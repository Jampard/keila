# Modified by EklipseTech, 2026; see NOTICE.
defmodule KeilaWeb.ProjectPlug do
  @moduledoc """
  This Plug adds a `current_project` assign from the `:project_id` path param.

  Halts the pipeline with 404 if the current user is not authorized to access
  the project or if the project doesn‘t exist.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [text: 2]
  alias Keila.Projects

  def init(_), do: []

  def call(conn, _) do
    project_id = conn.path_params["project_id"]
    user = conn.assigns.current_user

    case Projects.get_user_project(user.id, project_id) do
      nil -> conn |> put_status(404) |> text("Not Found") |> halt()
      project -> assign(conn, :current_project, project)
    end
  end
end
