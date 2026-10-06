defmodule Keila.SecretEnvTest do
  use ExUnit.Case, async: false
  alias Keila.SecretEnv

  @name "KEILA_SECRET_ENV_TEST"

  setup do
    on_exit(fn ->
      System.delete_env(@name)
      System.delete_env(@name <> "_FILE")
    end)
  end

  @tag :tmp_dir
  test "the _FILE variant wins and loses its trailing newline", %{tmp_dir: dir} do
    path = Path.join(dir, "secret")
    File.write!(path, "from-file\n")
    System.put_env(@name, "from-env")
    System.put_env(@name <> "_FILE", path)

    assert SecretEnv.get(@name) == "from-file"
  end

  test "falls back to the plain variable without a _FILE" do
    System.put_env(@name, "from-env")
    assert SecretEnv.get(@name) == "from-env"
  end

  test "a _FILE pointing at a missing file raises instead of falling back" do
    System.put_env(@name, "from-env")
    System.put_env(@name <> "_FILE", "/nonexistent/keila-secret")
    assert_raise File.Error, fn -> SecretEnv.get(@name) end
  end

  test "fetch!/1 raises when neither is set" do
    assert_raise ArgumentError, ~r/#{@name}_FILE/, fn -> SecretEnv.fetch!(@name) end
  end
end
