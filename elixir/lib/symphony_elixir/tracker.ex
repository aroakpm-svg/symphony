defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, Linear.Client, ProjectProfiles}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_candidate_issues(map()) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states(map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_routed_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids(map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback review_history(String.t()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks fetch_candidate_issues: 1

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_candidate_issues(map()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(profile) when is_map(profile) do
    adapter = adapter()

    if function_exported?(adapter, :fetch_candidate_issues, 1) do
      # The adapter is selected at runtime and this arity is an optional callback.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(adapter, :fetch_candidate_issues, [profile])
    else
      {:error, :profile_scoped_candidate_fetch_unsupported}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_states(map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(profile, states) when is_map(profile) and is_list(states) do
    adapter().fetch_issues_by_states(profile, states)
  end

  @spec fetch_routed_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_routed_issues_by_states(states) do
    adapter().fetch_routed_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue_states_by_ids(map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(profile, issue_ids) when is_map(profile) and is_list(issue_ids) do
    adapter().fetch_issue_states_by_ids(profile, issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec review_history(String.t()) :: {:ok, map()} | {:error, term()}
  def review_history(issue_id) do
    adapter().review_history(issue_id)
  end

  @spec validate_identity() :: {:ok, %{viewer_id: String.t()}} | {:error, atom()}
  def validate_identity do
    settings = Config.settings!()

    case settings.tracker.kind do
      "memory" -> {:ok, %{viewer_id: "memory"}}
      _ -> validate_linear_identity(linear_client_module(), settings.project_profiles)
    end
  end

  defp validate_linear_identity(client, %{profiles: profiles} = project_profiles)
       when map_size(profiles) > 0 do
    project_ids = ProjectProfiles.list(project_profiles) |> Enum.map(& &1.linear_project_id)

    if function_exported?(client, :validate_identity, 1),
      do: client.validate_identity(project_ids: project_ids),
      else: {:error, :linear_response_invalid}
  end

  defp validate_linear_identity(client, _project_profiles), do: client.validate_identity()

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end

  defp linear_client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end
end
