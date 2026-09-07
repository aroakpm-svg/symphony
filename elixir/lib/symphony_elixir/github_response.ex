defmodule SymphonyElixir.GitHubResponse do
  @moduledoc """
  Distinguishes temporary GitHub rate limits from permanent HTTP 403 authority failures.
  Raw headers and bodies never leave this boundary.
  """

  @spec classify_forbidden(map()) :: {:error, :github_unavailable | :github_forbidden}
  def classify_forbidden(response) do
    if rate_limited?(response), do: {:error, :github_unavailable}, else: {:error, :github_forbidden}
  end

  @spec reject_graphql_rate_limit(map()) :: :ok | {:error, :github_unavailable}
  def reject_graphql_rate_limit(%{"errors" => errors}) when is_list(errors) do
    if Enum.any?(errors, &graphql_rate_limit?/1), do: {:error, :github_unavailable}, else: :ok
  end

  def reject_graphql_rate_limit(_body), do: :ok

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

  defp graphql_rate_limit?(error) when is_map(error) do
    rate_limit_code?(Map.get(error, "type")) or
      extension_rate_limit?(Map.get(error, "extensions"))
  end

  defp graphql_rate_limit?(_error), do: false

  defp extension_rate_limit?(%{"code" => code}), do: rate_limit_code?(code)
  defp extension_rate_limit?(_extensions), do: false

  defp rate_limit_code?("RATE_LIMITED"), do: true
  defp rate_limit_code?(_code), do: false
end
