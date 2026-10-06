defmodule KeilaWeb.OidcControllerTest do
  @moduledoc """
  The controller against a **live kanidm**. There is no mock issuer.

  What that costs, recorded so nobody assumes the coverage is still here: a real IdP
  will not mint a token Keila must reject, so the cases that forged one are gone —
  a mismatched `nonce`, an expired `exp`, a signature from an unpublished key, an
  `alg: "none"` id_token, and every userinfo-versus-id_token precedence case (kanidm's
  userinfo body is not ours to write). Their invariants now live only in
  `Keila.Auth.Oidc.Claims` and `Keila.Auth.Oidc.Login`, which are exercised directly.
  """

  use KeilaWeb.ConnCase, async: false

  @moduletag :kanidm

  alias Keila.Auth
  alias Keila.Auth.Oidc
  alias Keila.Auth.OidcIdentity
  alias Keila.Auth.User
  alias Keila.KanidmIssuer
  alias Keila.Repo

  @unknown_provider "no_such_oidc_provider_for_the_controller"
  @password "KanidmSuitePassphrase-4Rt8Wq"

  setup do
    previous = Application.get_env(:keila, Oidc)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:keila, Oidc)
      else
        Application.put_env(:keila, Oidc, previous)
      end
    end)

    Application.delete_env(:keila, Oidc)
    with_seed()

    kanidm = KanidmIssuer.config!()
    admin = KanidmIssuer.admin_token!(kanidm)
    KanidmIssuer.allow_password_credentials!(kanidm, admin)

    %{kanidm: kanidm, admin: admin}
  end

  defp callback_url(provider \\ "merchant"),
    do: Routes.oidc_url(KeilaWeb.Endpoint, :callback, provider)

  # A shop member: the platform pushes the person's kanidm uuid into each of `slugs`.
  defp provision_member(kanidm, admin, opts \\ []) do
    person = KanidmIssuer.unique("member")
    slugs = Keyword.get_lazy(opts, :slugs, fn -> [KanidmIssuer.unique("acme")] end)
    mail = "#{person}@example.test"

    KanidmIssuer.provision_person!(kanidm, admin, person, password: @password, mail: mail)
    sub = KanidmIssuer.person_uuid!(kanidm, admin, person)
    Enum.each(slugs, &push_shop(&1, 1, [%{sub: sub, mail: mail, role: "merchant"}]))

    %{person: person, slug: List.first(slugs), sub: sub, mail: mail}
  end

  defp push_shop(slug, version, members) do
    state = %{version: version, state: "live", name: slug, domains: [], members: members}
    {:ok, :applied} = Keila.Tenancy.apply_state(slug, state)
  end

  defp configure(providers) do
    Application.put_env(:keila, Oidc, providers: providers)
    Enum.each(Oidc.child_specs(), &start_supervised!/1)
  end

  defp configure_merchant(kanidm, admin, overrides \\ []) do
    KanidmIssuer.allow_redirect_uri!(kanidm, admin, callback_url())
    configure(merchant: KanidmIssuer.provider_opts(kanidm, overrides))
  end

  defp entitlement_opts(kanidm) do
    KanidmIssuer.provider_opts(kanidm,
      policy: :entitlement,
      entitlement_claim: "groups",
      entitlement_value: "keila_nobody"
    )
  end

  defp request_authorize(conn, provider),
    do: get(conn, Routes.oidc_path(conn, :authorize, provider))

  defp request_callback(conn, provider, params) do
    conn
    |> recycle()
    |> get(Routes.oidc_path(conn, :callback, provider), params)
  end

  defp authorize_params(conn) do
    conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()
  end

  defp complete_login(conn, kanidm, provider, person) do
    conn = request_authorize(conn, provider)
    token = KanidmIssuer.auth_token!(kanidm, person, @password)
    {:ok, params} = KanidmIssuer.authorize(kanidm, redirected_to(conn, 302), token)
    request_callback(conn, provider, params)
  end

  defp project_names(user_id) do
    user_id |> Keila.Projects.get_user_projects() |> Enum.map(& &1.name)
  end

  defp counts do
    %{users: Repo.aggregate(User, :count), identities: Repo.aggregate(OidcIdentity, :count)}
  end

  @tag :oidc
  test "an install without OIDC configuration answers both routes with 404", %{conn: conn} do
    assert conn |> get(Routes.oidc_path(conn, :authorize, "merchant")) |> html_response(404)
    assert conn |> get(Routes.oidc_path(conn, :callback, "merchant")) |> html_response(404)
  end

  @tag :oidc
  test "a provider name that is not configured is a 404 that creates no atom", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    configure_merchant(kanidm, admin)

    assert conn
           |> get(Routes.oidc_path(conn, :authorize, @unknown_provider))
           |> html_response(404)

    assert conn |> get(Routes.oidc_path(conn, :callback, @unknown_provider)) |> html_response(404)

    assert_raise ArgumentError, fn -> String.to_existing_atom(@unknown_provider) end
  end

  @tag :oidc
  test "the authorize leg redirects to kanidm with state, nonce and an S256 challenge", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    configure_merchant(kanidm, admin)

    conn = request_authorize(conn, "merchant")
    assert String.starts_with?(redirected_to(conn, 302), kanidm.base_url)

    params = authorize_params(conn)
    assert is_binary(params["state"]) and params["state"] != ""
    assert is_binary(params["nonce"]) and params["nonce"] != ""
    assert is_binary(params["code_challenge"]) and params["code_challenge"] != ""
    assert params["code_challenge_method"] == "S256"
  end

  @tag :oidc
  test "a full code flow signs in a pushed member as the User the push created", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    configure_merchant(kanidm, admin)
    %{person: person, slug: slug} = provision_member(kanidm, admin)

    conn = complete_login(conn, kanidm, "merchant", person)

    assert redirected_to(conn, 302) == Routes.project_path(conn, :index)
    assert %Auth.Token{} = conn |> get_session(:token) |> Auth.find_token("web.session")

    assert user = Repo.get_by(User, email: "#{person}@example.test")

    # kanidm's `sub` is the account uuid, not the person name.
    assert %OidcIdentity{user_id: user_id, subject: subject} =
             Repo.get_by(OidcIdentity, issuer: kanidm.issuer, user_id: user.id)

    assert user_id == user.id
    assert subject =~ ~r/^[0-9a-f-]{36}$/

    assert slug in project_names(user.id)
  end

  @tag :oidc
  test "signing in twice writes no user or identity: the push already did", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    configure_merchant(kanidm, admin)
    %{person: person} = provision_member(kanidm, admin)

    before = counts()

    assert conn |> complete_login(kanidm, "merchant", person) |> redirected_to(302)
    assert build_conn() |> complete_login(kanidm, "merchant", person) |> redirected_to(302)

    assert counts() == before
  end

  @tag :oidc
  test "a tampered state is refused and establishes no session", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    configure_merchant(kanidm, admin)
    %{person: person} = provision_member(kanidm, admin)

    conn = request_authorize(conn, "merchant")
    token = KanidmIssuer.auth_token!(kanidm, person, @password)
    {:ok, params} = KanidmIssuer.authorize(kanidm, redirected_to(conn, 302), token)

    conn =
      request_callback(conn, "merchant", %{params | "state" => params["state"] <> "tampered"})

    assert html_response(conn, 400)
    refute get_session(conn, :token)
  end

  @tag :oidc
  test "a callback without a code is refused and establishes no session", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    configure_merchant(kanidm, admin)

    conn = request_authorize(conn, "merchant")
    conn = request_callback(conn, "merchant", %{"state" => authorize_params(conn)["state"]})

    assert html_response(conn, 400)
    refute get_session(conn, :token)
  end

  @tag :oidc
  test "a subject never pushed is refused and no user is written", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    configure_merchant(kanidm, admin)
    %{person: person} = provision_member(kanidm, admin, slugs: [])

    before = counts()
    conn = complete_login(conn, kanidm, "merchant", person)

    assert html_response(conn, 403)
    refute get_session(conn, :token)
    assert counts() == before
  end

  @tag :oidc
  test "a newer push without the member revokes that shop and keeps the other", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    configure_merchant(kanidm, admin)

    kept = KanidmIssuer.unique("kept")
    dropped = KanidmIssuer.unique("dropped")
    %{person: person} = provision_member(kanidm, admin, slugs: [kept, dropped])

    conn = complete_login(conn, kanidm, "merchant", person)
    assert get_session(conn, :token)
    user = Repo.get_by(User, email: "#{person}@example.test")
    assert MapSet.subset?(MapSet.new([kept, dropped]), MapSet.new(project_names(user.id)))

    push_shop(dropped, 2, [])

    assert build_conn() |> complete_login(kanidm, "merchant", person) |> get_session(:token)

    names = project_names(user.id)
    assert kept in names
    refute dropped in names
  end

  @tag :oidc
  test "the same person at two kanidm clients yields two distinct Keila users", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    second =
      KanidmIssuer.ensure_second_client!(
        kanidm,
        admin,
        "keila-second-test",
        callback_url("second")
      )

    KanidmIssuer.allow_redirect_uri!(kanidm, admin, callback_url())

    configure(merchant: KanidmIssuer.provider_opts(kanidm), second: entitlement_opts(second))

    %{person: person} = provision_member(kanidm, admin)

    first_conn = complete_login(conn, kanidm, "merchant", person)
    assert get_session(first_conn, :token)

    second_conn = complete_login(build_conn(), second, "second", person)

    # Same human, same kanidm uuid, but a different issuer — so a different identity
    # namespace: the second sign-in cannot reuse the first user.
    assert html_response(second_conn, 403)
    refute get_session(second_conn, :token)
    assert Repo.aggregate(OidcIdentity, :count) == 1
  end

  @tag :oidc
  test "a login begun at one provider and finished at another is refused", %{
    conn: conn,
    kanidm: kanidm,
    admin: admin
  } do
    second =
      KanidmIssuer.ensure_second_client!(
        kanidm,
        admin,
        "keila-second-test",
        callback_url("second")
      )

    KanidmIssuer.allow_redirect_uri!(kanidm, admin, callback_url())

    configure(merchant: KanidmIssuer.provider_opts(kanidm), second: entitlement_opts(second))

    %{person: person} = provision_member(kanidm, admin)

    started_at_merchant = request_authorize(conn, "merchant")
    state = authorize_params(started_at_merchant)["state"]
    token = KanidmIssuer.auth_token!(kanidm, person, @password)
    {:ok, params} = KanidmIssuer.authorize(kanidm, redirected_to(started_at_merchant, 302), token)

    # The second authorize overwrites the single fixed session slot.
    started_at_second = request_authorize(recycle(started_at_merchant), "second")

    conn =
      request_callback(started_at_second, "merchant", %{
        "code" => params["code"],
        "state" => state
      })

    assert html_response(conn, 400)
    refute get_session(conn, :token)
  end
end
