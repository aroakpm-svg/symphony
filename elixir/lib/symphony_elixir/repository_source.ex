defmodule SymphonyElixir.RepositorySource do
  @moduledoc false

  @spec url(String.t()) :: String.t()
  def url(repository) when is_binary(repository) do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repository),
      do: "https://github.com/#{repository}.git",
      else: repository
  end
end
