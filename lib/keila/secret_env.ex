defmodule Keila.SecretEnv do
  @moduledoc """
  Reads a secret from the file named by `<NAME>_FILE` when that is set, else from `<NAME>`.
  Trailing newlines are dropped from the file's contents.
  """

  @spec get(String.t()) :: String.t() | nil
  def get(name) do
    case System.get_env(name <> "_FILE") do
      path when path not in [nil, ""] -> path |> File.read!() |> String.trim_trailing("\n")
      _ -> System.get_env(name)
    end
  end

  @spec fetch!(String.t()) :: String.t()
  def fetch!(name) do
    case get(name) do
      value when value not in [nil, ""] -> value
      _ -> raise ArgumentError, "set #{name} or #{name}_FILE"
    end
  end
end
