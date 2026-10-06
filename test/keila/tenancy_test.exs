defmodule Keila.TenancyTest do
  use Keila.DataCase, async: false

  alias Keila.Accounts
  alias Keila.Accounts.Account
  alias Keila.Auth
  alias Keila.Auth.{Oidc, OidcIdentity, User}
  alias Keila.Auth.Oidc.Login
  alias Keila.{Mailings, Projects, Tenancy}
  alias Keila.Tenancy.Tenancy, as: Row

  @issuer "https://shop.example.com/oidc"
  @merchant [issuer: @issuer, client_id: "keila-merchant", client_secret: "sh0p", policy: :pushed]

  setup do
    previous = Application.get_env(:keila, Oidc)
    on_exit(fn -> Application.put_env(:keila, Oidc, previous || []) end)
    Application.put_env(:keila, Oidc, providers: [merchant: @merchant])
    with_seed()
    :ok
  end

  defp member(sub), do: %{sub: sub, mail: "#{sub}@shop.example.com", role: "merchant"}

  defp state(version, state, members, name \\ "Acme") do
    %{version: version, state: state, name: name, domains: ["acme.example.com"], members: members}
  end

  defp push!(slug, version, st, members) do
    Tenancy.apply_state(slug, state(version, st, members))
  end

  defp subs(slug) do
    {:ok, %{members: members}} = Tenancy.read(slug)
    Enum.map(members, & &1.sub)
  end

  defp user_of(sub) do
    Repo.get_by!(OidcIdentity, issuer: @issuer, subject: sub).user_id
  end

  defp project_of(slug), do: Repo.get_by!(Row, slug: slug).project_id

  defp encode(body), do: Jason.encode!(body)

  describe "parse/1 is strict and names the refused field" do
    @valid %{
      "version" => 1,
      "state" => "live",
      "name" => "Acme",
      "domains" => ["acme.example.com"],
      "members" => [%{"sub" => "s1", "mail" => "a@b.c", "role" => "merchant"}]
    }

    test "a v1 body parses" do
      assert {:ok, %{version: 1, members: [%{sub: "s1"}]}} = Tenancy.parse(encode(@valid))
    end

    test "refuses each malformed field by name" do
      for {what, change, error} <- [
            {"a field outside v1", &Map.put(&1, "tools", []), "tools: is not a v1 field"},
            {"a member field outside v1",
             &put_in(&1, ["members"], [
               %{"sub" => "s", "mail" => "a@b", "role" => "merchant", "name" => "x"}
             ]), "members[0].name: is not a v1 field"},
            {"a string version", &Map.put(&1, "version", "2"),
             "version: must be a positive integer"},
            {"version 0", &Map.put(&1, "version", 0), "version: must be a positive integer"},
            {"version 2.5", &Map.put(&1, "version", 2.5), "version: must be a positive integer"},
            {"an unknown state", &Map.put(&1, "state", "gone"),
             "state: must be one of live, suspended, purged"},
            {"a blank name", &Map.put(&1, "name", "  "), "name: must be a non-empty string"},
            {"a missing name", &Map.delete(&1, "name"), "name: must be a non-empty string"},
            {"a blank domain", &Map.put(&1, "domains", [" "]),
             "domains[0]: must be a non-empty string"},
            {"an unknown role",
             &put_in(&1, ["members"], [%{"sub" => "s", "mail" => "a@b", "role" => "admin"}]),
             "members[0].role: must be one of merchant"},
            {"a bare mail",
             &put_in(&1, ["members"], [%{"sub" => "s", "mail" => "ab", "role" => "merchant"}]),
             "members[0].mail: must be an address"},
            {"a blank sub",
             &put_in(&1, ["members"], [%{"sub" => " ", "mail" => "a@b", "role" => "merchant"}]),
             "members[0].sub: must be a non-empty string"},
            {"a repeated sub",
             &put_in(&1, ["members"], [
               %{"sub" => "s", "mail" => "a@b", "role" => "merchant"},
               %{"sub" => "s", "mail" => "c@d", "role" => "merchant"}
             ]), "members[1].sub: repeats s"}
          ] do
        assert {what, {:error, error}} == {what, Tenancy.parse(encode(change.(@valid)))}
      end
    end

    test "refuses a body that is not JSON, or not an object" do
      assert {:error, "body: not JSON"} = Tenancy.parse("{not json")
      assert {:error, "body: must be an object"} = Tenancy.parse("[]")
    end

    test "a slug must be a DNS label" do
      assert Tenancy.valid_slug?("acme-2")
      refute Tenancy.valid_slug?("Acme")
      refute Tenancy.valid_slug?("-acme")
      refute Tenancy.valid_slug?(String.duplicate("a", 64))
    end
  end

  describe "apply_state/2" do
    test "a live push creates the shop, its members, and reads back as pushed" do
      assert {:ok, :applied} = push!("acme", 1, "live", [member("s1"), member("s2")])

      assert {:ok, %{version: 1, state: "live"}} = Tenancy.read("acme")
      assert subs("acme") == ["s1", "s2"]
      assert [%{slug: "acme", version: 1}] = Tenancy.list()
      assert %Projects.Project{name: "Acme"} = Projects.get_project(project_of("acme"))
      assert %User{email: "s1@shop.example.com"} = Auth.get_user(user_of("s1"))
    end

    test "the same or a lower version is ignored" do
      push!("acme", 3, "live", [member("s1")])

      assert {:ok, :ignored} = push!("acme", 3, "live", [member("s2")])
      assert {:ok, :ignored} = push!("acme", 2, "live", [member("s2")])
      assert subs("acme") == ["s1"]
    end

    test "a member absent from a newer state loses the project and keeps the User" do
      push!("acme", 1, "live", [member("s1"), member("s2")])
      dropped = user_of("s2")

      push!("acme", 2, "live", [member("s1")])

      assert subs("acme") == ["s1"]
      assert nil == Projects.get_user_project(dropped, project_of("acme"))
      assert Auth.get_user(dropped)
    end

    test "a newer push renames the project and updates a member's mail" do
      push!("acme", 1, "live", [member("s1")])

      Tenancy.apply_state("acme", %{
        state(2, "live", [%{member("s1") | mail: "new@shop.example.com"}])
        | name: "Acme Two"
      })

      assert Projects.get_project(project_of("acme")).name == "Acme Two"
      assert Auth.get_user(user_of("s1")).email == "new@shop.example.com"
    end

    test "suspended keeps the data and withdraws every member's access" do
      push!("acme", 1, "live", [member("s1")])
      project_id = project_of("acme")

      push!("acme", 2, "suspended", [member("s1")])

      assert {:ok, %{state: "suspended", members: []}} = Tenancy.read("acme")
      assert Projects.get_project(project_id)
      assert nil == Projects.get_user_project(user_of("s1"), project_id)

      push!("acme", 3, "live", [member("s1")])
      assert Projects.get_user_project(user_of("s1"), project_id)
    end

    test "purged deletes the shop, never the Users, and leaves a tombstone" do
      push!("acme", 1, "live", [member("s1")])
      %Row{project_id: project_id, account_id: account_id} = Repo.get_by!(Row, slug: "acme")
      user_id = user_of("s1")

      assert {:ok, :applied} = push!("acme", 2, "purged", [])

      assert {:error, :not_found} = Tenancy.read("acme")
      assert [] == Tenancy.list()
      assert nil == Projects.get_project(project_id)
      assert nil == Repo.get(Account, account_id)
      assert Auth.get_user(user_id)

      assert %Row{version: 2, state: "purged", project_id: nil, account_id: nil} =
               Repo.get_by!(Row, slug: "acme")

      assert {:ok, :ignored} = push!("acme", 2, "live", [member("s1")])
      assert {:error, :not_found} = Tenancy.read("acme")
    end

    test "a higher version re-births a purged slug fresh" do
      push!("acme", 1, "live", [member("s1")])
      old_project = project_of("acme")
      push!("acme", 2, "purged", [])

      assert {:ok, :applied} = push!("acme", 3, "live", [member("s2")])

      assert subs("acme") == ["s2"]
      refute project_of("acme") == old_project
    end

    test "a mail held by a User the push does not own is refused and nothing is applied" do
      insert!(:user, email: "Taken@Shop.example.com")

      assert {:error, {:malformed, "members[1].mail: belongs to another user"}} =
               push!("acme", 1, "live", [
                 member("s1"),
                 %{member("s2") | mail: "taken@shop.example.com"}
               ])

      assert {:error, :not_found} = Tenancy.read("acme")
      assert nil == Repo.get_by(OidcIdentity, issuer: @issuer, subject: "s1")
      assert nil == Repo.get_by(Row, slug: "acme")
    end

    test "without exactly one pushed provider nothing is applied" do
      Application.put_env(:keila, Oidc, providers: [])
      assert {:error, :no_merchant_issuer} = push!("acme", 1, "live", [member("s1")])

      Application.put_env(:keila, Oidc,
        providers: [merchant: @merchant, other: Keyword.put(@merchant, :issuer, "https://other")]
      )

      assert {:error, :no_merchant_issuer} = push!("acme", 1, "live", [member("s1")])
      assert nil == Repo.get_by(Row, slug: "acme")
    end
  end

  describe "isolation" do
    defp set_credits_enabled(enabled) do
      config = Application.get_env(:keila, Keila.Accounts, [])
      Application.put_env(:keila, Keila.Accounts, Keyword.put(config, :credits_enabled, enabled))
    end

    defp available(account_id), do: account_id |> Accounts.get_credits() |> elem(1)

    test "proof 1: one sub in two shops reaches both, and B's send debits only B" do
      previous = Application.get_env(:keila, Keila.Accounts, [])[:credits_enabled]
      set_credits_enabled(true)
      on_exit(fn -> set_credits_enabled(previous || false) end)

      push!("shop-a", 1, "live", [member("s1")])
      push!("shop-b", 1, "live", [member("s1")])
      user_id = user_of("s1")
      %Row{project_id: b_project, account_id: b_account} = Repo.get_by!(Row, slug: "shop-b")
      %Row{account_id: a_account} = Repo.get_by!(Row, slug: "shop-a")

      assert Enum.sort(Enum.map(Projects.get_user_projects(user_id), & &1.name)) == [
               "Acme",
               "Acme"
             ]

      refute Auth.user_in_group?(user_id, Repo.get!(Account, b_account).group_id)
      assert Accounts.get_project_account(b_project).id == b_account

      tomorrow = DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.truncate(:second)
      :ok = Accounts.add_credits(a_account, 10, tomorrow)
      :ok = Accounts.add_credits(b_account, 10, tomorrow)
      personal = Accounts.get_user_account(user_id).id
      :ok = Accounts.add_credits(personal, 10, tomorrow)

      insert!(:contact, project_id: b_project)
      insert!(:contact, project_id: b_project)

      sender =
        insert!(:mailings_sender,
          project_id: b_project,
          config: %Mailings.Sender.Config{type: "test"}
        )

      campaign = insert!(:mailings_campaign, project_id: b_project, sender_id: sender.id)

      assert :ok = Mailings.deliver_campaign(campaign.id)
      assert available(b_account) == 8
      assert available(a_account) == 10
      assert available(personal) == 10
    end

    test "proof 2: removal from A, or purge of A, keeps the User and their B access" do
      push!("shop-a", 1, "live", [member("s1")])
      push!("shop-b", 1, "live", [member("s1")])
      user_id = user_of("s1")
      b_project = project_of("shop-b")

      push!("shop-a", 2, "live", [])
      assert Projects.get_user_project(user_id, b_project)

      push!("shop-a", 3, "purged", [])
      assert Auth.get_user(user_id)
      assert Projects.get_user_project(user_id, b_project)
      assert subs("shop-b") == ["s1"]
    end

    test "proof 3: a member holds no role and cannot reach another shop's project" do
      push!("shop-a", 1, "live", [member("s1")])
      push!("shop-b", 1, "live", [member("s2")])
      user_id = user_of("s1")

      refute Auth.has_permission?(user_id, Auth.root_group().id, "administer_keila")

      assert [] ==
               Repo.all(
                 from(r in Auth.UserGroupRole,
                   join: ug in Auth.UserGroup,
                   on: ug.id == r.user_group_id,
                   where: ug.user_id == ^user_id
                 )
               )

      assert nil == Projects.get_user_project(user_id, project_of("shop-b"))
    end

    test "a pushed User is idp_managed and signs in by sub alone" do
      push!("acme", 1, "live", [member("s1")])
      user_id = user_of("s1")

      assert Login.idp_managed?(user_id)

      assert {:ok, %User{id: ^user_id}} =
               Login.handle_claims(:merchant, %{"sub" => "s1", "email" => "x@y.z"})
    end

    test "a pushed User has a personal Account of its own, holding no shop project" do
      push!("acme", 1, "live", [member("s1")])
      user_id = user_of("s1")

      assert %Account{id: personal} = Accounts.get_user_account(user_id)
      refute personal == Repo.get_by!(Row, slug: "acme").account_id
    end

    test "a member of a suspended shop is refused at the door and the attempt writes nothing" do
      push!("acme", 1, "live", [member("s1")])
      push!("acme", 2, "suspended", [member("s1")])
      before = {Repo.aggregate(User, :count), Repo.aggregate(Account, :count)}

      assert {:error, :not_entitled} = Login.handle_claims(:merchant, %{"sub" => "s1"})
      assert before == {Repo.aggregate(User, :count), Repo.aggregate(Account, :count)}
    end

    test "a member removed from every shop is refused at the door" do
      push!("acme", 1, "live", [member("s1")])
      push!("acme", 2, "live", [])

      assert {:error, :not_entitled} = Login.handle_claims(:merchant, %{"sub" => "s1"})
    end
  end

  test "a first push in state suspended holds the shop with no member" do
    assert {:ok, :applied} = push!("acme", 1, "suspended", [member("s1")])

    assert {:ok, %{state: "suspended", members: []}} = Tenancy.read("acme")
    assert [%{slug: "acme", version: 1}] = Tenancy.list()
    assert Projects.get_project(project_of("acme"))
  end

  test "two subs pushed with one mail are refused and nothing is applied" do
    shared = "same@shop.example.com"

    assert {:error, {:malformed, "members[1].mail: belongs to another user"}} =
             push!("acme", 1, "live", [
               %{member("s1") | mail: shared},
               %{member("s2") | mail: shared}
             ])

    assert nil == Repo.get_by(OidcIdentity, issuer: @issuer, subject: "s1")
  end
end
