defmodule SymphonyElixir.DispatchCandidate do
  @moduledoc """
  Authorizes refreshed multi-project candidates without performing dispatch effects.
  """

  alias SymphonyElixir.ClaimService
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ProjectProfiles

  @default_active_states ["Todo", "In Progress"]
  @worker_label "symphony-worker"

  @type result :: {:ok, Issue.t()} | {:skip, atom()} | {:retry, atom()}

  @spec authorize(Issue.t(), ProjectProfiles.t(), keyword()) :: result()
  def authorize(%Issue{} = issue, profiles, opts \\ []) do
    active_states = Keyword.get(opts, :active_states, @default_active_states)
    route_reader = Keyword.get(opts, :route_reader, &ClaimService.exclusive_route/1)

    with :ok <- require_active_state(issue, active_states),
         :ok <- require_worker_label(issue),
         {:ok, profile} <- resolve_profile(profiles, issue.project_id),
         :ok <- require_same_profile(issue.project_profile, profile),
         :ok <- require_exclusive_route(issue, route_reader) do
      {:ok, %{issue | project_profile: profile, repository: profile.repository}}
    end
  end

  defp require_active_state(%Issue{state: state}, active_states)
       when is_binary(state) and is_list(active_states) do
    active_states = MapSet.new(active_states, &normalize/1)

    if MapSet.member?(active_states, normalize(state)),
      do: :ok,
      else: {:skip, :inactive_state}
  end

  defp require_active_state(_issue, _active_states), do: {:skip, :inactive_state}

  defp require_worker_label(%Issue{labels: labels}) when is_list(labels) do
    if Enum.any?(labels, &(normalize(&1) == @worker_label)),
      do: :ok,
      else: {:skip, :missing_worker_label}
  end

  defp require_worker_label(_issue), do: {:skip, :missing_worker_label}

  defp resolve_profile(%{profiles: profiles} = approved_profiles, project_id)
       when is_map(profiles) and is_binary(project_id) do
    case ProjectProfiles.fetch_by_linear_project_id(approved_profiles, project_id) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:skip, :unknown_project}
    end
  end

  defp resolve_profile(_profiles, _project_id), do: {:skip, :unknown_project}

  defp require_same_profile(profile, profile), do: :ok
  defp require_same_profile(_polled_profile, _refreshed_profile), do: {:skip, :project_changed}

  defp require_exclusive_route(issue, route_reader) when is_function(route_reader, 1) do
    case route_reader.(issue) do
      {:ok, %{routing_revision: revision}} when is_integer(revision) and revision > 0 ->
        :ok

      {:ineligible, reason} when is_atom(reason) ->
        {:skip, reason}

      _unavailable ->
        {:retry, :routing_unavailable}
    end
  end

  defp require_exclusive_route(_issue, _route_reader), do: {:retry, :routing_unavailable}

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
