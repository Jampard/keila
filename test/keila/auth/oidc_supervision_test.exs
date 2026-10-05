defmodule Keila.Auth.OidcSupervisionTest do
  use Keila.DataCase, async: false

  alias Keila.Auth.Oidc
  alias Oidcc.ProviderConfiguration.Worker

  @unreachable_a [
    issuer: "http://127.0.0.1:9/a",
    client_id: "client-a",
    client_secret: "secret-a"
  ]

  @unreachable_b [
    issuer: "http://127.0.0.1:9/b",
    client_id: "client-b",
    client_secret: "secret-b"
  ]

  setup do
    previous = Application.get_env(:keila, Oidc)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:keila, Oidc)
      else
        Application.put_env(:keila, Oidc, previous)
      end
    end)

    Application.delete_env(:keila, Oidc)

    :ok
  end

  defp put_providers(providers), do: Application.put_env(:keila, Oidc, providers: providers)

  defp worker_opts(%{start: {Worker, :start_link, [opts]}}), do: opts

  describe "child_specs/0" do
    test "an install without OIDC configuration starts no OIDC processes" do
      assert Oidc.child_specs() == []

      put_providers([])
      assert Oidc.child_specs() == []
    end

    test "one configured provider yields one worker carrying its issuer" do
      put_providers(staff: @unreachable_a)

      assert [spec] = Oidc.child_specs()
      assert worker_opts(spec).issuer == "http://127.0.0.1:9/a"
      assert worker_opts(spec).name == Oidc.provider_worker_name(:staff)
    end

    test "workers retry with backoff instead of stopping when the IdP is unreachable" do
      put_providers(staff: @unreachable_a)

      assert [spec] = Oidc.child_specs()
      opts = worker_opts(spec)

      assert opts.backoff_type == :random_exponential
      assert opts.backoff_min == 1_000
      assert opts.backoff_max == 120_000
    end

    test "two providers get distinct ids, so they do not collide in one supervisor" do
      put_providers(staff: @unreachable_a, merchant: @unreachable_b)

      assert [%{id: id_a}, %{id: id_b}] = specs = Oidc.child_specs()
      assert id_a != id_b

      assert {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)
      assert length(Supervisor.which_children(supervisor)) == 2
      Supervisor.stop(supervisor)
    end

    test "provider_configuration_opts from config reaches the worker" do
      put_providers(staff: Keyword.put(@unreachable_a, :provider_configuration_opts, %{a: 1}))

      assert [spec] = Oidc.child_specs()
      assert worker_opts(spec).provider_configuration_opts == %{a: 1}
    end

    test "a provider without provider_configuration_opts passes an empty map" do
      put_providers(staff: @unreachable_a)

      assert [spec] = Oidc.child_specs()
      assert worker_opts(spec).provider_configuration_opts == %{}
    end

    @tag :kanidm
    test "the built spec loads the live issuer's configuration over its private CA" do
      kanidm = Keila.KanidmIssuer.config!()
      put_providers(staff: Keila.KanidmIssuer.provider_opts(kanidm))

      assert [spec] = Oidc.child_specs()
      start_supervised!(spec)

      configuration = Worker.get_provider_configuration(Oidc.provider_worker_name(:staff))
      assert configuration.issuer == kanidm.issuer
    end
  end
end
