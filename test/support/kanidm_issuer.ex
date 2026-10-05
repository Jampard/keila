defmodule Keila.KanidmIssuer do
  @moduledoc """
  Drives a real kanidm for the OIDC suite: provisioning, authentication and the
  authorisation-code leg a browser would otherwise perform.

  There is no mock. Every test here runs against a live realm, so the suite needs
  one reachable and configured:

    * `KEILA_TEST_KANIDM_ENV` — path to the generated `keila.env`, which carries the
      issuer, client id, client secret, CA path and tenant prefix.
    * `KEILA_TEST_KANIDM_IDM_PW` — path to `idm_admin.pw`, minted on bring-up.

  Both live under `$DEVENV_STATE/kanidm` of the dev stack (`flake.nix`). `configured?/0`
  reports whether they resolve; `config!/0` raises with the reason when they do not,
  rather than letting a test fail somewhere less obvious.

  The realm is shared mutable state: provisioning is idempotent and every fixture is
  namespaced by `unique/1` so concurrent or repeated runs cannot collide.
  """

  defstruct [:base_url, :issuer, :client_id, :client_secret, :cacertfile, :tenant_prefix, :scopes]

  @type t :: %__MODULE__{
          base_url: String.t(),
          issuer: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          cacertfile: String.t(),
          tenant_prefix: String.t(),
          scopes: [String.t()]
        }

  @issuer_marker "/oauth2/openid/"

  @doc "Whether the live realm is configured well enough to attempt a run."
  @spec configured?() :: boolean()
  def configured? do
    with path when is_binary(path) <- System.get_env("KEILA_TEST_KANIDM_ENV"),
         pw when is_binary(pw) <- System.get_env("KEILA_TEST_KANIDM_IDM_PW") do
      File.exists?(path) and File.exists?(pw)
    else
      _ -> false
    end
  end

  @doc """
  The live realm's configuration, read from `keila.env`.

  Raises with what is missing: a suite that cannot reach its IdP must say so once,
  loudly, instead of failing every test with a connection error.
  """
  @spec config!() :: t()
  def config! do
    env = env_file!() |> File.read!() |> parse_env()

    issuer = fetch_env!(env, "KEILA_OIDC_MERCHANT_ISSUER")

    %__MODULE__{
      base_url: base_from_issuer!(issuer),
      issuer: issuer,
      client_id: fetch_env!(env, "KEILA_OIDC_MERCHANT_CLIENT_ID"),
      client_secret: fetch_env!(env, "KEILA_OIDC_MERCHANT_CLIENT_SECRET"),
      cacertfile: fetch_env!(env, "KEILA_OIDC_MERCHANT_CACERTFILE"),
      tenant_prefix: Map.get(env, "KEILA_OIDC_MERCHANT_TENANT_PREFIX", "merchant"),
      scopes: env |> Map.get("KEILA_OIDC_MERCHANT_SCOPES", "") |> String.split(" ", trim: true)
    }
  end

  defp env_file! do
    case System.get_env("KEILA_TEST_KANIDM_ENV") do
      path when is_binary(path) ->
        if File.exists?(path),
          do: path,
          else: raise("KEILA_TEST_KANIDM_ENV points at #{path}, which does not exist")

      _ ->
        raise """
        KEILA_TEST_KANIDM_ENV is unset. The OIDC suite runs against a live kanidm and has no mock.
        Point it at the devenv stack's generated keila.env, e.g.
          export KEILA_TEST_KANIDM_ENV=$DEVENV_STATE/kanidm/keila.env
          export KEILA_TEST_KANIDM_IDM_PW=$DEVENV_STATE/kanidm/idm_admin.pw
        """
    end
  end

  defp fetch_env!(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "#{key} missing from #{System.get_env("KEILA_TEST_KANIDM_ENV")}"
    end
  end

  defp parse_env(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), unquote_value(value))
        _ -> acc
      end
    end)
  end

  defp unquote_value(value) do
    value |> String.trim() |> String.trim("\"") |> String.trim("'")
  end

  # An issuer without the marker is not a kanidm OIDC issuer; guessing a base URL from
  # it would send every later call to a 404 far from here.
  defp base_from_issuer!(issuer) do
    case String.split(issuer, @issuer_marker, parts: 2) do
      [base, _client] -> base
      _ -> raise "issuer #{issuer} carries no #{@issuer_marker}, so its base URL is underivable"
    end
  end

  @doc "Provider options for `Keila.Auth.Oidc`, pointing at the live client."
  @spec provider_opts(t(), keyword()) :: keyword()
  def provider_opts(%__MODULE__{} = kanidm, overrides \\ []) do
    Keyword.merge(
      [
        issuer: kanidm.issuer,
        client_id: kanidm.client_id,
        client_secret: kanidm.client_secret,
        cacertfile: kanidm.cacertfile,
        scopes: kanidm.scopes,
        policy: :tenant_spn,
        tenant_prefix: kanidm.tenant_prefix
      ],
      overrides
    )
  end

  @doc "A realm-unique suffix, so repeated runs never collide on a name."
  @spec unique(String.t()) :: String.t()
  def unique(prefix) do
    "#{prefix}#{System.unique_integer([:positive])}#{:erlang.phash2(self(), 9973)}"
  end

  @doc """
  A privileged `idm_admin` bearer token.

  kanidm's auth is stepped and the CLI is TTY-bound, so this speaks the REST form:
  `init2` for a session id, `begin` to choose the mechanism, then the credential.
  """
  @spec admin_token!(t()) :: String.t()
  def admin_token!(%__MODULE__{} = kanidm) do
    password =
      case System.get_env("KEILA_TEST_KANIDM_IDM_PW") do
        path when is_binary(path) -> path |> File.read!() |> String.trim()
        _ -> raise "KEILA_TEST_KANIDM_IDM_PW is unset"
      end

    auth_token!(kanidm, "idm_admin", password, true)
  end

  @doc "Authenticates a person (or service account) and returns its bearer token."
  @spec auth_token!(t(), String.t(), String.t(), boolean()) :: String.t()
  def auth_token!(%__MODULE__{} = kanidm, username, password, privileged \\ false) do
    init =
      request!(kanidm, :post, "/v1/auth", %{
        step: %{init2: %{username: username, issue: "token", privileged: privileged}}
      })

    session_id =
      case Req.Response.get_header(init, "x-kanidm-auth-session-id") do
        [id | _] -> id
        _ -> raise "kanidm init2 for #{username} returned no session id (#{init.status})"
      end

    headers = [{"x-kanidm-auth-session-id", session_id}]

    request!(kanidm, :post, "/v1/auth", %{step: %{begin: "password"}}, headers: headers)

    result =
      request!(kanidm, :post, "/v1/auth", %{step: %{cred: %{password: password}}},
        headers: headers
      )

    case result.body do
      %{"state" => %{"success" => token}} when is_binary(token) ->
        token

      other ->
        raise "kanidm denied #{username}: #{inspect(other)}"
    end
  end

  @doc """
  Creates `person` with `mail`, puts it in `groups`, and gives it `password`.

  Idempotent, and safe to call for a name that already exists.
  """
  @spec provision_person!(t(), String.t(), String.t(), keyword()) :: :ok
  def provision_person!(%__MODULE__{} = kanidm, admin_token, person, opts) do
    mail = Keyword.get(opts, :mail, "#{person}@example.test")
    groups = Keyword.get(opts, :groups, [])
    password = Keyword.fetch!(opts, :password)

    admin_post!(kanidm, admin_token, "/v1/person", %{
      attrs: %{
        name: [person],
        displayname: [Keyword.get(opts, :displayname, person)],
        mail: [mail]
      }
    })

    # kanidm commits a person and propagates its name→uuid index asynchronously;
    # referencing it before that lands corrupts it into a phantom that 500s forever.
    await_resolvable!(kanidm, admin_token, person)

    Enum.each(groups, fn group ->
      admin_post!(kanidm, admin_token, "/v1/group", %{attrs: %{name: [group]}})
      admin_post!(kanidm, admin_token, "/v1/group/#{group}/_attr/member", [person])
    end)

    set_password!(kanidm, admin_token, person, password)
  end

  @doc "Removes `person` from `group`. kanidm drops values with a DELETE carrying them."
  @spec remove_from_group!(t(), String.t(), String.t(), String.t()) :: :ok
  def remove_from_group!(%__MODULE__{} = kanidm, admin_token, person, group) do
    request!(kanidm, :delete, "/v1/group/#{group}/_attr/member", [person],
      headers: [{"authorization", "Bearer " <> admin_token}]
    )

    :ok
  end

  @doc """
  Lets the realm's persons hold a password at all.

  kanidm defaults `idm_all_persons` to `credential_type_minimum = mfa`, and a
  password-only commit then fails with `cu0004sessioninconsistent`, which names the
  session rather than the policy and reads like a protocol bug.
  """
  @spec allow_password_credentials!(t(), String.t()) :: :ok
  def allow_password_credentials!(%__MODULE__{} = kanidm, admin_token) do
    # PUT replaces the attribute; POST would append.
    request!(kanidm, :put, "/v1/group/idm_all_persons/_attr/credential_type_minimum", ["any"],
      headers: [{"authorization", "Bearer " <> admin_token}]
    )

    :ok
  end

  @doc "Registers `redirect_uri` as an allowed origin of `client_id` (the configured one by default)."
  @spec allow_redirect_uri!(t(), String.t(), String.t(), String.t() | nil) :: :ok
  def allow_redirect_uri!(%__MODULE__{} = kanidm, admin_token, redirect_uri, client_id \\ nil) do
    admin_post!(
      kanidm,
      admin_token,
      "/v1/oauth2/#{client_id || kanidm.client_id}/_attr/oauth2_rs_origin",
      [redirect_uri]
    )
  end

  @doc """
  Ensures a second confidential OAuth2 client and returns a config pointing at it.

  A distinct client means a distinct **issuer**, which is what the identity-namespace
  tests need: two providers sharing one issuer would share `(issuer, subject)` rows and
  prove nothing.
  """
  @spec ensure_second_client!(t(), String.t(), String.t(), String.t()) :: t()
  def ensure_second_client!(%__MODULE__{} = kanidm, admin_token, client_id, redirect_uri) do
    admin_post!(kanidm, admin_token, "/v1/oauth2/_basic", %{
      attrs: %{
        name: [client_id],
        displayname: ["Keila second provider (test)"],
        oauth2_rs_origin_landing: [redirect_uri],
        oauth2_rs_origin: [redirect_uri]
      }
    })

    allow_redirect_uri!(kanidm, admin_token, redirect_uri, client_id)

    admin_post!(
      kanidm,
      admin_token,
      "/v1/oauth2/#{client_id}/_scopemap/idm_all_persons",
      ["openid", "email", "profile", "groups_spn"]
    )

    secret =
      kanidm
      |> request!(:get, "/v1/oauth2/#{client_id}/_basic_secret", nil,
        headers: [{"authorization", "Bearer " <> admin_token}]
      )
      |> decoded_body()

    if not is_binary(secret) or secret == "" do
      raise "#{client_id} has no basic secret — was it created as a _public client?"
    end

    %{
      kanidm
      | client_id: client_id,
        client_secret: secret,
        issuer: "#{kanidm.base_url}#{@issuer_marker}#{client_id}"
    }
  end

  defp set_password!(kanidm, admin_token, person, password) do
    auth = [{"authorization", "Bearer " <> admin_token}]

    session =
      kanidm
      |> request!(:get, "/v1/person/#{person}/_credential/_update", nil, headers: auth)
      |> Map.fetch!(:body)
      |> List.first()

    request!(kanidm, :post, "/v1/credential/_update", [%{password: password}, session],
      headers: auth
    )

    request!(kanidm, :post, "/v1/credential/_commit", session, headers: auth)
    :ok
  end

  defp await_resolvable!(kanidm, admin_token, person, attempts \\ 30) do
    auth = [{"authorization", "Bearer " <> admin_token}]

    response =
      request(kanidm, :get, "/v1/person/#{person}", nil, headers: auth)

    uuid =
      case response do
        {:ok, %{status: 200, body: %{"attrs" => %{"uuid" => [uuid | _]}}}} -> uuid
        _ -> nil
      end

    cond do
      is_binary(uuid) ->
        :ok

      attempts > 0 ->
        Process.sleep(200)
        await_resolvable!(kanidm, admin_token, person, attempts - 1)

      true ->
        raise "kanidm never resolved a uuid for person #{person}"
    end
  end

  @doc """
  Plays the browser half of the authorization request.

  Takes the authorization URL Keila redirected to and replays **its** `state`, `nonce`
  and PKCE challenge — minting fresh ones would produce a code Keila's session cannot
  validate. Returns the query parameters of kanidm's redirect back: `code` and `state`.
  """
  @spec authorize(t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def authorize(%__MODULE__{} = kanidm, authorize_url, person_token) do
    params = authorize_url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    auth = [{"authorization", "Bearer " <> person_token}]

    body = %{
      response_type: "code",
      client_id: kanidm.client_id,
      state: params["state"],
      code_challenge: params["code_challenge"],
      code_challenge_method: params["code_challenge_method"] || "S256",
      redirect_uri: params["redirect_uri"],
      scope: params["scope"],
      nonce: params["nonce"]
    }

    response = request!(kanidm, :post, "/oauth2/authorise", body, headers: auth)

    # Keyed on the `location` header, never the status: once the person has consented
    # to this client, kanidm answers a repeat authorise with the redirect already built
    # (body `"Permitted"`), and only the first one needs the consent round-trip.
    case {redirect_params(response), decoded_body(response)} do
      {%{"code" => _} = params, _} ->
        {:ok, params}

      {_, %{"ConsentRequested" => %{"consent_token" => token}}} ->
        permit(kanidm, token, auth)

      {_, decoded} ->
        {:error, {:unexpected_authorise_response, response.status, decoded}}
    end
  end

  # kanidm answers some endpoints without a JSON content-type, so Req leaves the body a
  # binary. Decoding here keeps every caller free of that distinction.
  defp decoded_body(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decoded_body(%{body: body}), do: body

  defp permit(kanidm, consent_token, auth) do
    # The consent token is posted as a bare JSON string, not an object.
    response = request!(kanidm, :post, "/oauth2/authorise/permit", consent_token, headers: auth)

    case redirect_params(response) do
      %{"code" => _} = params -> {:ok, params}
      _ -> {:error, {:permit_carried_no_code, response.status}}
    end
  end

  defp redirect_params(response) do
    case Req.Response.get_header(response, "location") do
      [location | _] -> location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      _ -> %{}
    end
  end

  defp admin_post!(kanidm, admin_token, path, body) do
    auth = [{"authorization", "Bearer " <> admin_token}]

    case request(kanidm, :post, path, body, headers: auth) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: _status, body: response_body}} ->
        if exists_already?(response_body),
          do: :ok,
          else: raise("kanidm POST #{path} failed: #{inspect(response_body)}")

      {:error, reason} ->
        raise "kanidm POST #{path} failed: #{inspect(reason)}"
    end
  end

  defp exists_already?(body) do
    text = if is_binary(body), do: body, else: inspect(body)

    Regex.match?(
      ~r/already exists|attribute\s*uniqueness|conflicting_attributes|memberof|duplicate/i,
      text
    )
  end

  defp request!(kanidm, method, path, body, opts \\ [])

  defp request!(kanidm, method, path, body, opts) do
    case request(kanidm, method, path, body, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "kanidm #{method} #{path} failed: #{inspect(reason)}"
    end
  end

  defp request(kanidm, method, path, body, opts) do
    headers = [{"content-type", "application/json"} | Keyword.get(opts, :headers, [])]

    request =
      Req.new(
        method: method,
        url: kanidm.base_url <> path,
        headers: headers,
        redirect: false,
        retry: false,
        connect_options: [
          transport_opts: [
            verify: :verify_peer,
            cacertfile: kanidm.cacertfile,
            depth: 3,
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
      )

    request = if is_nil(body), do: request, else: Req.merge(request, json: body)

    Req.request(request)
  end
end
