defmodule Keila.Auth.Oidc.Login do
  @moduledoc """
  Turns validated OIDC claims into a signed-in Keila User.

  Signature, `iss`, `aud`, `exp` and `nonce` are expected to have been verified
  by `oidcc` already; only claim *content* is interpreted here.

  The entitlement gate is evaluated on every login, not just when provisioning:
  the IdP is authoritative, so a linked User whose claims no longer entitle them
  is refused rather than admitted.
  """

  import Ecto.Query

  alias Keila.Auth
  alias Keila.Auth.Oidc
  alias Keila.Auth.Oidc.Claims
  alias Keila.Auth.OidcIdentity
  alias Keila.Auth.User
  alias Keila.Repo

  @doc """
  Signs in — provisioning on first sight unless the provider's policy is `:pushed` —
  the User `claims` identifies at `provider`.
  """
  @spec handle_claims(atom() | binary(), map()) :: {:ok, User.t()} | {:error, atom()}
  def handle_claims(provider, claims) do
    if Oidc.enabled?(provider) do
      do_handle_claims(provider, claims)
    else
      {:error, :unknown_provider}
    end
  end

  @doc """
  Whether the User's credentials are the IdP's to issue.

  True only while a *currently configured* provider still owns one of the User's
  identities, so removing OIDC from the configuration restores the local password
  path rather than stranding accounts that never had one.
  """
  @spec idp_managed?(User.id()) :: boolean()
  def idp_managed?(user_id) do
    issuers =
      Oidc.provider_names()
      |> Enum.map(&Oidc.issuer/1)
      |> Enum.filter(&is_binary/1)

    issuers != [] and
      Repo.exists?(from(i in OidcIdentity, where: i.user_id == ^user_id and i.issuer in ^issuers))
  end

  defp do_handle_claims(provider, claims) do
    with {:ok, iss, sub} <- identity(provider, claims),
         :ok <- gate(provider, claims),
         {:ok, user} <- find_or_provision(provider, iss, sub, claims),
         :ok <- sync_admin(provider, user, claims) do
      {:ok, user}
    end
  end

  # The issuer comes from OUR configuration, never from the claims: `oidcc` has
  # already proven the id_token belongs to this provider, and a claims-supplied
  # `iss` would let one provider mint identities in another's namespace.
  defp identity(provider, %{"sub" => sub}) when is_binary(sub) and sub != "" do
    case Oidc.issuer(provider) do
      iss when is_binary(iss) and iss != "" -> {:ok, iss, sub}
      _other -> {:error, :unknown_provider}
    end
  end

  defp identity(_provider, _claims), do: {:error, :invalid_claims}

  defp gate(provider, claims) do
    case Oidc.policy(provider) do
      :entitlement -> entitlement_gate(provider, claims)
      :pushed -> :ok
    end
  end

  # Both halves of the pair are required. A claim name without a value would otherwise
  # admit everyone at the IdP holding any value for it, while omitting the name refuses
  # everyone — the half-configuration that reads as deliberate must not be the open one.
  defp entitlement_gate(provider, claims) do
    case {Oidc.entitlement_claim(provider), Oidc.entitlement_value(provider)} do
      {claim, _value} when claim in [nil, ""] ->
        {:error, :provisioning_disabled}

      {_claim, value} when value in [nil, ""] ->
        {:error, :provisioning_disabled}

      {claim, value} ->
        if Claims.entitled?(claims, claim, value),
          do: :ok,
          else: {:error, :not_entitled}
    end
  end

  # A pushed provider's users exist only through Keila.Tenancy, which also owns their mail and
  # decides who may enter: someone holding no live shop is refused like a stranger.
  defp find_or_provision(provider, iss, sub, claims) do
    case {Repo.get_by(OidcIdentity, issuer: iss, subject: sub), Oidc.policy(provider)} do
      {%OidcIdentity{user_id: user_id}, :pushed} -> live_member(user_id)
      {%OidcIdentity{user_id: user_id}, _policy} -> {:ok, Auth.get_user(user_id)}
      {nil, :pushed} -> {:error, :not_entitled}
      {nil, _policy} -> provision(iss, sub, claims)
    end
  end

  defp live_member(user_id) do
    if Keila.Tenancy.holds_live_shop?(user_id),
      do: {:ok, Auth.get_user(user_id)},
      else: {:error, :not_entitled}
  end

  defp provision(iss, sub, claims) do
    with {:ok, email} <- email(claims),
         :ok <- email_verified(claims),
         :ok <- email_available(email) do
      insert(iss, sub, email, claims)
    end
  end

  defp email(%{"email" => email}) when is_binary(email) and email != "", do: {:ok, email}
  defp email(_claims), do: {:error, :missing_email}

  # Only an affirmative `true` counts: several IdPs serialize this claim as a
  # string, and `"false"` must not read as verified.
  defp email_verified(%{"email_verified" => verified}) when verified != true,
    do: {:error, :email_not_verified}

  defp email_verified(_claims), do: :ok

  defp email_available(email) do
    from(u in User, where: fragment("lower(?) = lower(?)", u.email, ^email))
    |> Repo.exists?()
    |> case do
      true -> {:error, :email_exists}
      false -> :ok
    end
  end

  defp insert(iss, sub, email, claims) do
    Repo.transaction(fn ->
      with {:ok, user} <- create_user(email, claims),
           {:ok, _identity} <- insert_identity(iss, sub, user) do
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, _reason} -> resolve_conflict(iss, sub)
    end
  end

  # Losing a concurrent first-login race is a legitimate login, not an error:
  # the winner's identity row is now present, so return its User.
  defp resolve_conflict(iss, sub) do
    case Repo.get_by(OidcIdentity, issuer: iss, subject: sub) do
      %OidcIdentity{user_id: user_id} -> {:ok, Auth.get_user(user_id)}
      nil -> {:error, :provisioning_failed}
    end
  end

  defp create_user(email, claims) do
    %{
      "email" => email,
      "given_name" => claim_string(claims, "given_name"),
      "family_name" => claim_string(claims, "family_name"),
      "locale" => Gettext.get_locale()
    }
    |> Auth.create_user(changeset: :oidc, skip_activation_email: true)
  end

  defp insert_identity(iss, sub, user) do
    %{issuer: iss, subject: sub, user_id: user.id}
    |> OidcIdentity.changeset()
    |> Repo.insert()
  end

  defp claim_string(claims, key) do
    case Map.get(claims, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  # Root-role membership tracks `admin_value` on every sign-in, both ways: a provider that
  # configures it OWNS admin for its users, so leaving the group at the IdP revokes on next login.
  defp sync_admin(provider, user, claims) do
    case {Oidc.policy(provider), Oidc.admin_value(provider)} do
      {:entitlement, value} when is_binary(value) and value != "" ->
        entitled? = Claims.entitled?(claims, Oidc.entitlement_claim(provider), value)
        reconcile_admin(user, entitled?)

      _other ->
        :ok
    end
  end

  defp reconcile_admin(user, entitled?) do
    root_group = Auth.root_group()

    case Repo.get_by(Auth.Role, name: "root") do
      nil ->
        {:error, :admin_sync_failed}

      role when entitled? ->
        Auth.add_user_group_role(user.id, root_group.id, role.id)

      role ->
        Auth.remove_user_group_role(user.id, root_group.id, role.id)
    end
  end
end
