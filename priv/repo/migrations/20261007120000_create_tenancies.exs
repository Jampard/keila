defmodule Keila.Repo.Migrations.CreateTenancies do
  use Ecto.Migration

  def up do
    drop_if_exists table("oidc_tenants")

    create table("tenancies") do
      add :slug, :text, null: false
      add :version, :bigint, null: false
      add :state, :text, null: false
      add :name, :text, null: false
      add :domains, {:array, :text}, null: false, default: []
      add :project_id, references("projects", on_delete: :nilify_all)
      add :account_id, references("accounts", on_delete: :nilify_all)

      timestamps()
    end

    create unique_index("tenancies", [:slug])

    create constraint("tenancies", :state_is_v1,
             check: "state IN ('live', 'suspended', 'purged')"
           )
  end

  def down do
    drop table("tenancies")
  end
end
