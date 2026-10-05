defmodule KeilaWeb.AccountControllerTest do
  use KeilaWeb.ConnCase
  alias Keila.Auth

  describe "GET /account" do
    @tag :account_controller
    test "shows manage account page", %{conn: conn} do
      conn = with_login(conn)
      conn = get(conn, Routes.account_path(conn, :edit))
      assert html_response(conn, 200) =~ ~r{Change Password\s*</h2>}
    end
  end

  describe "PUT /account" do
    @tag :account_controller
    test "allows changing of password", %{conn: conn} do
      conn = with_login(conn)

      password_params = %{"password" => "MyNewPassword"}

      conn = put(conn, Routes.account_path(conn, :post_edit), user: password_params)

      assert html_response(conn, 200) =~ ~r{New password saved.}
      user = conn.assigns.current_user
      user_id = user.id

      credentials = password_params |> Map.put("email", user.email)
      assert {:ok, %{id: ^user_id}} = Auth.find_user_by_credentials(credentials)
    end

    @tag :account_controller
    test "refuses a password change for an account the IdP manages", %{conn: conn} do
      conn = with_login(conn)
      user = conn.assigns.current_user
      issuer = "https://idp.example.com/oauth2/openid/keila"
      insert!(:oidc_identity, user_id: user.id, issuer: issuer)

      previous = Application.get_env(:keila, Keila.Auth.Oidc)
      on_exit(fn -> Application.put_env(:keila, Keila.Auth.Oidc, previous || []) end)

      Application.put_env(:keila, Keila.Auth.Oidc,
        providers: [staff: [issuer: issuer, client_id: "keila", client_secret: "s3cret"]]
      )

      password_hash = Keila.Repo.get!(Auth.User, user.id).password_hash

      conn =
        put(conn, Routes.account_path(conn, :post_edit), user: %{"password" => "MyNewPassword"})

      html = html_response(conn, 403)
      assert html =~ "Your password is managed by your identity provider."
      refute html =~ "Update password"
      assert Keila.Repo.get!(Auth.User, user.id).password_hash == password_hash
    end
  end
end
