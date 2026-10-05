defmodule KeilaWeb.AuthControllerOidcOnlyTest do
  use KeilaWeb.ConnCase, async: false
  use Oban.Testing, repo: Keila.Repo

  alias Keila.{Auth, Repo}
  alias Keila.Auth.Oidc

  @sign_up_params %{"email" => "oidc-only-foo@bar.com", "password" => @password}

  @valid_provider_config [
    providers: [
      staff: [
        issuer: "https://idp.example.com",
        client_id: "keila",
        client_secret: "s3cret",
        policy: :entitlement,
        entitlement_claim: "keila_role",
        entitlement_value: "keila_users"
      ]
    ],
    oidc_only: true
  ]

  @merchant_provider [
    issuer: "https://shop.example.com",
    client_id: "keila-merchant",
    client_secret: "sh0p",
    policy: :tenant_spn,
    tenant_prefix: "org",
    label: "Merchant sign-in"
  ]

  defp put_oidc_config(config) do
    previous = Application.get_env(:keila, Oidc)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:keila, Oidc)
      else
        Application.put_env(:keila, Oidc, previous)
      end
    end)

    Application.put_env(:keila, Oidc, config)
  end

  describe "OIDC-only off (default)" do
    @tag :auth_controller_oidc_only
    test "GET /auth/login renders the password form and register/reset links", %{conn: conn} do
      conn = get(conn, Routes.auth_path(conn, :login))
      html = html_response(conn, 200)

      assert html =~ "type=\"password\""
      assert html =~ Routes.auth_path(conn, :register)
      assert html =~ Routes.auth_path(conn, :reset)
    end

    @tag :auth_controller_oidc_only
    test "GET /auth/login renders no sign-in button when no provider is configured", %{conn: conn} do
      conn = get(conn, Routes.auth_path(conn, :login))

      refute html_response(conn, 200) =~ "/auth/oidc/"
    end

    @tag :auth_controller_oidc_only
    test "GET /auth/login offers the customer provider and withholds staff", %{conn: conn} do
      put_oidc_config(
        Keyword.merge(@valid_provider_config,
          providers: [
            staff: Keyword.put(@valid_provider_config[:providers][:staff], :label, "Staff SSO"),
            merchant: @merchant_provider
          ],
          oidc_only: false
        )
      )

      html = conn |> get(Routes.auth_path(conn, :login)) |> html_response(200)

      assert html =~ Routes.oidc_path(conn, :authorize, :merchant)
      assert html =~ "Merchant sign-in"
      refute html =~ Routes.oidc_path(conn, :authorize, :staff)
      refute html =~ "Staff SSO"
      assert html =~ "type=\"password\""
    end
  end

  describe "OIDC-only on" do
    @tag :auth_controller_oidc_only
    test "GET /auth/login shows no password field and no register/reset links", %{conn: conn} do
      put_oidc_config(@valid_provider_config)

      conn = get(conn, Routes.auth_path(conn, :login))
      html = html_response(conn, 200)

      refute html =~ "type=\"password\""
      refute html =~ Routes.auth_path(conn, :register)
      refute html =~ Routes.auth_path(conn, :reset)
    end

    @tag :auth_controller_oidc_only
    test "GET /auth/login still offers the customer button when passwords are disabled", %{
      conn: conn
    } do
      put_oidc_config(
        Keyword.put(@valid_provider_config, :providers, merchant: @merchant_provider)
      )

      html = conn |> get(Routes.auth_path(conn, :login)) |> html_response(200)

      assert html =~ Routes.oidc_path(conn, :authorize, :merchant)
    end

    @tag :auth_controller_oidc_only
    test "GET /auth/login offers nothing rather than staff when staff alone is configured", %{
      conn: conn
    } do
      put_oidc_config(@valid_provider_config)

      html = conn |> get(Routes.auth_path(conn, :login)) |> html_response(200)

      refute html =~ "/auth/oidc/"
      refute html =~ "type=\"password\""
    end

    @tag :auth_controller_oidc_only
    test "POST /auth/login with correct credentials does not authenticate", %{conn: conn} do
      with_seed()
      {:ok, user} = Auth.create_user(@sign_up_params)
      Auth.activate_user(user.id)

      put_oidc_config(@valid_provider_config)

      conn = post(conn, Routes.auth_path(conn, :login, user: @sign_up_params))
      conn = get(recycle(conn), "/")

      refute conn.assigns.current_user
    end

    @tag :auth_controller_oidc_only
    test "GET and POST /auth/register do not register a user", %{conn: conn} do
      put_oidc_config(@valid_provider_config)

      count_before = Repo.aggregate(Auth.User, :count)

      conn = get(conn, Routes.auth_path(conn, :register))
      assert html_response(conn, 200)

      conn =
        post(recycle(conn), Routes.auth_path(conn, :register),
          user: @sign_up_params,
          "h-captcha-response": "10000000-aaaa-bbbb-cccc-000000000001"
        )

      assert html_response(conn, 200)
      assert Repo.aggregate(Auth.User, :count) == count_before
    end

    @tag :auth_controller_oidc_only
    test "GET and POST /auth/reset do not send a reset email", %{conn: conn} do
      user = insert!(:user)
      put_oidc_config(@valid_provider_config)

      conn = get(conn, Routes.auth_path(conn, :reset))
      assert html_response(conn, 200)

      conn =
        post(recycle(conn), Routes.auth_path(conn, :reset),
          user: %{email: user.email},
          "h-captcha-response": "10000000-aaaa-bbbb-cccc-000000000001"
        )

      assert html_response(conn, 200)
      refute_enqueued(worker: Keila.Auth.SystemMailerWorker)
      assert_no_email_sent()
    end

    @tag :auth_controller_oidc_only
    test "GET /auth/logout still works for a signed-in user", %{conn: conn} do
      conn = with_login(conn)
      assert conn.assigns.current_user

      put_oidc_config(@valid_provider_config)

      conn = get(recycle(conn), Routes.auth_path(conn, :logout))
      conn = get(recycle(conn), "/")

      refute conn.assigns.current_user
    end

    @tag :auth_controller_oidc_only
    test "impersonation still works", %{conn: conn} do
      {root, user} = with_seed()
      conn = with_login(conn, user: root)

      put_oidc_config(@valid_provider_config)

      conn = get(conn, Routes.user_admin_path(conn, :impersonate, user.id))
      assert redirected_to(conn, 302) == "/"

      conn = recycle(conn) |> get("/")
      assert conn.assigns.current_user.id == user.id
    end
  end
end
