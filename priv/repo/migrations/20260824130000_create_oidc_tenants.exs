defmodule Keila.Repo.Migrations.CreateOidcTenants do
  use Ecto.Migration

  def change do
    create table("oidc_tenants") do
      add :issuer, :string, null: false
      add :slug, :string, null: false
      add :project_id, references("projects", on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index("oidc_tenants", [:issuer, :slug])
    create index("oidc_tenants", [:project_id])
  end
end
