defmodule KeilaWeb.OidcClientStoreTest do
  use ExUnit.Case, async: false

  @moduletag :kanidm

  alias Keila.Auth.Oidc
  alias KeilaWeb.OidcClientStore

  @unknown_provider "no_such_oidc_provider_name"

  setup do
    previous = Application.get_env(:keila, Oidc)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:keila, Oidc)
      else
        Application.put_env(:keila, Oidc, previous)
      end
    end)

    kanidm = Keila.KanidmIssuer.config!()

    Application.put_env(:keila, Oidc,
      providers: [staff: Keila.KanidmIssuer.provider_opts(kanidm)]
    )

    [spec] = Oidc.child_specs()
    start_supervised!(spec)

    %{issuer: kanidm}
  end

  defp conn(path_params) do
    %{Plug.Test.conn(:get, "/auth/oidc") | path_params: path_params}
  end

  describe "get_client_context/1" do
    test "resolves the provider named in the path to its configured client", %{issuer: issuer} do
      assert {:ok, %Oidcc.ClientContext{} = context} =
               OidcClientStore.get_client_context(conn(%{"provider" => "staff"}))

      assert context.client_id == issuer.client_id
      assert context.client_secret == issuer.client_secret
      assert context.provider_configuration.issuer == issuer.issuer
    end

    test "an unconfigured provider name is rejected without creating an atom for it" do
      assert {:error, :unknown_provider} =
               OidcClientStore.get_client_context(conn(%{"provider" => @unknown_provider}))

      assert_raise ArgumentError, fn -> String.to_existing_atom(@unknown_provider) end
    end

    test "a request without a provider path parameter is rejected" do
      assert {:error, :unknown_provider} = OidcClientStore.get_client_context(conn(%{}))
    end
  end

  describe "refresh_jwks/1" do
    test "reloads the keys of the provider that issued the context" do
      {:ok, context} = OidcClientStore.get_client_context(conn(%{"provider" => "staff"}))

      assert {:ok, %JOSE.JWK{} = jwks} = OidcClientStore.refresh_jwks(context)
      assert jwks == context.jwks
    end

    test "a context from an unconfigured issuer is rejected" do
      {:ok, context} = OidcClientStore.get_client_context(conn(%{"provider" => "staff"}))
      context = put_in(context.provider_configuration.issuer, "https://elsewhere.example.com")

      assert {:error, :provider_not_ready} = OidcClientStore.refresh_jwks(context)
    end

    # Guards the oidcc_plug pin: 0.5.1 captured the store callback directly, handing oidcc an
    # arity-1 function where it calls `fun(jwks, kid)`, so an IdP key rotation 500s every login.
    # Fails if the dependency moves back to a release without erlef/oidcc_plug#96.
    test "the plug wraps our client store in the arity-2 function oidcc calls" do
      {:ok, context} = OidcClientStore.get_client_context(conn(%{"provider" => "staff"}))

      assert %{refresh_jwks: fun} =
               Oidcc.Plug.Utils.put_refresh_jwks(%{}, context, client_store: OidcClientStore)

      assert is_function(fun, 2)
      assert {:ok, _jwks} = fun.(context.jwks, "unknown-kid")
    end
  end
end
