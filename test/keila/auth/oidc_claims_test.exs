defmodule Keila.Auth.Oidc.ClaimsTest do
  use ExUnit.Case, async: true

  alias Keila.Auth.Oidc.Claims

  describe "values/2 with a non-binary claim name" do
    test "returns no values instead of raising" do
      assert Claims.values(%{"groups" => ["a"]}, :groups) == []
      assert Claims.entitled?(%{"groups" => ["a"]}, :groups, "a") == false
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
end
