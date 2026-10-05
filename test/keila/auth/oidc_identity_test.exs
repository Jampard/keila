defmodule Keila.AuthTest.OidcIdentity do
  use Keila.DataCase, async: false
  alias Keila.Auth.OidcIdentity

  @tag :auth
  test "(issuer, subject) pair must be unique" do
    user = insert!(:user)
    identity = insert!(:oidc_identity, user: user)

    assert {:error, changeset} =
             OidcIdentity.changeset(%{
               issuer: identity.issuer,
               subject: identity.subject,
               user_id: user.id
             })
             |> Repo.insert()

    assert %{issuer: ["has already been taken"]} = errors_on(changeset)
  end

  @tag :auth
  test "one user may hold identities at two different issuers with the same subject" do
    user = insert!(:user)
    insert!(:oidc_identity, user: user, issuer: "https://idp-a.example.com", subject: "sub-1")
    insert!(:oidc_identity, user: user, issuer: "https://idp-b.example.com", subject: "sub-1")
  end

  @tag :auth
  test "two different users may hold the same subject at different issuers" do
    user_a = insert!(:user)
    user_b = insert!(:user)
    insert!(:oidc_identity, user: user_a, issuer: "https://idp-a.example.com", subject: "sub-1")
    insert!(:oidc_identity, user: user_b, issuer: "https://idp-b.example.com", subject: "sub-1")
  end

  @tag :auth
  test "deleting the user cascades the identity away" do
    user = insert!(:user)
    identity = insert!(:oidc_identity, user: user)

    assert :ok = Keila.Auth.delete_user(user.id)
    assert Repo.get(OidcIdentity, identity.id) == nil
  end

  @tag :auth
  test "changeset requires issuer, subject, and user_id" do
    changeset = OidcIdentity.changeset(%{})

    refute changeset.valid?

    assert %{issuer: ["can't be blank"], subject: ["can't be blank"], user_id: ["can't be blank"]} =
             errors_on(changeset)
  end
end
