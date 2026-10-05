defmodule Keila.Auth.OidcLoginTest do
  use Keila.DataCase, async: false

  alias Keila.Accounts
  alias Keila.Auth
  alias Keila.Auth.Oidc
  alias Keila.Auth.Oidc.Login
  alias Keila.Auth.OidcIdentity
  alias Keila.Auth.User
  alias Keila.Projects

  @staff_issuer "https://idp.example.com/oauth2/openid/keila"
  @merchant_issuer "https://shop.example.com/oidc"

  @staff [
    issuer: @staff_issuer,
    client_id: "keila",
    client_secret: "s3cret",
    policy: :entitlement,
    entitlement_claim: "keila_role",
    entitlement_value: "keila_users"
  ]

  @merchant [
    issuer: @merchant_issuer,
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
    with_seed()

    :ok
  end

  defp put_config(config), do: Application.put_env(:keila, Oidc, config)

  defp counts do
    %{users: Repo.aggregate(User, :count), identities: Repo.aggregate(OidcIdentity, :count)}
  end

  defp staff_claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @staff_issuer,
        "sub" => "sub-alice",
        "email" => "alice@example.com",
        "keila_role" => "keila_users"
      },
      overrides
    )
  end

  defp merchant_claims(groups, overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @merchant_issuer,
        "sub" => "sub-mia",
        "email" => "mia@example.com",
        "groups" => groups
      },
      overrides
    )
  end

  defp project_names(user_id) do
    user_id |> Projects.get_user_projects() |> Enum.map(& &1.name) |> Enum.sort()
  end

  @tag :oidc
  test "an entitled subject is provisioned as an activated, password-less User with its own Account" do
    put_config(providers: [staff: @staff])

    claims = staff_claims(%{"given_name" => "Alice", "family_name" => "Doe"})
    assert {:ok, user} = Login.handle_claims(:staff, claims)

    assert %User{email: "alice@example.com", given_name: "Alice", family_name: "Doe"} = user
    assert %DateTime{} = user.activated_at
    assert is_nil(user.password_hash)

    assert %OidcIdentity{user_id: user_id} =
             Repo.get_by(OidcIdentity, issuer: @staff_issuer, subject: "sub-alice")

    assert user_id == user.id
    assert %{id: _} = Accounts.get_user_account(user.id)
  end

  @tag :oidc
  test "a repeat login for the same issuer and subject returns the same User and writes no rows" do
    put_config(providers: [staff: @staff])

    assert {:ok, user} = Login.handle_claims(:staff, staff_claims())
    before = counts()

    assert {:ok, same_user} = Login.handle_claims(:staff, staff_claims())
    assert same_user.id == user.id
    assert counts() == before
  end

  @tag :oidc
  test "claims failing the entitlement gate are refused and write no rows" do
    put_config(providers: [staff: @staff])
    before = counts()

    assert {:error, :not_entitled} =
             Login.handle_claims(:staff, staff_claims(%{"keila_role" => "some_other_role"}))

    assert counts() == before
  end

  @tag :oidc
  test "an unconfigured entitlement_claim closes the gate rather than opening it" do
    put_config(providers: [staff: Keyword.delete(@staff, :entitlement_claim)])
    before = counts()

    assert {:error, :provisioning_disabled} = Login.handle_claims(:staff, staff_claims())
    assert counts() == before
  end

  @tag :oidc
  test "entitlement revocation at the IdP refuses an already linked User" do
    put_config(providers: [staff: @staff])

    assert {:ok, _user} = Login.handle_claims(:staff, staff_claims())

    assert {:error, :not_entitled} =
             Login.handle_claims(:staff, staff_claims(%{"keila_role" => "revoked"}))
  end

  @tag :oidc
  test "the entitlement value is matched in both a string claim and a list claim" do
    put_config(providers: [staff: @staff])

    assert {:ok, string_user} = Login.handle_claims(:staff, staff_claims())

    list_claims =
      staff_claims(%{
        "sub" => "sub-bob",
        "email" => "bob@example.com",
        "keila_role" => ["idm_all_persons", "keila_users"]
      })

    assert {:ok, list_user} = Login.handle_claims(:staff, list_claims)
    refute list_user.id == string_user.id
  end

  @tag :oidc
  test "a provisioned User cannot sign in with a password" do
    put_config(providers: [staff: @staff])

    assert {:ok, user} = Login.handle_claims(:staff, staff_claims())

    assert {:error, %Ecto.Changeset{}} =
             Auth.find_user_by_credentials(%{
               "email" => user.email,
               "password" => "anything at all"
             })
  end

  @tag :oidc
  test "an email claim that is not a valid address fails provisioning without writing rows" do
    put_config(providers: [staff: @staff])
    before = counts()

    assert {:error, :provisioning_failed} =
             Login.handle_claims(:staff, staff_claims(%{"email" => "not-an-address"}))

    assert before == counts()
  end

  @tag :oidc
  test "an existing address blocks provisioning even when the claim differs only in case" do
    put_config(providers: [staff: @staff])
    insert!(:user, email: "Foo@Bar.com")
    before = counts()

    assert {:error, :email_exists} =
             Login.handle_claims(:staff, staff_claims(%{"email" => "foo@bar.com"}))

    assert counts() == before
  end

  @tag :oidc
  test "claims without an email are refused and write no rows" do
    put_config(providers: [staff: @staff])
    before = counts()

    assert {:error, :missing_email} =
             Login.handle_claims(:staff, staff_claims() |> Map.delete("email"))

    assert {:error, :missing_email} = Login.handle_claims(:staff, staff_claims(%{"email" => ""}))
    assert counts() == before
  end

  @tag :oidc
  test "an explicit email_verified false is refused while an absent claim provisions" do
    put_config(providers: [staff: @staff])
    before = counts()

    assert {:error, :email_not_verified} =
             Login.handle_claims(:staff, staff_claims(%{"email_verified" => false}))

    assert counts() == before

    assert {:ok, %User{}} = Login.handle_claims(:staff, staff_claims())
  end

  @tag :oidc
  test "a tenant login creates the tenant Projects and grants access to them" do
    put_config(providers: [merchant: @merchant])

    groups = ["org.acme.admin@idm.example.com", "org.globex.viewer@idm.example.com"]
    assert {:ok, user} = Login.handle_claims(:merchant, merchant_claims(groups))

    assert ["acme", "globex"] == project_names(user.id)
  end

  @tag :oidc
  test "a later login with fewer tenants revokes the dropped one and keeps the rest" do
    put_config(providers: [merchant: @merchant])

    groups = ["org.acme.admin@idm.example.com", "org.globex.viewer@idm.example.com"]
    assert {:ok, user} = Login.handle_claims(:merchant, merchant_claims(groups))
    assert ["acme", "globex"] == project_names(user.id)

    smaller = merchant_claims(["org.acme.admin@idm.example.com"])
    assert {:ok, same_user} = Login.handle_claims(:merchant, smaller)

    assert same_user.id == user.id
    assert ["acme"] == project_names(user.id)
  end

  @tag :oidc
  test "a groups claim with no matching tenant entry is refused and writes no rows" do
    put_config(providers: [merchant: @merchant])
    before = counts()

    groups = ["idm_all_persons@idm.example.com", "org.broken@idm.example.com"]
    assert {:error, :not_entitled} = Login.handle_claims(:merchant, merchant_claims(groups))

    assert counts() == before
  end

  @tag :oidc
  test "a kanidm groups claim mixing UUIDs and SPNs grants exactly the SPN tenants" do
    put_config(providers: [merchant: @merchant])

    groups = [
      "4d21d04a-dc0d-42eb-96f8-1e5d1a1a1234",
      "org.acme.admin@idm.example.com",
      "idm_all_persons@idm.example.com",
      "org.globex.viewer@idm.example.com"
    ]

    assert {:ok, user} = Login.handle_claims(:merchant, merchant_claims(groups))
    assert ["acme", "globex"] == project_names(user.id)
  end

  @tag :oidc
  test "the same subject at two issuers yields two distinct Users" do
    put_config(providers: [staff: @staff, other: Keyword.put(@staff, :issuer, "https://other")])

    assert {:ok, staff_user} = Login.handle_claims(:staff, staff_claims())

    other_claims =
      staff_claims(%{"iss" => "https://other", "email" => "alice@other.example.com"})

    assert {:ok, other_user} = Login.handle_claims(:other, other_claims)
    refute other_user.id == staff_user.id
  end

  @tag :oidc
  test "editing a provider's configured issuer orphans its identities and locks every user out" do
    put_config(providers: [staff: @staff])

    assert {:ok, user} = Login.handle_claims(:staff, staff_claims())
    assert Repo.get_by(OidcIdentity, issuer: @staff_issuer, subject: "sub-alice")

    migrated = "https://idp.example.net/oauth2/openid/keila"
    put_config(providers: [staff: Keyword.put(@staff, :issuer, migrated)])

    assert {:error, :email_exists} =
             Login.handle_claims(:staff, staff_claims(%{"iss" => migrated}))

    assert Repo.aggregate(OidcIdentity, :count) == 1
    assert is_nil(Repo.get_by(OidcIdentity, issuer: migrated, subject: "sub-alice"))
    assert Repo.get(User, user.id)
  end

  @tag :oidc
  test "an entitlement_claim without an entitlement_value closes the gate rather than opening it" do
    put_config(providers: [staff: Keyword.delete(@staff, :entitlement_value)])
    before = counts()

    assert {:error, :provisioning_disabled} = Login.handle_claims(:staff, staff_claims())

    assert {:error, :provisioning_disabled} =
             Login.handle_claims(:staff, staff_claims(%{"keila_role" => "anything_at_all"}))

    assert counts() == before
  end

  @tag :oidc
  test "idp_managed? holds while the issuer is configured and lapses when it is removed" do
    put_config(providers: [staff: @staff])

    assert {:ok, user} = Login.handle_claims(:staff, staff_claims())
    assert Login.idp_managed?(user.id)

    put_config(providers: [])
    refute Login.idp_managed?(user.id)

    put_config(providers: [staff: Keyword.put(@staff, :issuer, "https://elsewhere.example.com")])
    refute Login.idp_managed?(user.id)
  end

  @tag :oidc
  test "a User with no OIDC identity is not idp_managed" do
    put_config(providers: [staff: @staff])

    {:ok, user} =
      Auth.create_user(%{"email" => "local@example.com", "password" => "BatteryHorse1"})

    refute Login.idp_managed?(user.id)
  end

  @tag :oidc
  test "an unconfigured provider is rejected before any claim is interpreted" do
    put_config(providers: [staff: @staff])
    before = counts()

    assert {:error, :unknown_provider} = Login.handle_claims(:merchant, staff_claims())
    assert {:error, :unknown_provider} = Login.handle_claims("merchant", staff_claims())
    assert counts() == before
  end

  @tag :oidc
  test "a claims-supplied iss cannot mint an identity in another provider's namespace" do
    put_config(providers: [staff: @staff, merchant: @merchant])

    {:ok, staff_user} = Login.handle_claims(:staff, staff_claims(%{"sub" => "shared-sub"}))

    forged =
      merchant_claims(["org.acme.admin"], %{"iss" => @staff_issuer, "sub" => "shared-sub"})

    {:ok, merchant_user} = Login.handle_claims(:merchant, forged)

    refute merchant_user.id == staff_user.id

    assert Repo.get_by(OidcIdentity, issuer: @merchant_issuer, subject: "shared-sub")
    assert Repo.aggregate(OidcIdentity, :count) == 2
  end

  @tag :oidc
  test "an over-long given_name is refused rather than raising" do
    put_config(providers: [staff: @staff])
    before = counts()

    assert {:error, :provisioning_failed} =
             Login.handle_claims(
               :staff,
               staff_claims(%{"given_name" => String.duplicate("A", 100)})
             )

    assert before == counts()
  end

  @tag :oidc
  test "an over-long sub is refused rather than raising" do
    put_config(providers: [staff: @staff])
    before = counts()

    assert {:error, :provisioning_failed} =
             Login.handle_claims(:staff, staff_claims(%{"sub" => String.duplicate("s", 300)}))

    assert before == counts()
  end

  @tag :oidc
  test "email_verified as the string \"false\" is not treated as verified" do
    put_config(providers: [staff: @staff])
    before = counts()

    assert {:error, :email_not_verified} =
             Login.handle_claims(:staff, staff_claims(%{"email_verified" => "false"}))

    assert before == counts()
  end

  defp admin?(user_id) do
    Auth.has_permission?(user_id, Auth.root_group().id, "administer_keila")
  end

  @tag :oidc
  test "an admin_value holder gains administer_keila and a plain member does not" do
    put_config(providers: [staff: Keyword.put(@staff, :admin_value, "keila_admins")])

    plain = staff_claims(%{"keila_role" => ["keila_users"]})
    assert {:ok, user} = Login.handle_claims(:staff, plain)
    refute admin?(user.id)

    admin_claims =
      staff_claims(%{
        "sub" => "sub-carol",
        "email" => "carol@example.com",
        "keila_role" => ["keila_users", "keila_admins"]
      })

    assert {:ok, admin} = Login.handle_claims(:staff, admin_claims)
    assert admin?(admin.id)
  end

  @tag :oidc
  test "leaving the admin group at the IdP revokes administer_keila at the next sign-in" do
    put_config(providers: [staff: Keyword.put(@staff, :admin_value, "keila_admins")])

    elevated = staff_claims(%{"keila_role" => ["keila_users", "keila_admins"]})
    assert {:ok, user} = Login.handle_claims(:staff, elevated)
    assert admin?(user.id)

    demoted = staff_claims(%{"keila_role" => ["keila_users"]})
    assert {:ok, same_user} = Login.handle_claims(:staff, demoted)
    assert same_user.id == user.id
    refute admin?(user.id)
  end

  @tag :oidc
  test "without admin_value nobody is granted and an existing grant is left alone" do
    put_config(providers: [staff: @staff])

    assert {:ok, user} = Login.handle_claims(:staff, staff_claims())
    refute admin?(user.id)

    root = Auth.root_group()
    role = Repo.get_by(Auth.Role, name: "root")
    :ok = Auth.add_user_group_role(user.id, root.id, role.id)

    assert {:ok, _user} = Login.handle_claims(:staff, staff_claims())
    assert admin?(user.id)
  end

  @tag :oidc
  test "admin_value on a tenant_spn provider is inert" do
    put_config(providers: [merchant: Keyword.put(@merchant, :admin_value, "keila_admins")])

    groups = ["org.acme.admin@idm.example.com", "keila_admins"]
    assert {:ok, user} = Login.handle_claims(:merchant, merchant_claims(groups))
    refute admin?(user.id)
  end

  @tag :oidc
  test "an unprocessable tenant entry does not block revoking withdrawn tenants" do
    put_config(providers: [merchant: @merchant])

    {:ok, user} =
      Login.handle_claims(:merchant, merchant_claims(["org.acme.admin", "org.globex.admin"]))

    assert ["acme", "globex"] == project_names(user.id)

    poison = "org.#{String.duplicate("a", 300)}.admin"
    Login.handle_claims(:merchant, merchant_claims([poison]))

    assert [] == project_names(user.id)
  end
end
