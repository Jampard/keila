defmodule KeilaWeb.OidcClientStore do
  @moduledoc """
  Resolves the `Oidcc` client context from the `:provider` path parameter.

  `Oidcc.Plug.Authorize` and `Oidcc.Plug.AuthorizationCallback` take their
  `:provider` at plug-init and never evaluate it per request, so routes of the
  shape `/auth/oidc/:provider` need this store instead.
  """

  @behaviour Oidcc.Plug.ClientStore

  alias Keila.Auth.Oidc
  alias Oidcc.ProviderConfiguration.Worker

  @impl Oidcc.Plug.ClientStore
  def get_client_context(conn) do
    with name when is_binary(name) <- path_provider(conn),
         worker when not is_nil(worker) <- Oidc.provider_worker_name(name) do
      Oidcc.ClientContext.from_configuration_worker(
        worker,
        Oidc.client_id(name),
        Oidc.client_secret(name)
      )
    else
      _other -> {:error, :unknown_provider}
    end
  end

  @impl Oidcc.Plug.ClientStore
  def refresh_jwks(%Oidcc.ClientContext{provider_configuration: %{issuer: issuer}}) do
    with name when not is_nil(name) <- provider_for_issuer(issuer),
         worker when not is_nil(worker) <- Oidc.provider_worker_name(name),
         true <- is_pid(Process.whereis(worker)) do
      :ok = Worker.refresh_jwks(worker)
      {:ok, Worker.get_jwks(worker)}
    else
      _other -> {:error, :provider_not_ready}
    end
  end

  defp path_provider(%Plug.Conn{path_params: params}) when is_map(params),
    do: Map.get(params, "provider")

  defp path_provider(_conn), do: nil

  defp provider_for_issuer(issuer) do
    Enum.find(Oidc.provider_names(), fn name -> Oidc.issuer(name) == issuer end)
  end
end
