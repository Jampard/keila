defmodule KeilaWeb.LiveAuthTest do
  use KeilaWeb.ConnCase, async: false

  alias Keila.{Auth, Projects}
  alias KeilaWeb.LiveAuth
  alias Phoenix.LiveView.Socket

  setup do
    {root, user} = with_seed()
    {:ok, project} = Projects.create_project(user.id, %{name: "Foo Bar"})
    {:ok, token} = Auth.create_token(%{scope: "web.session", user_id: user.id})
    %{root: root, user: user, project: project, session: %{"token" => token.key}}
  end

  defp mount(hook, session), do: LiveAuth.on_mount(hook, %{}, session, %Socket{})

  test ":project lets a member of the session's project through", %{
    project: project,
    session: session
  } do
    assert {:cont, _socket} = mount(:project, Map.put(session, "current_project", project))
  end

  test ":project refuses once the user has left the project the session was signed with", %{
    user: user,
    project: project,
    session: session
  } do
    :ok = Auth.remove_user_from_group(user.id, project.group_id)

    assert {:halt, %Socket{redirected: {:redirect, %{to: "/"}}}} =
             mount(:project, Map.put(session, "current_project", project))
  end

  test ":project refuses an ended session or one without a project", %{
    project: project,
    session: session
  } do
    Auth.find_and_delete_token(session["token"], "web.session")
    assert {:halt, _socket} = mount(:project, Map.put(session, "current_project", project))
    assert {:halt, _socket} = mount(:project, %{"current_project" => project})
    assert {:halt, _socket} = mount(:project, %{})
  end

  test ":admin lets only administer_keila through", %{root: root, session: session} do
    assert {:halt, _socket} = mount(:admin, session)

    {:ok, root_token} = Auth.create_token(%{scope: "web.session", user_id: root.id})

    assert {:cont, _socket} = mount(:admin, %{"token" => root_token.key})
  end

  test "a new auth session carries the user's live_socket_id", %{user: user} do
    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> KeilaWeb.AuthSession.start_auth_session(user.id)

    assert get_session(conn, :live_socket_id) == KeilaWeb.AuthSession.live_socket_id(user.id)
  end
end
