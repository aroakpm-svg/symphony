defmodule SymphonyElixir.GitHubResponse do
  @moduledoc """
  Distinguishes temporary GitHub rate limits from permanent HTTP 403 authority failures.
  Raw headers and bodies never leave this boundary.
  """

  @spec classify_forbidden(map()) :: {:error, :github_unavailable | :github_forbidden}
  def classify_forbidden(response) do
    if rate_limited?(response), do: {:error, :github_unavailable}, else: {:error, :github_forbidden}
  end

  defp rate_limited?(response) do
    header_values(response, "x-ratelimit-remaining") == ["0"] or
      Enum.any?(header_values(response, "retry-after"), &retry_delay?/1) or
      secondary_rate_limit?(Map.get(response, :body))
  end

  defp header_values(response, name) do
    case Map.get(response, :headers) do
      headers when is_map(headers) or is_list(headers) ->
        Enum.flat_map(headers, &matching_header_values(&1, name))

      _headers ->
        []
    end
  end

  defp matching_header_values({key, value}, name) when is_binary(key) do
    if String.downcase(key) == name, do: List.wrap(value), else: []
  end

  defp matching_header_values(_header, _name), do: []

  defp retry_delay?(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> true
      _invalid -> false
    end
  end

  defp retry_delay?(_value), do: false

  defp secondary_rate_limit?(%{"message" => message}) when is_binary(message),
    do: String.contains?(String.downcase(message), "secondary rate limit")

  defp secondary_rate_limit?(_body), do: false
end
