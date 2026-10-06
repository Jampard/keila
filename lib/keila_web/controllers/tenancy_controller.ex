defmodule KeilaWeb.TenancyController do
  use KeilaWeb, :controller

  alias Keila.Tenancy

  def index(conn, _params), do: json(conn, Tenancy.list())

  def show(conn, %{"slug" => slug}) do
    with true <- Tenancy.valid_slug?(slug),
         {:ok, held} <- Tenancy.read(slug) do
      json(conn, held)
    else
      {:error, :no_merchant_issuer} -> unavailable(conn)
      _not_held -> conn |> send_resp(404, "")
    end
  end

  def update(conn, %{"slug" => slug}) do
    with true <- Tenancy.valid_slug?(slug) || {:error, {:malformed, "slug: must be a DNS label"}},
         {:ok, next} <- Tenancy.parse(conn.assigns.raw_body) |> malformed(),
         {:ok, outcome} <- Tenancy.apply_state(slug, next) do
      json(conn, %{outcome => true})
    else
      {:error, {:malformed, why}} ->
        conn |> put_status(422) |> json(%{error: why})

      {:error, :no_merchant_issuer} ->
        unavailable(conn)

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(422) |> json(%{error: "members: could not be applied"})
    end
  end

  defp malformed({:error, why}) when is_binary(why), do: {:error, {:malformed, why}}
  defp malformed(ok), do: ok

  defp unavailable(conn) do
    conn |> put_status(503) |> json(%{error: "no single OIDC provider has policy pushed"})
  end
end
