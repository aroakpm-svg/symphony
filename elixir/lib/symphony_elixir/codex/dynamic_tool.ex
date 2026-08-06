defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{ClaimService, EffectLedger}
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @linear_comment_tool "linear_comment"
  @linear_state_tool "linear_state"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @managed_effect_input_schemas %{
    @linear_comment_tool => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["operationId", "body"],
      "properties" => %{
        "operationId" => %{"type" => "string"},
        "body" => %{"type" => "string"}
      }
    },
    @linear_state_tool => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["operationId", "state"],
      "properties" => %{
        "operationId" => %{"type" => "string"},
        "state" => %{"type" => "string"}
      }
    }
  }

  @comment_create_mutation """
  mutation SymphonyManagedComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) { success comment { id } }
  }
  """
  @comment_reconcile_query """
  query SymphonyManagedCommentReconcile($issueId: String!, $first: Int!, $after: String) {
    viewer { id }
    issue(id: $issueId) {
      comments(first: $first, after: $after) {
        nodes { id body user { id } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """
  @state_reconcile_query """
  query SymphonyManagedState($issueId: String!) { issue(id: $issueId) { state { name } } }
  """
  @state_lookup_query """
  query SymphonyManagedStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) { team { states(filter: {name: {eq: $stateName}}, first: 1) { nodes { id } } } }
  }
  """
  @state_update_mutation """
  mutation SymphonyManagedStateUpdate($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) { success }
  }
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @linear_comment_tool ->
        execute_managed_effect(@linear_comment_tool, arguments, opts)

      @linear_state_tool ->
        execute_managed_effect(@linear_state_tool, arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs(keyword()) :: [map()]
  def tool_specs(opts \\ []) do
    base = [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]

    if Keyword.get(opts, :managed_session, false) do
      base ++
        [
          managed_tool_spec(@linear_comment_tool, "Create one idempotent Linear comment through the managed effect ledger."),
          managed_tool_spec(@linear_state_tool, "Move the current Linear issue through the managed effect ledger.")
        ]
    else
      base
    end
  end

  defp managed_tool_spec(name, description) do
    %{"name" => name, "description" => description, "inputSchema" => Map.fetch!(@managed_effect_input_schemas, name)}
  end

  defp execute_managed_effect(tool, arguments, opts) do
    issue_id = Keyword.get(opts, :managed_issue_id)
    context_fetcher = Keyword.get(opts, :effect_context_fetcher, &ClaimService.effect_context/1)

    with true <- Keyword.get(opts, :managed_session, false),
         true <- is_binary(issue_id),
         {:ok, operation_id, value} <- normalize_managed_effect_arguments(tool, arguments),
         {:ok, connection, claim_context} <- context_fetcher.(issue_id),
         context <-
           Map.merge(claim_context, %{
             operation_id: operation_id,
             request_fingerprint: effect_fingerprint(tool, value)
           }),
         {:ok, resource} <- run_managed_effect(tool, connection, context, value, opts) do
      dynamic_tool_response(true, encode_payload(resource))
    else
      false -> failure_response(tool_error_payload(:managed_effect_context_required))
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_managed_effect_arguments(tool, arguments) when is_map(arguments) do
    operation_id = Map.get(arguments, "operationId") || Map.get(arguments, :operationId)
    value_key = if tool == @linear_comment_tool, do: "body", else: "state"
    value = Map.get(arguments, value_key) || Map.get(arguments, String.to_atom(value_key))

    if is_binary(operation_id) and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, operation_id) and
         is_binary(value) and
         String.trim(value) != "" do
      {:ok, operation_id, value}
    else
      {:error, :invalid_managed_effect_arguments}
    end
  end

  defp normalize_managed_effect_arguments(_tool, _arguments),
    do: {:error, :invalid_managed_effect_arguments}

  defp effect_fingerprint(tool, value) do
    :sha256
    |> :crypto.hash(Jason.encode!(%{"tool" => tool, "value" => value}))
    |> Base.encode16(case: :lower)
  end

  defp run_managed_effect(@linear_comment_tool, connection, context, body, opts) do
    client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    marker = "<!-- symphony-effect:#{context.operation_id} -->"
    marked_body = body <> "\n\n" <> marker

    adapter = fn ->
      create_linear_comment(client, context.issue_id, marked_body)
    end

    reconciler = fn -> reconcile_comment(client, context.issue_id, marked_body, nil) end
    EffectLedger.execute(connection, :linear_comment, context, adapter, reconciler)
  end

  defp run_managed_effect(@linear_state_tool, connection, context, state, opts) do
    client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    adapter = fn -> update_linear_state(client, context.issue_id, state) end
    reconciler = fn -> reconcile_state(client, context.issue_id, state) end
    EffectLedger.execute(connection, :linear_state, context, adapter, reconciler)
  end

  defp create_linear_comment(client, issue_id, body) do
    case client.(@comment_create_mutation, %{issueId: issue_id, body: body}, []) do
      {:ok, response} -> parse_comment_create(response)
      {:error, reason} -> {:error, :unknown, reason}
    end
  end

  defp parse_comment_create(response) do
    case get_in(response, ["data", "commentCreate"]) do
      %{"success" => true, "comment" => %{"id" => id}} -> {:ok, %{"id" => id}}
      _ -> {:error, :unknown, :comment_create_unconfirmed}
    end
  end

  defp reconcile_comment(client, issue_id, expected_body, after_cursor) do
    variables = %{issueId: issue_id, first: 100, after: after_cursor}

    case client.(@comment_reconcile_query, variables, []) do
      {:ok, response} ->
        comments = get_in(response, ["data", "issue", "comments"])
        viewer_id = get_in(response, ["data", "viewer", "id"])
        reconcile_comment_page(client, issue_id, expected_body, viewer_id, comments)

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  defp reconcile_comment_page(client, issue_id, expected_body, viewer_id, comments)
       when is_map(comments) and is_binary(viewer_id) do
    case Enum.find(comments["nodes"] || [], &matching_managed_comment?(&1, expected_body, viewer_id)) do
      %{"id" => id} -> {:found, %{"id" => id}}
      nil -> reconcile_next_comment_page(client, issue_id, expected_body, comments["pageInfo"])
    end
  end

  defp reconcile_comment_page(_client, _issue_id, _expected_body, _viewer_id, _comments),
    do: {:unknown, :invalid_comment_reconciliation_response}

  defp reconcile_next_comment_page(client, issue_id, expected_body, %{
         "hasNextPage" => true,
         "endCursor" => cursor
       })
       when is_binary(cursor),
       do: reconcile_comment(client, issue_id, expected_body, cursor)

  defp reconcile_next_comment_page(_client, _issue_id, _marker, %{"hasNextPage" => false}),
    do: :not_found

  defp reconcile_next_comment_page(_client, _issue_id, _marker, _page_info),
    do: {:unknown, :invalid_comment_reconciliation_response}

  defp matching_managed_comment?(comment, expected_body, viewer_id),
    do: comment["body"] == expected_body and get_in(comment, ["user", "id"]) == viewer_id

  defp update_linear_state(client, issue_id, state) do
    with {:ok, lookup} <- client.(@state_lookup_query, %{issueId: issue_id, stateName: state}, []),
         state_id when is_binary(state_id) <-
           get_in(lookup, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]),
         {:ok, response} <- client.(@state_update_mutation, %{issueId: issue_id, stateId: state_id}, []),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      {:ok, %{"state" => state, "stateId" => state_id}}
    else
      {:error, reason} -> {:error, :unknown, reason}
      _ -> {:error, :no_effect, :state_not_found_or_update_rejected}
    end
  end

  defp reconcile_state(client, issue_id, state) do
    case client.(@state_reconcile_query, %{issueId: issue_id}, []) do
      {:ok, response} ->
        current = get_in(response, ["data", "issue", "state", "name"])
        if current == state, do: {:found, %{"state" => state}}, else: :not_found

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- authorize_linear_document(query, opts),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp authorize_linear_document(query, opts) do
    if Keyword.get(opts, :managed_session, false) and graphql_mutation?(query) do
      {:error, :managed_linear_mutation_requires_effect_wrapper}
    else
      :ok
    end
  end

  defp graphql_mutation?(query) do
    with {:ok, document} <- strip_graphql_non_syntax(query),
         {:ok, tokens} <- graphql_tokens(document) do
      unsafe_graphql_operation?(tokens)
    else
      _error -> true
    end
  end

  defp strip_graphql_non_syntax(query) do
    document = Regex.replace(~r/"""(?:(?!""").)*"""/su, query, " ")
    document = Regex.replace(~r/"(?:\\.|[^"\\])*"/su, document, " ")
    document = Regex.replace(~r/#[^\r\n]*/u, document, " ")

    if String.contains?(document, "\"") do
      {:error, :unterminated_graphql_string}
    else
      {:ok, document}
    end
  end

  defp graphql_tokens(document) do
    tokens =
      ~r/[A-Za-z_][A-Za-z0-9_]*|[{}()]/u
      |> Regex.scan(document)
      |> List.flatten()

    if tokens == [], do: {:error, :empty_graphql_document}, else: {:ok, tokens}
  end

  defp unsafe_graphql_operation?(tokens) do
    case Enum.reduce_while(tokens, {:definition, 0, 0}, &scan_graphql_token/2) do
      :unsafe -> true
      {:definition, 0, 0} -> false
      _incomplete -> true
    end
  end

  defp scan_graphql_token("mutation", {:definition, 0, 0}), do: {:halt, :unsafe}
  defp scan_graphql_token("subscription", {:definition, 0, 0}), do: {:halt, :unsafe}

  defp scan_graphql_token(token, {:definition, 0, 0}) when token in ["query", "fragment"],
    do: {:cont, {:header, 0, 0}}

  defp scan_graphql_token("{", {:definition, 0, 0}), do: {:cont, {:selection, 1, 0}}
  defp scan_graphql_token(_token, {:definition, 0, 0}), do: {:halt, :unsafe}

  defp scan_graphql_token("(", {phase, braces, parens}),
    do: {:cont, {phase, braces, parens + 1}}

  defp scan_graphql_token(")", {phase, braces, parens}) when parens > 0,
    do: {:cont, {phase, braces, parens - 1}}

  defp scan_graphql_token("{", {:header, 0, 0}), do: {:cont, {:selection, 1, 0}}

  defp scan_graphql_token("{", {:selection, braces, parens}),
    do: {:cont, {:selection, braces + 1, parens}}

  defp scan_graphql_token("}", {:selection, 1, 0}), do: {:cont, {:definition, 0, 0}}

  defp scan_graphql_token("}", {:selection, braces, parens}) when braces > 1,
    do: {:cont, {:selection, braces - 1, parens}}

  defp scan_graphql_token(_token, state), do: {:cont, state}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:managed_linear_mutation_requires_effect_wrapper) do
    %{
      "error" => %{
        "message" => "Managed Symphony sessions cannot execute raw Linear mutations. Use the ARO-165 effect wrapper for comments and state changes."
      }
    }
  end

  defp tool_error_payload(:managed_effect_context_required) do
    %{"error" => %{"message" => "Managed effect tools require an orchestrator-owned active claim context."}}
  end

  defp tool_error_payload(:invalid_managed_effect_arguments) do
    %{"error" => %{"message" => "Managed effect tools require a stable operationId and a non-empty value."}}
  end

  defp tool_error_payload(:effect_attempt_in_flight) do
    %{"error" => %{"message" => "This managed effect already has an active attempt; reconcile or retry after its lease."}}
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
