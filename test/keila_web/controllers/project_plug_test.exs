defmodule KeilaWeb.ProjectPlugTest do
  use KeilaWeb.ConnCase, async: false

  alias Keila.Auth
  alias Keila.Auth.{Oidc, OidcIdentity}
  alias Keila.{Repo, Tenancy}

  @issuer "https://shop.example.com/oidc"

  setup do
    previous = Application.get_env(:keila, Oidc)
    on_exit(fn -> Application.put_env(:keila, Oidc, previous || []) end)

    Application.put_env(:keila, Oidc,
      providers: [
        merchant: [issuer: @issuer, client_id: "keila", client_secret: "s3cret", policy: :pushed]
      ]
    )

    with_seed()
    :ok
  end

  defp push_shop!(version, state) do
    members = [%{sub: "s1", mail: "s1@shop.example.com", role: "merchant"}]
    state = %{version: version, state: state, name: "Acme", domains: [], members: members}
    {:ok, :applied} = Tenancy.apply_state("acme", state)
  end

  defp open_session(conn) do
    user_id = Repo.get_by!(OidcIdentity, issuer: @issuer, subject: "s1").user_id
    {:ok, token} = Auth.create_token(%{scope: "web.session", user_id: user_id})
    init_test_session(conn, %{token: token.key})
  end

  defp show(conn) do
    project_id = Repo.get_by!(Tenancy.Tenancy, slug: "acme").project_id
    get(conn, Routes.project_path(conn, :show, project_id))
  end

  @tag :project_controller
  test "suspending the shop answers the member's open session 404, and live restores it", %{
    conn: conn
  } do
    push_shop!(1, "live")
    conn = open_session(conn)
    assert html_response(show(conn), 200)

    push_shop!(2, "suspended")
    assert response(show(conn), 404) == "Not Found"

    push_shop!(3, "live")
    assert html_response(show(conn), 200)
  end
end
