defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          id
          slugId
        }
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @profile_query """
  query SymphonyLinearProjectPoll($projectId: ID!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {id: {eq: $projectId}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          id
          slugId
        }
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          id
          slugId
        }
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @project_identity_query """
  query SymphonyLinearProjectIdentity($projectId: String!) {
    project(id: $projectId) {
      id
    }
  }
  """

  @spec validate_identity(keyword()) :: {:ok, %{viewer_id: String.t()}} | {:error, atom()}
  def validate_identity(opts \\ []) when is_list(opts) do
    payload = build_graphql_payload(@viewer_query, %{}, nil)
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)
    project_ids = Keyword.get(opts, :project_ids, [])

    with {:ok, headers} <- graphql_headers(),
         {:ok, response} <- identity_request(request_fun, payload, headers),
         {:ok, viewer} <- classify_identity_response(response),
         :ok <- validate_project_identity_access(project_ids, request_fun, headers) do
      {:ok, viewer}
    else
      {:error, :missing_linear_api_token} ->
        {:error, :linear_unauthorized}

      {:error, reason}
      when reason in [
             :linear_unauthorized,
             :linear_forbidden,
             :linear_identity_missing,
             :linear_response_invalid,
             :linear_workspace_mismatch
           ] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :linear_unavailable}
    end
  end

  defp validate_project_identity_access([], _request_fun, _headers), do: :ok

  defp validate_project_identity_access(project_ids, request_fun, headers)
       when is_list(project_ids) do
    project_ids
    |> Enum.reduce_while(:ok, fn project_id, :ok ->
      with {:ok, expected_project_id} <- Ecto.UUID.cast(project_id),
           payload <-
             build_graphql_payload(
               @project_identity_query,
               %{projectId: expected_project_id},
               nil
             ),
           {:ok, response} <- identity_request(request_fun, payload, headers),
           :ok <- classify_project_identity_response(response, expected_project_id) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _invalid -> {:halt, {:error, :linear_response_invalid}}
      end
    end)
  end

  defp validate_project_identity_access(_project_ids, _request_fun, _headers),
    do: {:error, :linear_response_invalid}

  defp classify_project_identity_response(%{status: 200, body: body}, expected_project_id) do
    with {:ok, payload} <- decode_identity_body(body),
         %{"data" => %{"project" => %{"id" => actual_project_id}}} <- payload,
         {:ok, actual_project_id} <- Ecto.UUID.cast(actual_project_id),
         true <- actual_project_id == expected_project_id do
      :ok
    else
      %{"errors" => errors} -> classify_project_identity_errors(errors)
      _missing_or_mismatch -> {:error, :linear_workspace_mismatch}
    end
  end

  defp classify_project_identity_response(%{status: 401}, _expected_project_id),
    do: {:error, :linear_unauthorized}

  defp classify_project_identity_response(%{status: 403}, _expected_project_id),
    do: {:error, :linear_workspace_mismatch}

  defp classify_project_identity_response(%{status: status}, _expected_project_id)
       when is_integer(status),
       do: {:error, :linear_unavailable}

  defp classify_project_identity_response(_response, _expected_project_id),
    do: {:error, :linear_response_invalid}

  defp decode_identity_body(body) when is_map(body), do: {:ok, body}
  defp decode_identity_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_identity_body(_body), do: {:error, :invalid_body}

  defp classify_project_identity_errors(errors) do
    case classify_identity_graphql_errors(errors) do
      :linear_unauthorized -> {:error, :linear_unauthorized}
      _not_accessible -> {:error, :linear_workspace_mismatch}
    end
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    project_slug = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_candidate_issues(map()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(%{linear_project_id: project_id}) when is_binary(project_id) do
    tracker = Config.settings!().tracker

    if is_nil(tracker.api_key) do
      {:error, :missing_linear_api_token}
    else
      with {:ok, assignee_filter} <- routing_assignee_filter() do
        do_fetch_by_project_id(project_id, tracker.active_states, assignee_filter)
      end
    end
  end

  def fetch_candidate_issues(_profile), do: {:error, :invalid_linear_project_profile}

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_legacy_issues_by_states(state_names, nil)
  end

  @spec fetch_issues_by_states(map(), [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(%{linear_project_id: project_id} = profile, state_names)
      when is_binary(project_id) and is_list(state_names) do
    with {:ok, assignee_filter} <- routing_assignee_filter(),
         {:ok, issues} <- do_fetch_by_project_id(project_id, state_names, assignee_filter) do
      {:ok, Enum.map(issues, &attach_profile(&1, profile))}
    end
  end

  @spec fetch_routed_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_routed_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, assignee_filter} <- routing_assignee_filter() do
      fetch_legacy_issues_by_states(state_names, assignee_filter)
    end
  end

  defp fetch_legacy_issues_by_states(state_names, assignee_filter) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_slug = tracker.project_slug

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, assignee_filter)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec fetch_issue_states_by_ids(map(), [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(%{linear_project_id: project_id} = profile, issue_ids)
      when is_binary(project_id) and is_list(issue_ids) do
    with {:ok, issues} <- fetch_issue_states_by_ids(issue_ids) do
      {:ok,
       issues
       |> Enum.filter(&(&1.project_id == project_id))
       |> Enum.map(&attach_profile(&1, profile))}
    end
  end

  defp attach_profile(%Issue{} = issue, profile) do
    %{issue | project_profile: profile, repository: profile.repository}
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  @doc false
  @spec fetch_candidate_issues_for_test(
          map(),
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_test(%{linear_project_id: project_id}, state_names, graphql_fun)
      when is_binary(project_id) and is_list(state_names) and is_function(graphql_fun, 2) do
    do_fetch_by_project_id(project_id, state_names, nil, graphql_fun)
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_project_id(project_id, state_names, assignee_filter, graphql_fun \\ &graphql/2) do
    do_fetch_by_project_id_page(project_id, state_names, assignee_filter, graphql_fun, nil, [])
  end

  defp do_fetch_by_project_id_page(
         project_id,
         state_names,
         assignee_filter,
         graphql_fun,
         after_cursor,
         acc_issues
       ) do
    with {:ok, body} <-
           graphql_fun.(@profile_query, %{
             projectId: project_id,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_project_id_page(
            project_id,
            state_names,
            assignee_filter,
            graphql_fun,
            next_cursor,
            updated_acc
          )

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp identity_request(request_fun, payload, headers) when is_function(request_fun, 2) do
    request_fun.(payload, headers)
  rescue
    _exception -> {:error, :identity_request_failed}
  catch
    _kind, _reason -> {:error, :identity_request_failed}
  end

  defp identity_request(_request_fun, _payload, _headers), do: {:error, :identity_request_invalid}

  defp classify_identity_response(%{status: 200, body: body}), do: classify_identity_body(body)
  defp classify_identity_response(%{status: 401}), do: {:error, :linear_unauthorized}
  defp classify_identity_response(%{status: 403}), do: {:error, :linear_forbidden}
  defp classify_identity_response(%{status: status}) when is_integer(status), do: {:error, :linear_unavailable}
  defp classify_identity_response(_response), do: {:error, :linear_response_invalid}

  defp classify_identity_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} -> classify_identity_payload(payload)
      {:error, _reason} -> {:error, :linear_response_invalid}
    end
  end

  defp classify_identity_body(body) when is_map(body), do: classify_identity_payload(body)
  defp classify_identity_body(_body), do: {:error, :linear_response_invalid}

  defp classify_identity_payload(%{"errors" => errors}) do
    {:error, classify_identity_graphql_errors(errors)}
  end

  defp classify_identity_payload(%{"data" => %{"viewer" => %{"id" => viewer_id}}})
       when is_binary(viewer_id) do
    case String.trim(viewer_id) do
      "" -> {:error, :linear_identity_missing}
      _viewer_id -> {:ok, %{viewer_id: viewer_id}}
    end
  end

  defp classify_identity_payload(%{"data" => %{"viewer" => _viewer}}),
    do: {:error, :linear_identity_missing}

  defp classify_identity_payload(_payload), do: {:error, :linear_response_invalid}

  defp classify_identity_graphql_errors(errors) when is_list(errors) do
    cond do
      Enum.any?(errors, &(identity_graphql_error_kind(&1) == :linear_forbidden)) -> :linear_forbidden
      Enum.any?(errors, &(identity_graphql_error_kind(&1) == :linear_unauthorized)) -> :linear_unauthorized
      true -> :linear_response_invalid
    end
  end

  defp classify_identity_graphql_errors(_errors), do: :linear_response_invalid

  defp identity_graphql_error_kind(%{} = error) do
    error
    |> get_in(["extensions", "code"])
    |> identity_graphql_error_kind_from_value()
    |> case do
      nil -> error |> Map.get("message") |> identity_graphql_error_kind_from_value()
      kind -> kind
    end
  end

  defp identity_graphql_error_kind(_error), do: nil

  defp identity_graphql_error_kind_from_value(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized in ["forbidden", "permission_denied"] or String.contains?(normalized, "forbidden") ->
        :linear_forbidden

      normalized in ["unauthenticated", "authentication_error", "authentication_required"] or
        String.contains?(normalized, "unauthenticated") or
          String.contains?(normalized, "authentication") ->
        :linear_unauthorized

      true ->
        nil
    end
  end

  defp identity_graphql_error_kind_from_value(_value), do: nil

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      project_id: get_in(issue, ["project", "id"]),
      project_slug: get_in(issue, ["project", "slugId"]),
      project_profile: nil,
      repository: nil,
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
