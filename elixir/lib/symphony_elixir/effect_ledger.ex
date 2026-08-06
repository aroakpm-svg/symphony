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
  @type adapter_result ::
          {:ok, native_resource()}
          | {:error, :no_effect, term()}
          | {:error, :unknown, term()}

  @spec effect_types() :: [effect_type()]
  def effect_types, do: @effect_types

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
        with :ok <- reconcile_effect(connection, context, "succeeded", resource), do: {:ok, resource}

      :not_found when status == "pending" ->
        perform(connection, context, attempt_id, adapter)

      :not_found ->
        {:error, :unknown_requires_reconciliation}

      {:unknown, reason} ->
        {:error, {:reconciliation_unknown, reason}}
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
    select status, native_resource
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

  defp reconcile_effect(connection, context, status, resource) do
    sql = "select symphony_staging.reconcile_effect($1, $2, $3, $4::jsonb)"
    params = [context.operation_id, context.request_fingerprint, status, encode_resource(resource)]
    boolean_result(Postgrex.query(connection, sql, params), :effect_reconciliation_rejected)
  end

  defp boolean_result({:ok, %Postgrex.Result{rows: [[true]]}}, _rejected), do: :ok
  defp boolean_result({:ok, _result}, rejected), do: {:error, rejected}
  defp boolean_result({:error, reason}, _rejected), do: {:error, reason}

  defp encode_resource(nil), do: nil
  defp encode_resource(resource) when is_map(resource), do: Jason.encode!(resource)
end
