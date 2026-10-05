defmodule Keila.Auth.Oidc.ClaimsTest do
  use ExUnit.Case, async: true

  alias Keila.Auth.Oidc.Claims

  describe "values/2 with a non-binary claim name" do
    test "returns no values instead of raising" do
      assert Claims.values(%{"groups" => ["a"]}, :groups) == []
      assert Claims.entitled?(%{"groups" => ["a"]}, :groups, "a") == false
      assert Claims.tenant_grants(%{"groups" => ["org.acme.admin"]}, :groups, "org") == []
    end
  end

  describe "values/2" do
    test "a string claim yields a single-element list" do
      assert Claims.values(%{"groups" => "admin"}, "groups") == ["admin"]
    end

    test "a list claim yields its elements in order" do
      assert Claims.values(%{"groups" => ["a", "b"]}, "groups") == ["a", "b"]
    end

    test "an absent claim yields an empty list" do
      assert Claims.values(%{}, "groups") == []
    end

    test "a nil claim name yields an empty list" do
      assert Claims.values(%{"groups" => "admin"}, nil) == []
    end

    test "an empty claim name yields an empty list" do
      assert Claims.values(%{"groups" => "admin"}, "") == []
    end

    test "non-binary elements of a mixed list are dropped, not converted" do
      assert Claims.values(%{"groups" => ["a", 1, nil, %{"x" => 1}, "b"]}, "groups") ==
               ["a", "b"]
    end

    test "a claim whose value is a number yields an empty list" do
      assert Claims.values(%{"groups" => 42}, "groups") == []
    end

    test "a claim whose value is a map yields an empty list" do
      assert Claims.values(%{"groups" => %{"a" => 1}}, "groups") == []
    end
  end

  describe "entitled?/3" do
    test "matches exactly when the required value is present in a list claim" do
      assert Claims.entitled?(%{"groups" => ["admin", "viewer"]}, "groups", "admin")
    end

    test "matches exactly when the required value equals a single string claim" do
      assert Claims.entitled?(%{"groups" => "admin"}, "groups", "admin")
    end

    test "does not match a case variant of the required value" do
      refute Claims.entitled?(%{"groups" => ["Admin"]}, "groups", "admin")
    end

    test "does not match a substring or prefix of a group name" do
      refute Claims.entitled?(%{"groups" => ["administrator"]}, "groups", "admin")
    end

    test "a nil claim name is always false even when a same-named claim exists" do
      refute Claims.entitled?(%{"groups" => ["admin"]}, nil, "admin")
    end

    test "an empty claim name is always false even when a same-named claim exists" do
      refute Claims.entitled?(%{"" => ["admin"]}, "", "admin")
    end

    test "an empty required value is true when the claim has values" do
      assert Claims.entitled?(%{"groups" => ["admin"]}, "groups", "")
      assert Claims.entitled?(%{"groups" => ["admin"]}, "groups", nil)
    end

    test "an empty required value is false when the claim is absent" do
      refute Claims.entitled?(%{}, "groups", "")
      refute Claims.entitled?(%{}, "groups", nil)
    end

    test "an empty required value is false when the claim is present but empty" do
      refute Claims.entitled?(%{"groups" => []}, "groups", "")
    end
  end

  describe "tenant_grants/3" do
    @kanidm_groups [
      "4d21d04a-dc0d-42eb-96f8-1e5d1a1a1234",
      "org.acme.admin@idm.example.com",
      "b1e2c3d4-0000-1111-2222-333344445555",
      "org.globex.viewer@idm.example.com",
      "idm_all_persons@idm.example.com",
      "org.acme.admin"
    ]

    test "the real-world mixed kanidm list yields exactly the two matching pairs" do
      claims = %{"groups" => @kanidm_groups}

      assert Claims.tenant_grants(claims, "groups", "org") == [
               {"acme", "admin"},
               {"globex", "viewer"}
             ]
    end

    test "the SPN form and the bare-name form of the same group parse identically" do
      spn =
        Claims.tenant_grants(%{"groups" => ["org.acme.admin@idm.example.com"]}, "groups", "org")

      bare = Claims.tenant_grants(%{"groups" => ["org.acme.admin"]}, "groups", "org")
      assert spn == bare
      assert spn == [{"acme", "admin"}]
    end

    test "bare UUIDs are skipped" do
      claims = %{"groups" => ["4d21d04a-dc0d-42eb-96f8-1e5d1a1a1234"]}
      assert Claims.tenant_grants(claims, "groups", "org") == []
    end

    test "unrelated groups outside the prefix are skipped" do
      claims = %{"groups" => ["idm_all_persons@idm.example.com"]}
      assert Claims.tenant_grants(claims, "groups", "org") == []
    end

    test "an entry with the wrong prefix is skipped" do
      claims = %{"groups" => ["other.acme.admin@idm.example.com"]}
      assert Claims.tenant_grants(claims, "groups", "org") == []
    end

    test "a four-segment entry does not match the exactly-three-segment grammar" do
      claims = %{"groups" => ["org.acme.admin.extra"]}
      assert Claims.tenant_grants(claims, "groups", "org") == []
    end

    test "a two-segment entry does not match the exactly-three-segment grammar" do
      claims = %{"groups" => ["org.acme"]}
      assert Claims.tenant_grants(claims, "groups", "org") == []
    end

    test "an entry with an empty slug segment is skipped" do
      claims = %{"groups" => ["org..admin"]}
      assert Claims.tenant_grants(claims, "groups", "org") == []
    end

    test "an entry with an empty role segment is skipped" do
      claims = %{"groups" => ["org.acme."]}
      assert Claims.tenant_grants(claims, "groups", "org") == []
    end

    test "exact duplicate pairs are deduplicated preserving first-seen order" do
      claims = %{
        "groups" => [
          "org.acme.admin@idm.example.com",
          "org.acme.admin",
          "org.globex.viewer@idm.example.com"
        ]
      }

      assert Claims.tenant_grants(claims, "groups", "org") == [
               {"acme", "admin"},
               {"globex", "viewer"}
             ]
    end

    test "two distinct roles at the same tenant both survive" do
      claims = %{"groups" => ["org.acme.admin", "org.acme.viewer"]}

      assert Claims.tenant_grants(claims, "groups", "org") == [
               {"acme", "admin"},
               {"acme", "viewer"}
             ]
    end

    test "a nil claim name yields an empty list" do
      assert Claims.tenant_grants(%{"groups" => ["org.acme.admin"]}, nil, "org") == []
    end

    test "an empty claim name yields an empty list" do
      assert Claims.tenant_grants(%{"groups" => ["org.acme.admin"]}, "", "org") == []
    end

    test "a nil prefix yields an empty list" do
      assert Claims.tenant_grants(%{"groups" => ["org.acme.admin"]}, "groups", nil) == []
    end

    test "an empty prefix yields an empty list" do
      assert Claims.tenant_grants(%{"groups" => ["org.acme.admin"]}, "groups", "") == []
    end
  end

  describe "tenant_slugs/3" do
    test "dedupes slugs across multiple roles at the same tenant, preserving order" do
      claims = %{
        "groups" => [
          "org.acme.admin",
          "org.acme.viewer",
          "org.globex.viewer"
        ]
      }

      assert Claims.tenant_slugs(claims, "groups", "org") == ["acme", "globex"]
    end
  end
end
