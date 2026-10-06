defmodule KeilaWeb.Tenancy.RawBodyPlug do
  @moduledoc """
  Keeps `/tenancy` bodies away from `Plug.Parsers`, whose 400 on bad JSON the contract answers with 422.
  """
  import Plug.Conn

  @max_length 1_000_000

  def init(opts), do: opts

  def call(conn = %Plug.Conn{path_info: ["tenancy" | _]}, _opts) do
    case read_body(conn, length: @max_length) do
      {:ok, body, conn} -> %{assign(conn, :raw_body, body) | body_params: %{}}
      {:more, _partial, conn} -> conn |> send_resp(413, "") |> halt()
      {:error, _reason} -> conn |> send_resp(400, "") |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
