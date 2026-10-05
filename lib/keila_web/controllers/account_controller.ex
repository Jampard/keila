defmodule KeilaWeb.AccountController do
  use KeilaWeb, :controller
  import Ecto.Changeset
  alias Keila.{Auth, Accounts}

  @spec edit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def edit(conn, _) do
    render_edit(conn, change(conn.assigns.current_user))
  end

  @spec post_edit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def post_edit(conn, %{"user" => %{"password" => password}}) do
    user = conn.assigns.current_user

    # A local password would outlive revocation at the IdP, so IdP-managed accounts get none.
    if Auth.Oidc.Login.idp_managed?(user.id) do
      conn
      |> put_status(403)
      |> put_flash(
        :error,
        dgettext("auth", "Your password is managed by your identity provider.")
      )
      |> render_edit(change(user))
    else
      case Auth.update_user_password(user.id, %{password: password}) do
        {:ok, user} ->
          conn
          |> put_flash(:info, dgettext("auth", "New password saved."))
          |> render_edit(change(user))

        {:error, changeset} ->
          render_edit(conn, changeset)
      end
    end
  end

  def post_edit(conn, %{"user" => %{"locale" => locale}}) do
    case Auth.set_user_locale(conn.assigns.current_user.id, locale) do
      {:ok, _user} ->
        conn
        |> redirect(to: Routes.account_path(conn, :edit))

      {:error, changeset} ->
        render_edit(conn, changeset)
    end
  end

  defp render_edit(conn, changeset) do
    account = Accounts.get_user_account(conn.assigns.current_user.id)
    credits = if account, do: Accounts.get_credits(account.id)

    conn
    |> put_meta(:title, dgettext("auth", "Manage Account"))
    |> assign(:changeset, changeset)
    |> assign(:account, account)
    |> assign(:credits, credits)
    |> assign(:idp_managed, Auth.Oidc.Login.idp_managed?(conn.assigns.current_user.id))
    |> render("edit.html")
  end
end
