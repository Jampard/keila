defmodule Keila.ReleaseTasks do
  @moduledoc """
  One-off commands you can run on Keila releases.

  Run the functions from this module like this:
  `bin/keila eval "Keila.ReleaseTasks.init()"`

  If you’re using the official Docker image, run them like this:
  `docker run pentacent/keila eval "Keila.ReleaseTasks.init()"`
  """
  require Logger

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

  A password the user schema refuses is logged and leaves the current one in place,
  rather than stopping the boot it runs in.
  """
  def sync_root_password() do
    with password when password not in [nil, ""] <- Keila.SecretEnv.get("KEILA_PASSWORD"),
         email = root_email(),
         %Keila.Auth.User{} = user <- Keila.Auth.find_user_by_email(email),
         false <-
           is_binary(user.password_hash) and Argon2.verify_pass(password, user.password_hash),
         {:error, changeset} <-
           Keila.Auth.update_user_password(user.id, %{"password" => password}) do
      Logger.error(
        "KEILA_PASSWORD was not applied to #{email}, the old password stays in effect: " <>
          inspect(Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end))
      )

      {:error, :invalid_password}
    else
      _noop_or_updated -> :ok
    end
  end

  # As in seeds.exs, an empty KEILA_USER means the default root user.
  defp root_email() do
    case System.get_env("KEILA_USER") do
      email when email not in [nil, ""] -> email
      _empty -> "root@localhost"
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
