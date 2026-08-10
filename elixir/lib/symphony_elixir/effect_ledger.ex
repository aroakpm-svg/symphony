defmodule SymphonyElixir.EffectLedger do
  @moduledoc """
  Coordinates the fixed ARO-165 side effects with a durable PostgreSQL intent.

  Native Git, GitHub, and Linear resources remain authoritative. A pending or
  unknown intent is reconciled before another external call is allowed.
  """

  @effect_types ~w(
    linear_comment github_comment git_commit git_push github_pr_create
    github_pr_update linear_state
  )a
  @attempt_lease_ms 300_000
  @list_operations_sql """
  select operation_id, effect_type, request_fingerprint, status, native_resource,
         issue_id, claim_id::text, generation
  from symphony_staging.list_effect_operations(
    $1, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid
  )
  order by operation_id
  """

  @type effect_type ::
          :linear_comment
          | :github_comment
          | :git_commit
          | :git_push
          | :github_pr_create
          | :github_pr_update
          | :linear_state

  @type context :: %{
          operation_id: String.t(),
          request_fingerprint: String.t(),
          issue_id: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          node_id: String.t(),
          node_instance_id: String.t()
        }

  @type native_resource :: map() | nil
  @type operation_status :: :pending | :succeeded | :failed_no_effect | :unknown
  @type operation :: %{
          operation_id: String.t(),
          effect_type: effect_type(),
          request_fingerprint: String.t(),
          status: operation_status(),
          native_resource: native_resource(),
          issue_id: String.t(),
          claim_id: String.t(),
          generation: pos_integer()
        }
  @type adapter_result ::
          {:ok, native_resource()}
          | {:error, :no_effect, term()}
          | {:error, :unknown, term()}

  @spec effect_types() :: [effect_type()]
  def effect_types, do: @effect_types

  @spec list_operations(Postgrex.conn(), map()) :: {:ok, [operation()]} | {:error, term()}
  def list_operations(connection, claim_context) do
    with {:ok, params} <- list_operation_params(claim_context) do
      connection
      |> run_query(@list_operations_sql, params)
      |> decode_operations(claim_context)
    end
  end

  @spec execute(
          Postgrex.conn(),
          effect_type(),
          context(),
          (-> adapter_result()),
          (-> {:found, native_resource()} | :not_found | {:unknown, term()})
        ) :: {:ok, native_resource()} | {:error, term()}
  def execute(connection, effect_type, context, adapter, reconciler)
      when effect_type in @effect_types and is_map(context) and is_function(adapter, 0) and
             is_function(reconciler, 0) do
    attempt_id = Ecto.UUID.generate()
    context = namespace_operation(context)

    with {:ok, status, resource, granted_attempt_id} <-
           begin_effect(connection, effect_type, context, attempt_id) do
      continue(connection, status, resource, context, granted_attempt_id, adapter, reconciler)
    end
  end

  def execute(_connection, effect_type, _context, _adapter, _reconciler),
    do: {:error, {:unsupported_effect_type, effect_type}}

  defp continue(_connection, "succeeded", resource, _context, _attempt_id, _adapter, _reconciler),
    do: {:ok, resource}

  defp continue(_connection, "in-flight", _resource, _context, _attempt_id, _adapter, _reconciler),
    do: {:error, :effect_attempt_in_flight}

  defp continue(connection, status, _resource, context, attempt_id, adapter, reconciler)
       when status in ["pending", "unknown"] do
    case reconciler.() do
      {:found, resource} ->
        with :ok <- reconcile_effect(connection, context, attempt_id, "succeeded", resource),
             do: {:ok, resource}

      :not_found when status == "pending" ->
        perform(connection, context, attempt_id, adapter)

      :not_found ->
        {:error, :unknown_requires_reconciliation}

      {:unknown, reason} ->
        with :ok <- relinquish_effect(connection, context, attempt_id) do
          {:error, {:reconciliation_unknown, reason}}
        end
    end
  end

  defp continue(_connection, status, _resource, _context, _attempt_id, _adapter, _reconciler),
    do: {:error, {:invalid_effect_status, status}}

  defp perform(connection, context, attempt_id, adapter) do
    case adapter.() do
      {:ok, resource} ->
        case finish_effect(connection, context, attempt_id, "succeeded", resource, nil) do
          :ok -> {:ok, resource}
          {:error, reason} -> {:error, {:ledger_completion_unknown, reason}}
        end

      {:error, :no_effect, reason} ->
        with :ok <- finish_effect(connection, context, attempt_id, "failed-no-effect", nil, inspect(reason)) do
          {:error, {:failed_no_effect, reason}}
        end

      {:error, :unknown, reason} ->
        with :ok <- finish_effect(connection, context, attempt_id, "unknown", nil, inspect(reason)) do
          {:error, {:effect_unknown, reason}}
        end

      other ->
        {:error, {:invalid_adapter_result, other}}
    end
  end

  defp begin_effect(connection, effect_type, context, attempt_id) do
    sql = """
    select status, native_resource, attempt_id::text
    from symphony_staging.begin_effect(
      $1, $2, $3, $4, $5::text::uuid, $6, $7::text::uuid, $8::text::uuid,
      $9::text::uuid, $10
    )
    """

    params = [
      context.operation_id,
      Atom.to_string(effect_type),
      context.request_fingerprint,
      context.issue_id,
      context.claim_id,
      context.generation,
      context.node_id,
      context.node_instance_id,
      attempt_id,
      @attempt_lease_ms
    ]

    case Postgrex.query(connection, sql, params) do
      {:ok, %Postgrex.Result{rows: [[status, resource, granted_attempt_id]]}} ->
        {:ok, status, resource, granted_attempt_id}

      {:ok, result} ->
        {:error, {:unexpected_begin_effect_result, result.num_rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_effect(connection, context, attempt_id, status, resource, failure_reason) do
    sql = "select symphony_staging.finish_effect($1, $2, $3::text::uuid, $4, $5::jsonb, $6)"

    params = [
      context.operation_id,
      context.request_fingerprint,
      attempt_id,
      status,
      encode_resource(resource),
      failure_reason
    ]

    boolean_result(Postgrex.query(connection, sql, params), :effect_finish_rejected)
  end

  defp reconcile_effect(connection, context, attempt_id, status, resource) do
    sql = """
    select symphony_staging.reconcile_effect(
      $1, $2, $3::text::uuid, $4, $5::text::uuid, $6, $7::text::uuid,
      $8::text::uuid, $9, $10::jsonb
    )
    """

    params = [
      context.operation_id,
      context.request_fingerprint,
      attempt_id,
      context.issue_id,
      context.claim_id,
      context.generation,
      context.node_id,
      context.node_instance_id,
      status,
      encode_resource(resource)
    ]

    boolean_result(Postgrex.query(connection, sql, params), :effect_reconciliation_rejected)
  end

  defp relinquish_effect(connection, context, attempt_id) do
    sql = "select symphony_staging.relinquish_effect($1, $2, $3::text::uuid)"
    params = [context.operation_id, context.request_fingerprint, attempt_id]
    boolean_result(Postgrex.query(connection, sql, params), :effect_relinquish_rejected)
  end

  defp namespace_operation(context) do
    namespaced_id = context.issue_id <> ":" <> context.operation_id
    %{context | operation_id: namespaced_id}
  end

  defp list_operation_params(%{
         issue_id: issue_id,
         claim_id: claim_id,
         generation: generation,
         node_id: node_id,
         node_instance_id: node_instance_id
       }) do
    if non_empty_string?(issue_id) and valid_uuid?(claim_id) and is_integer(generation) and
         generation > 0 and
         valid_uuid?(node_id) and valid_uuid?(node_instance_id) do
      {:ok, [issue_id, claim_id, generation, node_id, node_instance_id]}
    else
      {:error, :invalid_claim_context}
    end
  end

  defp list_operation_params(claim_context), do: {:error, {:invalid_claim_context, claim_context}}

  defp run_query(connection, sql, params) when is_function(connection, 2), do: connection.(sql, params)
  defp run_query(connection, sql, params), do: Postgrex.query(connection, sql, params)

  defp decode_operations({:ok, %Postgrex.Result{rows: rows, num_rows: count}}, claim_context)
       when is_list(rows) and count == length(rows) do
    decode_operation_rows(rows, claim_context)
  end

  defp decode_operations({:ok, %Postgrex.Result{num_rows: count}}, _claim_context),
    do: {:error, {:unexpected_list_operations_result, count}}

  defp decode_operations({:error, reason}, _claim_context), do: {:error, reason}

  defp decode_operations(result, _claim_context),
    do: {:error, {:unexpected_list_operations_result, result}}

  defp decode_operation_rows(rows, claim_context) do
    Enum.reduce_while(rows, {:ok, MapSet.new(), []}, fn row, {:ok, seen, operations} ->
      case decode_operation_row(row, claim_context) do
        {:ok, operation} ->
          add_operation(seen, operations, operation)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _seen, operations} -> {:ok, Enum.reverse(operations)}
      error -> error
    end
  end

  defp add_operation(seen, operations, operation) do
    if MapSet.member?(seen, operation.operation_id) do
      {:halt, {:error, {:duplicate_operation_id, operation.operation_id}}}
    else
      {:cont, {:ok, MapSet.put(seen, operation.operation_id), [operation | operations]}}
    end
  end

  defp decode_operation_row(
         [operation_id, effect_type, request_fingerprint, status, native_resource, issue_id, claim_id, generation],
         claim_context
       ) do
    with {:ok, operation_id} <- non_empty_value(operation_id, :operation_id),
         {:ok, effect_type} <- decode_effect_type(effect_type),
         {:ok, request_fingerprint} <- non_empty_value(request_fingerprint, :request_fingerprint),
         {:ok, status} <- decode_operation_status(status),
         :ok <- valid_native_resource(native_resource),
         :ok <- matching_context(issue_id, claim_id, generation, claim_context) do
      {:ok,
       %{
         operation_id: operation_id,
         effect_type: effect_type,
         request_fingerprint: request_fingerprint,
         status: status,
         native_resource: native_resource,
         issue_id: issue_id,
         claim_id: claim_id,
         generation: generation
       }}
    end
  end

  defp decode_operation_row(row, _claim_context),
    do: {:error, {:invalid_effect_operation_row, row}}

  defp non_empty_value(value, _field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :blank_effect_operation_field}, else: {:ok, value}
  end

  defp non_empty_value(_value, field), do: {:error, {:invalid_effect_operation_field, field}}

  defp decode_effect_type(effect_type) when is_binary(effect_type) do
    case Enum.find(@effect_types, &(Atom.to_string(&1) == effect_type)) do
      nil -> {:error, {:unsupported_effect_type, effect_type}}
      effect_type -> {:ok, effect_type}
    end
  end

  defp decode_effect_type(effect_type), do: {:error, {:unsupported_effect_type, effect_type}}

  defp decode_operation_status(status) do
    case status do
      "pending" -> {:ok, :pending}
      "succeeded" -> {:ok, :succeeded}
      "failed-no-effect" -> {:ok, :failed_no_effect}
      "unknown" -> {:ok, :unknown}
      _ -> {:error, {:invalid_effect_status, status}}
    end
  end

  defp valid_native_resource(nil), do: :ok
  defp valid_native_resource(resource) when is_map(resource), do: :ok
  defp valid_native_resource(resource), do: {:error, {:invalid_native_resource, resource}}

  defp matching_context(issue_id, claim_id, generation, claim_context) do
    if issue_id == claim_context.issue_id and claim_id == claim_context.claim_id and
         generation == claim_context.generation do
      :ok
    else
      {:error, :effect_operation_context_mismatch}
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp boolean_result({:ok, %Postgrex.Result{rows: [[true]]}}, _rejected), do: :ok
  defp boolean_result({:ok, _result}, rejected), do: {:error, rejected}
  defp boolean_result({:error, reason}, _rejected), do: {:error, reason}

  defp encode_resource(nil), do: nil
  defp encode_resource(resource) when is_map(resource), do: resource
end
