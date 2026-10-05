defmodule Keila.Auth.OidcConfigTest do
  use Keila.DataCase, async: false

  alias Keila.Auth.Oidc

  @staff [
    issuer: "https://idp.example.com/oauth2/openid/keila",
    client_id: "keila",
    client_secret: "s3cret",
    scopes: ["openid", "email", "profile", "groups"],
    label: "Sign in with Staff SSO",
    policy: :entitlement,
    entitlement_claim: "keila_role",
    entitlement_value: "keila_users"
  ]

  @merchant [
    issuer: "https://shop.example.com/oidc",
    client_id: "keila-merchant",
    client_secret: "sh0p",
    policy: :tenant_spn,
    tenant_prefix: "org"
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

  defp put_config(config), do: Application.put_env(:keila, Oidc, config)

  @tag :oidc
  test "unconfigured instance exposes no providers" do
    assert Oidc.providers() == []
    assert Oidc.provider_names() == []
    refute Oidc.enabled?()
    refute Oidc.enabled?(:staff)
    refute Oidc.oidc_only?()
    assert Oidc.provider(:staff) == nil
    assert Oidc.provider("staff") == nil
    assert Oidc.issuer(:staff) == nil
    assert Oidc.client_id(:staff) == nil
    assert Oidc.client_secret(:staff) == nil
    assert Oidc.label(:staff) == nil
    assert Oidc.scopes(:staff) == nil
    assert Oidc.policy(:staff) == nil
    assert Oidc.entitlement_claim(:staff) == nil
    assert Oidc.entitlement_value(:staff) == nil
    assert Oidc.tenant_prefix(:staff) == nil
    assert Oidc.provider_worker_name(:staff) == nil
  end

  @tag :oidc
  test "malformed config does not raise" do
    put_config(providers: "not a keyword list")
    assert Oidc.providers() == []

    put_config(providers: ["staff"])
    assert Oidc.providers() == []

    put_config(providers: [staff: "not a keyword list"])
    assert Oidc.providers() == []
  end

  @tag :oidc
  test "a fully configured provider is readable through every accessor" do
    put_config(providers: [staff: @staff])

    assert Oidc.enabled?()
    assert Oidc.enabled?(:staff)
    assert Oidc.enabled?("staff")
    assert Oidc.provider_names() == [:staff]
    assert Oidc.provider(:staff) == @staff
    assert Oidc.provider("staff") == @staff
    assert Oidc.issuer("staff") == "https://idp.example.com/oauth2/openid/keila"
    assert Oidc.client_id("staff") == "keila"
    assert Oidc.client_secret("staff") == "s3cret"
    assert Oidc.label("staff") == "Sign in with Staff SSO"
    assert Oidc.scopes("staff") == ["openid", "email", "profile", "groups"]
    assert Oidc.policy("staff") == :entitlement
    assert Oidc.entitlement_claim("staff") == "keila_role"
    assert Oidc.entitlement_value("staff") == "keila_users"
    assert Oidc.tenant_prefix("staff") == nil
  end

  @tag :oidc
  test "oidc_only? is false when no valid provider exists" do
    put_config(oidc_only: true)
    refute Oidc.oidc_only?()

    put_config(providers: [], oidc_only: true)
    refute Oidc.oidc_only?()

    put_config(providers: [staff: Keyword.delete(@staff, :client_secret)], oidc_only: true)
    refute Oidc.oidc_only?()
  end

  @tag :oidc
  test "oidc_only? is true when enabled alongside a valid provider" do
    put_config(providers: [staff: @staff], oidc_only: true)
    assert Oidc.oidc_only?()
  end

  @tag :oidc
  test "oidc_only? defaults to false for a valid provider" do
    put_config(providers: [staff: @staff])
    refute Oidc.oidc_only?()
  end

  @tag :oidc
  test "a provider missing client_secret is dropped" do
    put_config(providers: [staff: Keyword.delete(@staff, :client_secret)])

    assert Oidc.providers() == []
    refute Oidc.enabled?(:staff)
    refute Oidc.enabled?("staff")
    assert Oidc.provider(:staff) == nil
  end

  @tag :oidc
  test "a provider with an empty issuer is dropped" do
    put_config(providers: [staff: Keyword.put(@staff, :issuer, "")])

    assert Oidc.providers() == []
    refute Oidc.enabled?(:staff)
  end

  @tag :oidc
  test "a provider with an unrecognized policy is dropped" do
    put_config(providers: [staff: Keyword.put(@staff, :policy, :allow_everyone)])

    assert Oidc.providers() == []
    refute Oidc.enabled?(:staff)
  end

  @tag :oidc
  test "an omitted policy defaults to entitlement rather than dropping the provider" do
    put_config(providers: [staff: Keyword.delete(@staff, :policy)])

    assert Oidc.enabled?(:staff)
    assert Oidc.policy(:staff) == :entitlement
  end

  @tag :oidc
  test "tenant_claim defaults to the kanidm groups claim" do
    put_config(providers: [merchant: @merchant])

    assert Oidc.tenant_claim(:merchant) == "groups"
    assert Oidc.tenant_claim(:unconfigured) == nil

    put_config(providers: [merchant: Keyword.put(@merchant, :tenant_claim, "roles")])
    assert Oidc.tenant_claim(:merchant) == "roles"
  end

  @tag :oidc
  test "empty scopes fall back to the defaults so openid is never dropped" do
    put_config(providers: [staff: Keyword.put(@staff, :scopes, [])])

    assert Oidc.scopes(:staff) == ["openid", "email", "profile"]
  end

  @tag :oidc
  test "an invalid provider does not hide its valid siblings" do
    put_config(providers: [broken: Keyword.delete(@staff, :issuer), merchant: @merchant])

    assert Oidc.provider_names() == [:merchant]
    assert Oidc.enabled?()
  end

  @tag :oidc
  test "two providers are exposed in config order with distinct worker names" do
    put_config(providers: [staff: @staff, merchant: @merchant])

    assert Oidc.provider_names() == [:staff, :merchant]
    assert Oidc.policy(:merchant) == :tenant_spn
    assert Oidc.tenant_prefix(:merchant) == "org"

    assert Oidc.provider_worker_name(:staff) != Oidc.provider_worker_name(:merchant)
    assert Oidc.provider_worker_name("staff") == Oidc.provider_worker_name(:staff)
    assert is_atom(Oidc.provider_worker_name(:staff))
  end

  @tag :oidc
  test "the sign-in page withholds staff even when staff IS configured" do
    put_config(providers: [staff: @staff, merchant: @merchant])

    assert Oidc.provider_names() == [:staff, :merchant]
    assert Oidc.login_page_providers() == [:merchant]
    assert Oidc.enabled?(Oidc.staff_provider())
  end

  @tag :oidc
  test "the sign-in page offers nothing rather than staff when staff alone is configured" do
    put_config(providers: [staff: @staff])

    assert Oidc.login_page_providers() == []
    assert Oidc.enabled?()
  end

  @tag :oidc
  test "an unknown binary provider name never creates an atom" do
    put_config(providers: [staff: @staff])

    name = "unconfigured-#{System.unique_integer([:positive])}"

    assert Oidc.provider(name) == nil
    refute Oidc.enabled?(name)
    assert Oidc.issuer(name) == nil
    assert Oidc.label(name) == nil
    assert Oidc.scopes(name) == nil
    assert Oidc.provider_worker_name(name) == nil

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  @tag :oidc
  test "scopes and label fall back to their defaults" do
    put_config(providers: [staff: @staff |> Keyword.delete(:scopes) |> Keyword.delete(:label)])

    assert Oidc.scopes(:staff) == ["openid", "email", "profile"]
    assert Oidc.label(:staff) == "Staff"
    assert Oidc.label("staff") == "Staff"
  end

  describe "cacertfile" do
    @tag :oidc
    test "a provider without one sends no TLS options, leaving the system trust store in play" do
      put_config(providers: [staff: @staff])

      assert Oidc.cacertfile(:staff) == nil
      assert Oidc.request_opts(:staff) == %{}
      assert Oidc.provider_configuration_opts(:staff) == %{}
    end

    @tag :oidc
    test "an empty cacertfile is ignored rather than sent as a path" do
      put_config(providers: [staff: Keyword.put(@staff, :cacertfile, "")])

      assert Oidc.request_opts(:staff) == %{}
    end

    @tag :oidc
    test "a configured cacertfile verifies the peer against exactly that file" do
      put_config(providers: [staff: Keyword.put(@staff, :cacertfile, "/etc/keila/idp-ca.pem")])

      assert %{ssl: ssl} = Oidc.request_opts(:staff)
      assert ssl[:verify] == :verify_peer
      assert ssl[:cacertfile] == "/etc/keila/idp-ca.pem"
      assert Keyword.has_key?(ssl, :customize_hostname_check)
    end

    @tag :oidc
    test "verification is never disabled, whatever the file is set to" do
      put_config(providers: [staff: Keyword.put(@staff, :cacertfile, "/tmp/whatever.pem")])

      assert %{ssl: ssl} = Oidc.request_opts(:staff)
      refute ssl[:verify] == :verify_none
    end

    @tag :oidc
    test "the same options reach the discovery leg, which opens its own connection" do
      put_config(providers: [staff: Keyword.put(@staff, :cacertfile, "/etc/keila/idp-ca.pem")])

      assert %{request_opts: %{ssl: ssl}} = Oidc.provider_configuration_opts(:staff)
      assert ssl[:cacertfile] == "/etc/keila/idp-ca.pem"
    end

    @tag :oidc
    test "an explicit provider_configuration_opts stays the operator's escape hatch" do
      put_config(
        providers: [
          staff:
            @staff
            |> Keyword.put(:cacertfile, "/etc/keila/idp-ca.pem")
            |> Keyword.put(:provider_configuration_opts, %{quirks: %{allow_unsafe_http: true}})
        ]
      )

      opts = Oidc.provider_configuration_opts(:staff)

      assert opts[:quirks] == %{allow_unsafe_http: true}
      assert %{ssl: _} = opts[:request_opts]
    end

    @tag :oidc
    test "an operator's own request_opts wins outright over the derived ones" do
      put_config(
        providers: [
          staff:
            @staff
            |> Keyword.put(:cacertfile, "/etc/keila/idp-ca.pem")
            |> Keyword.put(:provider_configuration_opts, %{request_opts: %{timeout: 1_000}})
        ]
      )

      assert Oidc.provider_configuration_opts(:staff) == %{request_opts: %{timeout: 1_000}}
    end

    @tag :oidc
    test "an unconfigured provider yields no options rather than raising" do
      assert Oidc.cacertfile(:staff) == nil
      assert Oidc.request_opts(:staff) == %{}
      assert Oidc.provider_configuration_opts(:staff) == nil
    end
  end
end
