Ecto.Adapters.SQL.Sandbox.mode(Keila.Repo, :manual)
kanidm_exclude = if Keila.KanidmIssuer.configured?(), do: [], else: [:kanidm]
ExUnit.configure(exclude: [:skip | kanidm_exclude])
ExUnit.start()
