defmodule KeilaWeb.SourceLink do
  @moduledoc """
  Link to the source code of the running instance, as required by AGPL-3.0 §13.
  """

  @default_url "https://github.com/pentacent/keila"

  @spec source_url() :: String.t()
  def source_url do
    config = Application.get_env(:keila, __MODULE__, [])

    # A revision only exists in the configured repository, never in upstream's.
    case {Keyword.get(config, :url), Keyword.get(config, :revision)} do
      {url, _} when url in [nil, ""] -> @default_url
      {url, revision} when revision in [nil, ""] -> url
      {url, revision} -> String.trim_trailing(url, "/") <> "/tree/" <> revision
    end
  end
end
