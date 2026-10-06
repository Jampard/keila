defmodule Keila.Tenancy.Tenancy do
  use Keila.Schema, prefix: "tn"

  schema "tenancies" do
    field(:slug, :string)
    field(:version, :integer)
    field(:state, :string)
    field(:name, :string)
    field(:domains, {:array, :string}, default: [])
    belongs_to(:project, Keila.Projects.Project, type: Keila.Projects.Project.Id)
    belongs_to(:account, Keila.Accounts.Account, type: Keila.Accounts.Account.Id)

    timestamps()
  end
end
