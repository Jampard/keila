defmodule Keila.Auth.Oidc.Claims do
  @moduledoc """
  Pure functions for interpreting OIDC claims maps.

  Claims are assumed to already be validated (signature, `iss`, `aud`, `exp`,
  `nonce`) by the `oidcc` library before reaching this module; only claim
  *content* is interpreted here. Input is never trusted to be well-shaped —
  every function degrades to "no access" instead of raising.
  """

  @doc """
  Extracts a claim's values as a list of strings.

  A string claim yields a single-element list; a list claim yields its
  binary elements, in order, with non-binary elements dropped.
  """
  @spec values(map(), binary() | nil) :: [binary()]
  def values(_claims, claim_name) when claim_name in [nil, ""], do: []

  def values(claims, claim_name) when is_binary(claim_name) do
    case Map.get(claims, claim_name) do
      value when is_binary(value) -> [value]
      value when is_list(value) -> Enum.filter(value, &is_binary/1)
      _ -> []
    end
  end

  def values(_claims, _claim_name), do: []

  @doc """
  Checks whether `claims` grants membership via `claim_name`.

  With `required_value` `nil`/`""`, this is a mere presence check. Otherwise
  it is an exact, case-sensitive match against one of the claim's values.
  """
  @spec entitled?(map(), binary() | nil, binary() | nil) :: boolean()
  def entitled?(_claims, claim_name, _required_value) when claim_name in [nil, ""], do: false

  def entitled?(claims, claim_name, required_value) when required_value in [nil, ""] do
    values(claims, claim_name) != []
  end

  def entitled?(claims, claim_name, required_value) do
    required_value in values(claims, claim_name)
  end

  @doc """
  Parses `<prefix>.<slug>.<role>[@domain]` tenant entitlements out of a group
  claim, deduplicated and in first-seen order.
  """
  @spec tenant_grants(map(), binary() | nil, binary() | nil) :: [{binary(), binary()}]
  def tenant_grants(_claims, claim_name, _prefix) when claim_name in [nil, ""], do: []
  def tenant_grants(_claims, _claim_name, prefix) when prefix in [nil, ""], do: []

  def tenant_grants(claims, claim_name, prefix) do
    claims
    |> values(claim_name)
    |> Enum.map(&parse_tenant_grant(&1, prefix))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  The deduplicated tenant slugs from `tenant_grants/3`, in first-seen order.
  """
  @spec tenant_slugs(map(), binary() | nil, binary() | nil) :: [binary()]
  def tenant_slugs(claims, claim_name, prefix) do
    claims
    |> tenant_grants(claim_name, prefix)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  defp parse_tenant_grant(entry, prefix) do
    [local | _] = String.split(entry, "@", parts: 2)

    with true <- local != "",
         [^prefix, slug, role] <- String.split(local, "."),
         true <- slug != "" and role != "" do
      {slug, role}
    else
      _ -> nil
    end
  end
end
