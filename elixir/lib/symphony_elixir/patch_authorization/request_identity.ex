defmodule SymphonyElixir.PatchAuthorization.RequestIdentity do
  @moduledoc false

  @identity_fields [
    :profile,
    :repository,
    :pull_request_number,
    :evaluated_head_sha,
    :eligible_finding_keys,
    :eligible_finding_set_digest,
    :policy_version,
    :human_summary,
    :expected_transition
  ]

  @type request :: %{
          request_id: String.t(),
          request_fingerprint: String.t(),
          profile: :aroak_autonomous_v1,
          repository: String.t(),
          pull_request_number: pos_integer(),
          evaluated_head_sha: String.t(),
          eligible_finding_keys: [term()],
          eligible_finding_set_digest: String.t(),
          policy_version: String.t(),
          human_summary: String.t(),
          expected_transition: map()
        }

  @spec build(map()) :: {:ok, request()} | {:error, atom()}
  def build(input) when is_map(input) do
    with :ok <- validate_input(input) do
      normalized = normalize_input(input)
      digest = digest(normalized)

      {:ok,
       Map.merge(normalized, %{
         request_id: "d3-request-v1-#{digest}",
         request_fingerprint: "d3-request-fingerprint-v1-#{digest}"
       })}
    end
  end

  def build(_input), do: {:error, :invalid_request_input}

  @spec validate(request(), map()) :: :ok | {:error, atom()}
  def validate(request, current_input) when is_map(request) and is_map(current_input) do
    with {:ok, stored} <- build(Map.take(request, @identity_fields)),
         {:ok, current} <- build(current_input),
         :ok <- validate_stored_fingerprint(request, stored) do
      compare_current_snapshot(stored, current)
    end
  end

  def validate(_request, _current_input), do: {:error, :invalid_request_input}

  defp validate_input(input) do
    with :ok <- validate_profile(input),
         :ok <- validate_repository_and_pull_request(input),
         :ok <- validate_snapshot_fields(input) do
      validate_policy_fields(input)
    end
  end

  defp validate_profile(input) do
    if input[:profile] == :aroak_autonomous_v1, do: :ok, else: {:error, :invalid_profile}
  end

  defp validate_repository_and_pull_request(input) do
    cond do
      not non_empty_string?(input[:repository]) ->
        {:error, :invalid_repository}

      not is_integer(input[:pull_request_number]) or input[:pull_request_number] < 1 ->
        {:error, :invalid_pull_request_number}

      true ->
        :ok
    end
  end

  defp validate_snapshot_fields(input) do
    cond do
      not non_empty_string?(input[:evaluated_head_sha]) -> {:error, :invalid_evaluated_head_sha}
      not valid_finding_keys?(input[:eligible_finding_keys]) -> {:error, :invalid_finding_keys}
      not non_empty_string?(input[:eligible_finding_set_digest]) -> {:error, :invalid_finding_set_digest}
      true -> :ok
    end
  end

  defp validate_policy_fields(input) do
    cond do
      not non_empty_string?(input[:policy_version]) -> {:error, :invalid_policy_version}
      not non_empty_string?(input[:human_summary]) -> {:error, :invalid_human_summary}
      not is_map(input[:expected_transition]) -> {:error, :invalid_expected_transition}
      true -> :ok
    end
  end

  defp normalize_input(input) do
    Map.take(input, @identity_fields)
    |> Map.update!(:eligible_finding_keys, &sort_finding_keys/1)
  end

  defp validate_stored_fingerprint(request, stored) do
    if request[:request_id] == stored.request_id and
         request[:request_fingerprint] == stored.request_fingerprint do
      :ok
    else
      {:error, :request_fingerprint_mismatch}
    end
  end

  defp compare_current_snapshot(stored, current) do
    cond do
      stored.evaluated_head_sha != current.evaluated_head_sha ->
        {:error, :authorization_request_stale}

      stored.eligible_finding_set_digest != current.eligible_finding_set_digest or
          stored.eligible_finding_keys !== current.eligible_finding_keys ->
        {:error, :authorization_finding_set_changed}

      stored != current ->
        {:error, :authorization_request_changed}

      true ->
        :ok
    end
  end

  defp valid_finding_keys?(keys) when is_list(keys) do
    proper_list?(keys) and keys != [] and length(Enum.uniq(keys)) == length(keys)
  end

  defp valid_finding_keys?(_keys), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp sort_finding_keys(keys) do
    Enum.sort_by(keys, fn key -> :erlang.term_to_binary(canonical_term(key)) end)
  end

  defp digest(input) do
    input
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_term(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.map(fn {key, item} -> {canonical_term(key), canonical_term(item)} end)
    |> Enum.sort_by(fn {key, _item} -> :erlang.term_to_binary(key) end)
    |> then(&{:map, &1})
  end

  defp canonical_term(value) when is_list(value), do: {:list, Enum.map(value, &canonical_term/1)}

  defp canonical_term(value) when is_tuple(value) do
    {:tuple, value |> Tuple.to_list() |> Enum.map(&canonical_term/1)}
  end

  defp canonical_term(value), do: value

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
