defmodule Keila.Auth.Oidc do
  @moduledoc """
  Reads and validates the optional OIDC SSO configuration.

  Providers are configured under `config :keila, Keila.Auth.Oidc, providers: [...]`.
  """

  @default_scopes ["openid", "email", "profile"]
  @default_policy :entitlement
  @policies [:entitlement, :pushed]
  @staff_provider :staff

  @spec providers() :: keyword(keyword())
  def providers do
    config()
    |> Keyword.get(:providers, [])
    |> case do
      providers when is_list(providers) -> Enum.filter(providers, &valid_provider?/1)
      _other -> []
    end
  end

  @doc """
  Parses a `KEILA_OIDC_<NAME>_POLICY` value; anything but a current policy refuses boot.
  """
  @spec parse_policy!(String.t(), String.t() | nil) :: atom()
  def parse_policy!(name, value) do
    case value |> to_string() |> String.downcase() do
      "" ->
        @default_policy

      "entitlement" ->
        :entitlement

      "pushed" ->
        :pushed

      other ->
        raise ArgumentError,
              "KEILA_OIDC_#{String.upcase(name)}_POLICY=#{other} is not a policy (entitlement, pushed)"
    end
  end

  @doc """
  Refuses boot on any unknown `KEILA_OIDC_*_POLICY` and while any tenant_spn-era variable is
  still set: a stale config must fail the deploy, not run silently.
  """
  @spec refuse_stale_config!(%{String.t() => String.t()}) :: :ok
  def refuse_stale_config!(env) do
    for {key, value} <- env, [_, name] <- [Regex.run(~r/^KEILA_OIDC_(.+)_POLICY$/, key)] do
      parse_policy!(name, value)
    end

    case env
         |> Map.keys()
         |> Enum.filter(&Regex.match?(~r/^KEILA_OIDC_.+_TENANT_(PREFIX|CLAIM)$/, &1)) do
      [] ->
        :ok

      stale ->
        raise ArgumentError,
              "#{Enum.join(Enum.sort(stale), ", ")} belong to the removed tenant_spn policy; unset them"
    end
  end

  @spec provider_names() :: [atom()]
  def provider_names do
    Enum.map(providers(), fn {name, _opts} -> name end)
  end

  @doc """
  The staff provider, whose door is the unlinked `/staff`.

  Staff and customers authenticate at different IdPs, so a staff button on a
  customer sign-in page is an entrance nobody there can pass.
  """
  @spec staff_provider() :: atom()
  def staff_provider, do: @staff_provider

  @doc """
  What a CUSTOMER-facing sign-in page may offer: every configured provider but staff.
  """
  @spec login_page_providers() :: [atom()]
  def login_page_providers do
    Enum.reject(provider_names(), &(&1 == @staff_provider))
  end

  @spec provider(atom() | binary()) :: keyword() | nil
  def provider(name) do
    case resolve_name(name) do
      nil -> nil
      name -> Keyword.get(providers(), name)
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: providers() != []

  @spec enabled?(atom() | binary()) :: boolean()
  def enabled?(name), do: not is_nil(provider(name))

  @spec oidc_only?() :: boolean()
  def oidc_only? do
    Keyword.get(config(), :oidc_only, false) == true and enabled?()
  end

  @spec issuer(atom() | binary()) :: binary() | nil
  def issuer(name), do: fetch(name, :issuer)

  @spec client_id(atom() | binary()) :: binary() | nil
  def client_id(name), do: fetch(name, :client_id)

  @spec client_secret(atom() | binary()) :: binary() | nil
  def client_secret(name), do: fetch(name, :client_secret)

  @spec policy(atom() | binary()) :: atom() | nil
  def policy(name) do
    with opts when is_list(opts) <- provider(name) do
      Keyword.get(opts, :policy, @default_policy)
    end
  end

  @spec entitlement_claim(atom() | binary()) :: binary() | nil
  def entitlement_claim(name), do: fetch(name, :entitlement_claim)

  @spec entitlement_value(atom() | binary()) :: binary() | nil
  def entitlement_value(name), do: fetch(name, :entitlement_value)

  @spec admin_value(atom() | binary()) :: binary() | nil
  def admin_value(name), do: fetch(name, :admin_value)

  @spec scopes(atom() | binary()) :: [binary()] | nil
  def scopes(name) do
    with opts when is_list(opts) <- provider(name) do
      case Keyword.get(opts, :scopes) do
        [_ | _] = scopes -> scopes
        _other -> @default_scopes
      end
    end
  end

  @spec label(atom() | binary()) :: binary() | nil
  def label(name) do
    with opts when is_list(opts) <- provider(name) do
      Keyword.get(opts, :label) || default_label(resolve_name(name))
    end
  end

  @spec provider_worker_name(atom() | binary()) :: module() | nil
  def provider_worker_name(name) do
    case resolve_name(name) do
      nil -> nil
      name -> Module.concat(__MODULE__.Provider, name)
    end
  end

  @spec cacertfile(atom() | binary()) :: binary() | nil
  def cacertfile(name), do: fetch(name, :cacertfile)

  @doc """
  HTTP options for every call `oidcc` makes to `name` — discovery, JWKS, the
  token exchange and userinfo.

  Empty unless the provider configures `:cacertfile`. Both legs must carry
  these: a token exchange opens its own connection, so an IdP the discovery leg
  could reach still fails there.
  """
  @spec request_opts(atom() | binary()) :: map()
  def request_opts(name) do
    case cacertfile(name) do
      path when is_binary(path) and path != "" -> %{ssl: ssl_opts(path)}
      _other -> %{}
    end
  end

  # `cacertfile` REPLACES the OS trust store rather than adding to it: right for a private IdP,
  # wrong for a public one, which is why it is opt-in per provider.
  defp ssl_opts(cacertfile) do
    [
      verify: :verify_peer,
      cacertfile: cacertfile,
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  @spec provider_configuration_opts(atom() | binary()) :: map() | nil
  def provider_configuration_opts(name) do
    with opts when is_list(opts) <- provider(name) do
      configured =
        case Keyword.get(opts, :provider_configuration_opts) do
          opts when is_map(opts) -> opts
          _other -> %{}
        end

      # An explicit `provider_configuration_opts` wins outright, so an operator keeps the escape
      # hatch for TLS settings `:cacertfile` cannot express.
      case request_opts(name) do
        empty when empty == %{} -> configured
        derived -> Map.merge(%{request_opts: derived}, configured)
      end
    end
  end

  @doc """
  Child specs for the per-provider `Oidcc.ProviderConfiguration.Worker`s.
  """
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    Enum.map(provider_names(), &worker_spec/1)
  end

  # Worker.child_spec/1 hardcodes `id: __MODULE__`, and `backoff_type` defaults
  # to `:stop`, which turns an IdP that is down at boot into a boot failure.
  defp worker_spec(name) do
    Supervisor.child_spec(
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: issuer(name),
         name: provider_worker_name(name),
         backoff_type: :random_exponential,
         backoff_min: 1_000,
         backoff_max: 120_000,
         provider_configuration_opts: provider_configuration_opts(name)
       }},
      id: provider_worker_name(name)
    )
  end

  defp config, do: Application.get_env(:keila, __MODULE__, [])

  defp fetch(name, key) do
    with opts when is_list(opts) <- provider(name) do
      Keyword.get(opts, key)
    end
  end

  defp default_label(name) do
    name |> Atom.to_string() |> String.capitalize()
  end

  defp valid_provider?({name, opts}) when is_atom(name) and is_list(opts) do
    Enum.all?([:issuer, :client_id, :client_secret], fn key ->
      case Keyword.get(opts, key) do
        value when is_binary(value) -> String.trim(value) != ""
        _other -> false
      end
    end) and Keyword.get(opts, :policy, @default_policy) in @policies
  end

  defp valid_provider?(_other), do: false

  defp resolve_name(name) when is_atom(name) do
    if name in provider_names(), do: name
  end

  defp resolve_name(name) when is_binary(name) do
    Enum.find(provider_names(), fn configured -> Atom.to_string(configured) == name end)
  end

  defp resolve_name(_other), do: nil
end
