defmodule KeilaWeb.OidcController do
  use KeilaWeb, :controller

  require Logger

  alias Keila.Auth.Oidc

  # Scoped: `:staff` names no provider in its path, and the authorize leg it redirects to
  # already refuses an unconfigured one.
  plug :check_enabled when action in [:authorize, :callback]

  @doc """
  The staff door, deliberately unlinked from the sign-in page.

  A bare alias for the staff authorize leg, so the URL staff are told stays
  short and survives a change of provider path.
  """
  @spec staff(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def staff(conn, _params),
    do: redirect(conn, to: Routes.oidc_path(conn, :authorize, Oidc.staff_provider()))

  @doc """
  Callback URL for the provider named in the request path.

  Both legs derive their `redirect_uri` from here: the token exchange fails
  unless it is byte-identical to the one sent with the authorization request.
  """
  @spec callback_url(Plug.Conn.t()) :: String.t()
  def callback_url(conn), do: Routes.oidc_url(conn, :callback, provider(conn))

  @spec authorize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authorize(conn, _params), do: do_authorize(conn, provider(conn))

  # `Oidcc.Plug.Authorize` is invoked here rather than declared as a plug
  # because `:scopes` is not evaluated per request and ours are per provider.
  defp do_authorize(conn, provider) do
    opts =
      Oidcc.Plug.Authorize.init(
        client_store: KeilaWeb.OidcClientStore,
        redirect_uri: &__MODULE__.callback_url/1,
        scopes: Oidc.scopes(provider)
      )

    Oidcc.Plug.Authorize.call(conn, opts)
  rescue
    error in Oidcc.Plug.Authorize.Error ->
      Logger.warning(
        "OIDC authorization request for #{inspect(provider)} failed: #{inspect(error.reason)}"
      )

      render_error(conn, 400)
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, _params) do
    provider = provider(conn)

    conn
    |> Oidcc.Plug.AuthorizationCallback.call(callback_opts(provider))
    |> handle_callback(provider)
  end

  # Initialised per request for the same reason `Oidcc.Plug.Authorize` is above: a declared plug's
  # options are fixed for every provider, and `request_opts` carries per-provider TLS trust.
  defp callback_opts(provider) do
    Oidcc.Plug.AuthorizationCallback.init(
      client_store: KeilaWeb.OidcClientStore,
      redirect_uri: &__MODULE__.callback_url/1,
      check_peer_ip: false,
      retrieve_userinfo: false,
      request_opts: Oidc.request_opts(provider)
    )
  end

  defp handle_callback(
         conn = %Plug.Conn{private: %{Oidcc.Plug.AuthorizationCallback => {:ok, {token, _}}}},
         provider
       ) do
    case userinfo(provider, token) do
      {:ok, userinfo} -> sign_in(conn, provider, claims(provider, token, userinfo))
      {:error, reason} -> callback_failed(conn, provider, reason)
    end
  end

  defp handle_callback(
         conn = %Plug.Conn{private: %{Oidcc.Plug.AuthorizationCallback => {:error, reason}}},
         provider
       ) do
    callback_failed(conn, provider, reason)
  end

  # `retrieve_userinfo: true` would have the plug make this call, but it builds the userinfo options
  # from scratch and still drops `request_opts` (authorization_callback.ex:248), so an IdP behind a
  # private CA fails here after the token exchange has already succeeded.
  #
  # No `refresh_jwks`: oidcc calls it as `fun(jwks, kid)` (oidcc_userinfo.erl:302) while the store
  # callback is arity 1 over a ClientContext, and `retrieve_userinfo/5` installs no default of its
  # own. Omitting the key skips the refresh (`=/= undefined`); passing a mismatched one crashes.
  defp userinfo(provider, token) do
    Oidcc.retrieve_userinfo(
      token,
      Oidc.provider_worker_name(provider),
      Oidc.client_id(provider),
      Oidc.client_secret(provider),
      %{request_opts: Oidc.request_opts(provider)}
    )
  end

  defp sign_in(conn, provider, claims) do
    case Oidc.Login.handle_claims(provider, claims) do
      {:ok, user} ->
        conn
        |> start_auth_session(user.id)
        |> redirect(to: Routes.project_path(conn, :index))

      {:error, reason} ->
        Logger.warning("OIDC sign-in via #{inspect(provider)} refused: #{inspect(reason)}")
        render_error(conn, 403)
    end
  end

  # Only the error's shape is logged: several `oidcc` errors carry the decoded claims
  # map, which would put a subject's email — and sometimes a raw id_token — in the log.
  defp callback_failed(conn, provider, reason) do
    Logger.warning("OIDC callback for #{inspect(provider)} failed: #{error_tag(reason)}")

    render_error(conn, 400)
  end

  defp error_tag(reason) when is_atom(reason), do: inspect(reason)

  defp error_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: reason |> elem(0) |> error_tag()

  defp error_tag(_reason), do: "unknown_error"

  defp check_enabled(conn, _opts) do
    if Oidc.enabled?(provider(conn)) do
      conn
    else
      conn |> render_404() |> halt()
    end
  end

  defp provider(conn), do: conn.path_params["provider"]

  # The id_token is signed; a plain-JSON userinfo body is not — `oidcc` validates
  # only `sub` on it (oidcc_userinfo.erl:204-210). Userinfo may fill profile gaps,
  # never override a signed claim, and never supply the claim the gate reads:
  # for an access decision, absent must mean denied rather than "ask the unsigned body".
  defp claims(provider, token, userinfo) do
    userinfo
    |> userinfo_claims()
    |> Map.drop(gate_claims(provider))
    |> Map.merge(id_claims(token))
  end

  defp gate_claims(provider) do
    [Oidc.entitlement_claim(provider)]
    |> Enum.filter(&is_binary/1)
  end

  defp id_claims(%Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}) when is_map(claims),
    do: claims

  defp id_claims(_token), do: %{}

  defp userinfo_claims(userinfo) when is_map(userinfo), do: userinfo
  defp userinfo_claims(_userinfo), do: %{}

  defp render_404(conn) do
    conn
    |> put_status(404)
    |> put_view(KeilaWeb.AuthView)
    |> put_meta(:title, dgettext("auth", "Not found"))
    |> render("404.html")
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> put_view(KeilaWeb.AuthView)
    |> put_meta(:title, dgettext("auth", "Sign-in failed"))
    |> render("oidc_error.html")
  end
end
