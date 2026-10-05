defmodule Keila.AuthTest.OidcTenants do
  use Keila.DataCase, async: false

  alias Keila.Accounts
  alias Keila.Auth.OidcTenant
  alias Keila.Auth.Oidc.Tenants
  alias Keila.Auth.UserGroup
  alias Keila.Projects
  alias Keila.Projects.Project

  @issuer "https://idp-a.example.com"
  @other_issuer "https://idp-b.example.com"

  setup do
    {_root, user} = with_seed()
    %{user: user}
  end

  defp project_of(tenant), do: Projects.get_project(tenant.project_id)

  defp membership_count(user_id, group_id) do
    from(ug in UserGroup, where: ug.user_id == ^user_id and ug.group_id == ^group_id)
    |> Repo.aggregate(:count)
  end

  @tag :auth
  test "find_or_create/2 creates an Account, a Project and a mapping row", %{user: user} do
    assert {:ok, tenant} = Tenants.find_or_create(@issuer, "acme")
    assert %OidcTenant{issuer: @issuer, slug: "acme"} = tenant

    assert %Project{name: "acme"} = project = project_of(tenant)
    assert account = Accounts.get_project_account(project.id)
    refute account.id == Accounts.get_user_account(user.id).id
  end

  @tag :auth
  test "find_or_create/2 called twice returns the same tenant and creates one Project" do
    assert {:ok, tenant} = Tenants.find_or_create(@issuer, "acme")
    count = Repo.aggregate(Project, :count)

    assert {:ok, ^tenant} = Tenants.find_or_create(@issuer, "acme")
    assert count == Repo.aggregate(Project, :count)
  end

  @tag :auth
  test "find_or_create/2 returns a mapping row inserted behind its back", %{user: user} do
    {:ok, project} = Projects.create_project(user.id, %{name: "Preexisting"})

    {:ok, existing} =
      %{issuer: @issuer, slug: "acme", project_id: project.id}
      |> OidcTenant.changeset()
      |> Repo.insert()

    count = Repo.aggregate(Project, :count)

    assert {:ok, tenant} = Tenants.find_or_create(@issuer, "acme")
    assert tenant.id == existing.id
    assert tenant.project_id == project.id
    assert count == Repo.aggregate(Project, :count)
  end

  @tag :auth
  test "a duplicate (issuer, slug) insert inside a transaction is a changeset error, not a raise" do
    {:ok, tenant} = Tenants.find_or_create(@issuer, "acme")

    assert {:error, changeset} =
             Repo.transaction(fn ->
               %{issuer: @issuer, slug: "acme", project_id: tenant.project_id}
               |> OidcTenant.changeset()
               |> Repo.insert()
               |> case do
                 {:error, changeset} -> Repo.rollback(changeset)
               end
             end)

    assert %{issuer: ["has already been taken"]} = errors_on(changeset)
  end

  @tag :auth
  test "the same slug at two issuers yields two tenants with two Projects" do
    assert {:ok, tenant_a} = Tenants.find_or_create(@issuer, "acme")
    assert {:ok, tenant_b} = Tenants.find_or_create(@other_issuer, "acme")

    refute tenant_a.id == tenant_b.id
    refute tenant_a.project_id == tenant_b.project_id
  end

  @tag :auth
  test "grant/2 gives real Project access", %{user: user} do
    {:ok, tenant} = Tenants.find_or_create(@issuer, "acme")

    assert :ok = Tenants.grant(user.id, tenant)
    assert %Project{} = Projects.get_user_project(user.id, tenant.project_id)
    assert tenant.project_id in Enum.map(Projects.get_user_projects(user.id), & &1.id)
  end

  @tag :auth
  test "grant/2 twice leaves one membership and access intact", %{user: user} do
    {:ok, tenant} = Tenants.find_or_create(@issuer, "acme")

    assert :ok = Tenants.grant(user.id, tenant)
    assert :ok = Tenants.grant(user.id, tenant)

    assert 1 == membership_count(user.id, project_of(tenant).group_id)
    assert %Project{} = Projects.get_user_project(user.id, tenant.project_id)
  end

  @tag :auth
  test "revoke/2 removes Project access", %{user: user} do
    {:ok, tenant} = Tenants.find_or_create(@issuer, "acme")
    :ok = Tenants.grant(user.id, tenant)

    assert :ok = Tenants.revoke(user.id, tenant)
    assert nil == Projects.get_user_project(user.id, tenant.project_id)
    assert :ok = Tenants.revoke(user.id, tenant)
  end

  @tag :auth
  test "list_user_tenants/2 lists only this issuer's tenants the User belongs to", %{user: user} do
    {:ok, held} = Tenants.find_or_create(@issuer, "acme")
    {:ok, _unheld} = Tenants.find_or_create(@issuer, "globex")
    {:ok, other_issuer} = Tenants.find_or_create(@other_issuer, "acme")
    :ok = Tenants.grant(user.id, held)
    :ok = Tenants.grant(user.id, other_issuer)

    assert [%OidcTenant{slug: "acme"}] = Tenants.list_user_tenants(user.id, @issuer)
  end

  @tag :auth
  test "reconcile/3 grants the asserted slugs and revokes the ones no longer asserted", %{
    user: user
  } do
    assert {:ok, %{granted: granted, revoked: []}} =
             Tenants.reconcile(user.id, @issuer, ["acme", "globex", "acme"])

    assert ["acme", "globex"] == Enum.sort(granted)

    assert {:ok, %{granted: ["initech"], revoked: ["globex"]}} =
             Tenants.reconcile(user.id, @issuer, ["acme", "initech"])

    assert ["acme", "initech"] ==
             user.id |> Tenants.list_user_tenants(@issuer) |> Enum.map(& &1.slug) |> Enum.sort()
  end

  @tag :auth
  test "reconcile/3 leaves the User's own Projects and other issuers' tenants untouched", %{
    user: user
  } do
    {:ok, own_project} = Projects.create_project(user.id, %{name: "Own Project"})
    {:ok, other_tenant} = Tenants.find_or_create(@other_issuer, "acme")
    :ok = Tenants.grant(user.id, other_tenant)
    {:ok, %{granted: ["acme"]}} = Tenants.reconcile(user.id, @issuer, ["acme"])

    assert {:ok, %{granted: [], revoked: ["acme"]}} = Tenants.reconcile(user.id, @issuer, [])

    assert %Project{} = Projects.get_user_project(user.id, own_project.id)
    assert %Project{} = Projects.get_user_project(user.id, other_tenant.project_id)
    assert [%OidcTenant{}] = Tenants.list_user_tenants(user.id, @other_issuer)
  end

  @tag :auth
  test "reconcile/3 with no slugs and no tenants is a no-op", %{user: user} do
    assert {:ok, %{granted: [], revoked: []}} = Tenants.reconcile(user.id, @issuer, [])
  end
end
