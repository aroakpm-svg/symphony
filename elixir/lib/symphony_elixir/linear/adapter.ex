defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @review_history_query """
  query SymphonyReviewHistory($issueId: String!, $first: Int!, $after: String) {
    issue(id: $issueId) {
      comments(first: $first, after: $after) {
        nodes { body }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_routed_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_routed_issues_by_states(states), do: client_module().fetch_routed_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec review_history(String.t()) :: {:ok, map()} | {:error, term()}
  def review_history(issue_id) when is_binary(issue_id) do
    fetch_review_history(issue_id, nil, %{
      dedup: MapSet.new(),
      rework: MapSet.new(),
      transition_intents: %{},
      completed_transitions: %{},
      invalid_transition: false,
      last_head_sha: nil
    })
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  defp fetch_review_history(issue_id, after_cursor, history) do
    variables = %{issueId: issue_id, first: 50, after: after_cursor}

    with {:ok, response} <- client_module().graphql(@review_history_query, variables),
         %{"nodes" => nodes, "pageInfo" => page_info} <-
           get_in(response, ["data", "issue", "comments"]),
         true <- is_list(nodes) and is_map(page_info) do
      history = Enum.reduce(nodes, history, &collect_history/2)

      case page_info do
        %{"hasNextPage" => true, "endCursor" => cursor} when is_binary(cursor) and cursor != "" ->
          fetch_review_history(issue_id, cursor, history)

        %{"hasNextPage" => false} ->
          finalize_review_history(history)

        _ ->
          {:error, :invalid_review_history_page_info}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_review_history_response}
    end
  end

  defp collect_history(%{"body" => body}, history) when is_binary(body) do
    history
    |> collect_dedup(body)
    |> collect_transition(body)
    |> collect_head_sha(body)
  end

  defp collect_history(_comment, history), do: history

  defp collect_dedup(history, body) do
    case Regex.run(~r/dedup-key: `([^`]+)`/, body, capture: :all_but_first) do
      [key] ->
        rework =
          if String.contains?(body, "Review Convergence Gate returned this issue to In Progress"),
            do: MapSet.put(history.rework, key),
            else: history.rework

        %{history | dedup: MapSet.put(history.dedup, key), rework: rework}

      _ ->
        history
    end
  end

  defp collect_head_sha(history, body) do
    patterns = [
      ~r/currentHeadSha = reviewedHeadSha = `([0-9a-f]{40})`/i,
      ~r/currentHeadSha: `([0-9a-f]{40})`/i
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, body, capture: :all_but_first) do
        [head_sha] -> String.downcase(head_sha)
        _ -> nil
      end
    end)
    |> case do
      nil -> history
      head_sha -> %{history | last_head_sha: head_sha}
    end
  end

  defp collect_transition(history, body) do
    operation_id = capture(body, ~r/transition-operation-id: `([^`]+)`/)

    cond do
      is_nil(operation_id) ->
        history

      String.contains?(body, "transition-operation: `intent`") ->
        collect_transition_intent(history, body, operation_id)

      String.contains?(body, "transition-operation: `completed`") ->
        collect_transition_completion(history, body, operation_id)

      true ->
        history
    end
  end

  defp collect_transition_intent(history, body, operation_id) do
    intent = %{
      operation_id: operation_id,
      head_sha: capture(body, ~r/currentHeadSha: `([0-9a-f]{40})`/i),
      target_state: capture(body, ~r/target-state: `([^`]+)`/)
    }

    existing = history.transition_intents[operation_id]

    invalid? =
      is_nil(intent.head_sha) or is_nil(intent.target_state) or
        (not is_nil(existing) and existing != intent)

    %{
      history
      | transition_intents: Map.put(history.transition_intents, operation_id, intent),
        invalid_transition: history.invalid_transition or invalid?
    }
  end

  defp collect_transition_completion(history, body, operation_id) do
    completion = %{
      operation_id: operation_id,
      head_sha: capture(body, ~r/currentHeadSha: `([0-9a-f]{40})`/i),
      dedup_key: capture(body, ~r/dedup-key: `([^`]+)`/)
    }

    existing = history.completed_transitions[operation_id]

    invalid? =
      is_nil(completion.head_sha) or completion.dedup_key != operation_id or
        (not is_nil(existing) and existing != completion)

    %{
      history
      | completed_transitions: Map.put(history.completed_transitions, operation_id, completion),
        invalid_transition: history.invalid_transition or invalid?
    }
  end

  defp capture(body, pattern) do
    case Regex.run(pattern, body, capture: :all_but_first) do
      [value] -> value
      _ -> nil
    end
  end

  defp finalize_review_history(history) do
    completed_ids = Map.keys(history.completed_transitions)

    completed_without_intent =
      MapSet.difference(MapSet.new(completed_ids), MapSet.new(Map.keys(history.transition_intents)))

    mismatched_completion? =
      Enum.any?(history.completed_transitions, fn {operation_id, completion} ->
        case history.transition_intents[operation_id] do
          %{head_sha: head_sha} -> completion.head_sha != head_sha
          _ -> true
        end
      end)

    if history.invalid_transition or MapSet.size(completed_without_intent) > 0 or mismatched_completion? do
      {:error, :invalid_review_transition_history}
    else
      {:ok,
       %{
         dedup: history.dedup,
         rework_count: MapSet.size(history.rework),
         pending_transitions: Map.drop(history.transition_intents, completed_ids),
         last_head_sha: history.last_head_sha
       }}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
