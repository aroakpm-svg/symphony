defmodule SymphonyElixir.MultiProjectPoll do
  @moduledoc """
  Independently polls approved projects and combines unambiguous issue candidates.
  """

  alias SymphonyElixir.Linear.Issue

  @default_timeout 5_000

  @type outcome :: %{status: :ok} | %{status: :timeout | :error, retry: :transient}
  @type result :: %{
          candidates: [Issue.t()],
          outcomes: %{required(String.t()) => outcome()},
          ambiguous_issue_ids: MapSet.t(String.t())
        }

  @spec fetch([map()], (map() -> {:ok, [Issue.t()]} | {:error, term()}), keyword()) :: result()
  def fetch(profiles, fetcher, opts \\ []) when is_list(profiles) and is_function(fetcher, 1) do
    profiles = Enum.sort_by(profiles, & &1.key)

    case profiles do
      [] -> empty_result()
      _ -> profiles |> poll(fetcher, opts) |> aggregate()
    end
  end

  defp poll(profiles, fetcher, opts) do
    timeout = per_profile_timeout(opts)

    profiles
    |> Task.async_stream(&safe_fetch(fetcher, &1),
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true,
      max_concurrency: length(profiles)
    )
    |> Enum.zip(profiles)
    |> Enum.map(fn {result, profile} -> {profile, result} end)
  end

  defp safe_fetch(fetcher, profile) do
    fetcher.(profile)
  rescue
    _exception -> {:error, :profile_fetch_exception}
  catch
    :exit, _reason -> {:error, :profile_fetch_exit}
    :throw, _value -> {:error, :profile_fetch_throw}
  end

  defp aggregate(profile_results) do
    {candidates, outcomes} =
      Enum.reduce(profile_results, {[], %{}}, fn {profile, result}, {candidates, outcomes} ->
        {profile_candidates, outcome} = classify_result(profile, result)
        {candidates ++ profile_candidates, Map.put(outcomes, profile.key, outcome)}
      end)

    candidates = Enum.uniq_by(candidates, &{&1.project_profile.key, &1.id})
    ambiguous_issue_ids = ambiguous_issue_ids(candidates)

    %{
      candidates: Enum.reject(candidates, &MapSet.member?(ambiguous_issue_ids, &1.id)),
      outcomes: outcomes,
      ambiguous_issue_ids: ambiguous_issue_ids
    }
  end

  defp classify_result(profile, {:ok, {:ok, issues}}) when is_list(issues) do
    candidates =
      issues
      |> Enum.filter(&match?(%Issue{id: id} when is_binary(id), &1))
      |> Enum.map(&%{&1 | project_profile: profile})

    {candidates, %{status: :ok}}
  end

  defp classify_result(_profile, {:exit, :timeout}), do: {[], %{status: :timeout, retry: :transient}}
  defp classify_result(_profile, _result), do: {[], %{status: :error, retry: :transient}}

  defp ambiguous_issue_ids(candidates) do
    candidates
    |> Enum.group_by(& &1.id, & &1.project_profile.key)
    |> Enum.reduce(MapSet.new(), fn
      {issue_id, profile_keys}, ambiguous_issue_ids ->
        if profile_keys |> Enum.uniq() |> length() > 1,
          do: MapSet.put(ambiguous_issue_ids, issue_id),
          else: ambiguous_issue_ids
    end)
  end

  defp empty_result do
    %{candidates: [], outcomes: %{}, ambiguous_issue_ids: MapSet.new()}
  end

  defp per_profile_timeout(opts) do
    case Keyword.get(opts, :timeout, @default_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout
    end
  end
end
