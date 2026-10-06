defmodule KeilaWeb.Tenancy.AuthPlug do
  @moduledoc """
  Bearer-secret gate for `/tenancy`; without a configured secret the routes do not exist.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:keila, Keila.Tenancy, [])[:secret] do
      secret when is_binary(secret) and secret != "" -> authorise(conn, secret)
      _unset -> conn |> send_resp(404, "") |> halt()
    end
  end

  defp authorise(conn, secret) do
    with ["Bearer " <> given] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(given, secret) do
      conn
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthorised"}) |> halt()
    end
  end
end
