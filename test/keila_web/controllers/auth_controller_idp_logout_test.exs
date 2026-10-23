defmodule KeilaWeb.AuthControllerIdpLogoutTest do
  use KeilaWeb.ConnCase, async: false

  alias Keila.Auth
  alias Keila.Auth.Oidc

  @end_session_url "https://idm.example.test/ui/logout"

  setup do
    previous = Application.get_env(:keila, Oidc)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:keila, Oidc),
        else: Application.put_env(:keila, Oidc, previous)
    end)

    provider = [
      issuer: "https://idm.example.test/oauth2/openid/keila",
      client_id: "keila",
      client_secret: "s3cret",
      policy: :pushed
    ]

    Application.put_env(:keila, Oidc,
      providers: [
        merchant: Keyword.put(provider, :end_session_url, @end_session_url),
        quiet: Keyword.put(provider, :issuer, "https://quiet.example.test/oidc")
      ]
    )

    with_seed()

    {:ok, user} =
      Auth.create_user(%{email: "signout@example.test", password: "BatteryHorse123"},
        skip_activation_email: true
      )

    Auth.activate_user(user.id)
    {:ok, token} = Auth.create_token(%{scope: "web.session", user_id: user.id})

    %{token: token.key}
  end

  defp sign_out(conn, session) do
    conn |> init_test_session(session) |> get(Routes.auth_path(conn, :logout))
  end

  @tag :oidc
  test "signing out of a session from a provider with an end-session URL ends the IdP session too",
       %{conn: conn, token: token} do
    conn = sign_out(conn, %{token: token, oidc_provider: "merchant"})

    assert redirected_to(conn, 302) == @end_session_url
    refute Auth.find_token(token, "web.session")
    refute get_session(conn, :oidc_provider)
  end

  @tag :oidc
  test "a provider without an end-session URL, a password session or none at all stays on Keila",
       %{conn: conn, token: token} do
    for session <- [%{token: token, oidc_provider: "quiet"}, %{token: token}, %{}] do
      conn = sign_out(conn, session)

      assert redirected_to(conn, 302) == Routes.auth_path(conn, :login)
      refute Auth.find_token(token, "web.session")
    end
  end

  @tag :oidc
  test "a session naming a provider that is no longer configured stays on Keila",
       %{conn: conn, token: token} do
    conn = sign_out(conn, %{token: token, oidc_provider: "removed_since_sign_in"})

    assert redirected_to(conn, 302) == Routes.auth_path(conn, :login)
  end
end
