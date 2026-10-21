defmodule KeilaWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks that check, on every mount (reconnects included), that the session's user
  still has the access the LiveView was rendered for.

  The controllers that `live_render` these LiveViews check access once and sign the project into
  the LiveView session; without a hook, a socket keeps that access for as long as it lives and
  regains it on every reconnect. `KeilaWeb.AuthSession.disconnect_live_sockets/1` forces the
  reconnect when access is taken away.

  - `:project` - the user is a member of the session's `"current_project"`.
  - `:admin` - the user holds `administer_keila`.
  """
  import Phoenix.LiveView, only: [redirect: 2]
  alias Keila.{Auth, Projects}

  def on_mount(:project, _params, session, socket) do
    with %Auth.User{id: user_id} <- session_user(session),
         %{id: project_id} <- session["current_project"],
         %Projects.Project{} <- Projects.get_user_project(user_id, project_id) do
      {:cont, socket}
    else
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  def on_mount(:admin, _params, session, socket) do
    with %Auth.User{id: user_id} <- session_user(session),
         true <- Auth.has_permission?(user_id, Auth.root_group().id, "administer_keila") do
      {:cont, socket}
    else
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  defp session_user(session) do
    with token when is_binary(token) <- session["token"],
         %Auth.Token{user_id: user_id} <- Auth.find_token(token, "web.session") do
      Auth.get_user(user_id)
    end
  end
end
