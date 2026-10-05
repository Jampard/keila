defmodule Keila.Auth.Oidc.Tenants do
  @moduledoc """
  Maps IdP tenant identifiers to Keila Projects.

  A tenant is keyed on `{issuer, slug}` so that renaming a provider in the
  configuration cannot orphan its Projects. The tenant’s Account is not stored;
  it is always re-derived with `Keila.Accounts.get_project_account/1`.
  """

  use Keila.Repo
  alias Keila.Accounts
  alias Keila.Auth
  alias Keila.Auth.OidcTenant
  alias Keila.Auth.UserGroup
  alias Keila.Projects.Project

  @doc """
  Returns the `OidcTenant` for `issuer` and `slug`, creating its Account,
  Project and mapping row if it doesn’t exist yet.

  Does not grant any User access to the Project; use `grant/2` for that.
  """
  @spec find_or_create(String.t(), String.t()) :: {:ok, OidcTenant.t()} | {:error, term()}
  def find_or_create(issuer, slug)
      when not (is_binary(slug) and byte_size(slug) in 1..255) or
             not (is_binary(issuer) and byte_size(issuer) in 1..255) do
    {:error, :invalid_tenant}
  end

  def find_or_create(issuer, slug) do
    case get(issuer, slug) do
      tenant = %OidcTenant{} -> {:ok, tenant}
      nil -> create(issuer, slug)
    end
  end

  @doc """
  Grants the User specified by `user_id` access to the tenant’s Project.

  This function is idempotent.
  """
  @spec grant(Auth.User.id(), OidcTenant.t()) :: :ok | {:error, Ecto.Changeset.t()}
  def grant(user_id, tenant = %OidcTenant{}) do
    Auth.add_user_to_group(user_id, project_group_id(tenant))
  end

  @doc """
  Removes the access of the User specified by `user_id` to the tenant’s Project.

  This function is idempotent.
  """
  @spec revoke(Auth.User.id(), OidcTenant.t()) :: :ok
  def revoke(user_id, tenant = %OidcTenant{}) do
    Auth.remove_user_from_group(user_id, project_group_id(tenant))
  end

  @doc """
  Returns every `OidcTenant` of `issuer` whose Project the User specified by
  `user_id` is currently a member of.

  This is the only set `reconcile/3` is allowed to revoke from.
  """
  @spec list_user_tenants(Auth.User.id(), String.t()) :: [OidcTenant.t()]
  def list_user_tenants(user_id, issuer) do
    from(t in OidcTenant,
      join: p in Project,
      on: p.id == t.project_id,
      join: ug in UserGroup,
      on: ug.group_id == p.group_id,
      where: t.issuer == ^issuer and ug.user_id == ^user_id
    )
    |> Repo.all()
  end

  @doc """
  Aligns the tenant memberships of the User specified by `user_id` at `issuer`
  with `slugs`, the set of tenants the IdP currently asserts.

  Only Projects registered in `oidc_tenants` for `issuer` are ever revoked;
  Projects the User owns, joined manually, or holds at another issuer are left
  untouched.
  """
  @spec reconcile(Auth.User.id(), String.t(), [String.t()]) ::
          {:ok, %{granted: [String.t()], revoked: [String.t()]}} | {:error, term()}
  def reconcile(user_id, issuer, slugs) do
    slugs = Enum.uniq(slugs)
    held = list_user_tenants(user_id, issuer)
    held_slugs = MapSet.new(held, & &1.slug)

    # Revoke first: a grant that fails must never leave withdrawn memberships in
    # place, which is what an unprocessable entry in the claim would otherwise do.
    revoked = revoke_stale(user_id, held, slugs)

    case grant_all(user_id, issuer, slugs, held_slugs) do
      {:ok, granted} -> {:ok, %{granted: granted, revoked: revoked}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp grant_all(user_id, issuer, slugs, held_slugs) do
    Enum.reduce_while(slugs, {:ok, []}, fn slug, {:ok, granted} ->
      with {:ok, tenant} <- find_or_create(issuer, slug),
           :ok <- grant(user_id, tenant) do
        if MapSet.member?(held_slugs, slug),
          do: {:cont, {:ok, granted}},
          else: {:cont, {:ok, [slug | granted]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, granted} -> {:ok, Enum.reverse(granted)}
      error -> error
    end
  end

  defp revoke_stale(user_id, held, slugs) do
    held
    |> Enum.reject(&(&1.slug in slugs))
    |> Enum.map(fn tenant ->
      :ok = revoke(user_id, tenant)
      tenant.slug
    end)
  end

  defp get(issuer, slug) do
    Repo.get_by(OidcTenant, issuer: issuer, slug: slug)
  end

  defp create(issuer, slug) do
    Repo.transaction(fn ->
      with {:ok, account} <- Accounts.create_account(),
           {:ok, group} <- Auth.create_group(%{parent_id: account.group_id}),
           {:ok, project} <- insert_project(group, slug),
           {:ok, tenant} <- insert_tenant(issuer, slug, project) do
        tenant
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, tenant} -> {:ok, tenant}
      {:error, reason} -> resolve_conflict(issuer, slug, reason)
    end
  end

  defp resolve_conflict(issuer, slug, reason) do
    case get(issuer, slug) do
      tenant = %OidcTenant{} -> {:ok, tenant}
      nil -> {:error, reason}
    end
  end

  defp insert_project(group, slug) do
    %{"name" => slug, "group_id" => group.id}
    |> Project.creation_changeset()
    |> Repo.insert()
  end

  defp insert_tenant(issuer, slug, project) do
    %{issuer: issuer, slug: slug, project_id: project.id}
    |> OidcTenant.changeset()
    |> Repo.insert()
  end

  defp project_group_id(%OidcTenant{project_id: project_id}) do
    from(p in Project, where: p.id == ^project_id, select: p.group_id)
    |> Repo.one()
  end
end
