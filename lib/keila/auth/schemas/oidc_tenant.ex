defmodule Keila.Auth.OidcTenant do
  use Keila.Schema, prefix: "ot"

  schema "oidc_tenants" do
    field(:issuer, :string)
    field(:slug, :string)
    belongs_to(:project, Keila.Projects.Project, type: Keila.Projects.Project.Id)

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.data(), map()) :: Ecto.Changeset.t(t)
  def changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, [:issuer, :slug, :project_id])
    |> validate_required([:issuer, :slug, :project_id])
    |> validate_length(:issuer, max: 255)
    |> validate_length(:slug, max: 255)
    |> unique_constraint([:issuer, :slug])
  end
end
