defmodule Keila.Repo.Migrations.CreateOidcIdentities do
  use Ecto.Migration

  def change do
    create table("oidc_identities") do
      add :issuer, :string, null: false
      add :subject, :string, null: false
      add :user_id, references("users", on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index("oidc_identities", [:issuer, :subject])
    create index("oidc_identities", [:user_id])
  end
end
