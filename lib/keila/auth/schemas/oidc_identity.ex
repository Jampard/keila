defmodule Keila.Auth.OidcIdentity do
  use Keila.Schema, prefix: "oi"

  schema "oidc_identities" do
    field(:issuer, :string)
    field(:subject, :string)
    belongs_to(:user, Keila.Auth.User, type: Keila.Auth.User.Id)

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.data(), map()) :: Ecto.Changeset.t(t)
  def changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, [:issuer, :subject, :user_id])
    |> validate_required([:issuer, :subject, :user_id])
    |> validate_length(:issuer, max: 255)
    |> validate_length(:subject, max: 255)
    |> unique_constraint([:issuer, :subject])
  end
end
