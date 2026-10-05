defmodule Keila.ReleaseTasks do
  @moduledoc """
  One-off commands you can run on Keila releases.

  Run the functions from this module like this:
  `bin/keila eval "Keila.ReleaseTasks.init()"`

  If you’re using the official Docker image, run them like this:
  `docker run pentacent/keila eval "Keila.ReleaseTasks.init()"`
  """

  @doc """
  Initializes the database and inserts fixtues.
  """
  def init() do
    migrate()

    Ecto.Migrator.with_repo(Keila.Repo, fn _ ->
      Code.eval_file(Path.join(:code.priv_dir(:keila), "repo/seeds.exs"))
      sync_root_password()
      {:ok, :stop}
    end)
  end

  @doc """
  Makes `KEILA_PASSWORD` authoritative for the root user's password on every boot,
  not only at first seed — the seed script runs solely on an empty database, so
  without this an operator-supplied password is silently ignored on an existing
  deployment. A no-op when the variable is unset or already in effect.
  """
  def sync_root_password() do
    with password when password not in [nil, ""] <- System.get_env("KEILA_PASSWORD"),
         email = System.get_env("KEILA_USER") || "root@localhost",
         %Keila.Auth.User{} = user <- Keila.Auth.find_user_by_email(email) do
      unless is_binary(user.password_hash) and Argon2.verify_pass(password, user.password_hash) do
        {:ok, _user} = Keila.Auth.update_user_password(user.id, %{"password" => password})
      end

      :ok
    else
      _other -> :ok
    end
  end

  @doc """
  Runs database migrations.
  """
  def migrate do
    {:ok, _, _} = Ecto.Migrator.with_repo(Keila.Repo, &Ecto.Migrator.run(&1, :up, all: true))
  end

  @doc """
  Rolls back database migrations to given version.
  """
  def rollback(version) do
    {:ok, _, _} = Ecto.Migrator.with_repo(Keila.Repo, &Ecto.Migrator.run(&1, :down, to: version))
  end
end
