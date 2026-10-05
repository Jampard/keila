defmodule Keila.ReleaseTasksTest do
  use Keila.DataCase, async: false

  alias Keila.Auth
  alias Keila.ReleaseTasks

  setup do
    on_exit(fn ->
      System.delete_env("KEILA_PASSWORD")
      System.delete_env("KEILA_USER")
    end)

    with_seed()

    :ok
  end

  test "KEILA_PASSWORD is authoritative for an EXISTING root user, not only at seed time" do
    {:ok, user} =
      Auth.create_user(%{"email" => "root@localhost", "password" => "the-first-password"})

    System.put_env("KEILA_PASSWORD", "the-rotated-password")
    assert :ok = ReleaseTasks.sync_root_password()

    assert {:ok, %{id: id}} =
             Auth.find_user_by_credentials(%{
               "email" => "root@localhost",
               "password" => "the-rotated-password"
             })

    assert id == user.id

    assert {:error, _changeset} =
             Auth.find_user_by_credentials(%{
               "email" => "root@localhost",
               "password" => "the-first-password"
             })
  end

  test "a matching password is left untouched and a missing variable or user is a no-op" do
    assert :ok = ReleaseTasks.sync_root_password()

    {:ok, user} =
      Auth.create_user(%{"email" => "root@localhost", "password" => "already-in-effect"})

    System.put_env("KEILA_PASSWORD", "already-in-effect")
    hash_before = Repo.get(Auth.User, user.id).password_hash

    assert :ok = ReleaseTasks.sync_root_password()
    assert Repo.get(Auth.User, user.id).password_hash == hash_before

    System.put_env("KEILA_USER", "nobody@example.com")
    assert :ok = ReleaseTasks.sync_root_password()
  end
end
