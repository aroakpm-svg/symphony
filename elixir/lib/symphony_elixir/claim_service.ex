defmodule SymphonyElixir.ClaimService do
  @moduledoc """
  Owns the PostgreSQL connection used for cross-machine issue claims.

  When enabled, every dispatch must first obtain a database claim. Owned leases are
  renewed in the background; uncertain renewals are reported to the orchestrator so
  the affected worker stops before performing more work.
  """

  use GenServer

  alias SymphonyElixir.ClaimConnection
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @call_timeout_ms 15_000

  defstruct [:connection, :settings, :timer_ref, :transaction_fun, claims: %{}]

  @type claim :: %{
          issue_id: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          lease_deadline_ms: integer(),
          owner: pid(),
          acquisition: :new | :existing
        }

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    settings = Config.settings!().claim

    if settings.enabled do
      GenServer.start_link(__MODULE__, settings, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: Config.settings!().claim.enabled

  @spec exclusive_route(Issue.t()) ::
          {:ok, %{routing_revision: pos_integer()}} | {:ineligible, atom()} | {:error, atom()}
  def exclusive_route(%Issue{} = issue) do
    if enabled?() do
      case safe_call({:exclusive_route, issue}) do
        {:error, {:claim_service_unavailable, _reason}} -> {:error, :claim_service_unavailable}
        result -> result
      end
    else
      {:error, :claim_service_unavailable}
    end
  end

  @spec claim(Issue.t(), pid()) :: {:ok, claim() | nil} | {:error, term()}
  def claim(%Issue{} = issue, owner \\ self()) when is_pid(owner) do
    cond do
      enabled?() -> safe_call({:claim, issue, owner})
      coordinator_running?() -> {:error, :claim_service_disabling}
      true -> {:ok, nil}
    end
  end

  @spec release(String.t()) :: :ok | {:error, term()}
  def release(issue_id) when is_binary(issue_id) do
    if coordinator_running?(), do: safe_call({:release, issue_id}), else: :ok
  end

  @spec release_if_owned(String.t(), map()) :: :ok | {:error, term()}
  def release_if_owned(issue_id, %{claim_id: claim_id, generation: generation} = identity)
      when is_binary(issue_id) and is_binary(claim_id) and is_integer(generation) do
    if coordinator_running?(),
      do: safe_call({:release_if_owned, issue_id, identity}),
      else: {:error, :claim_service_unavailable}
  end

  @spec complete(String.t()) :: :ok | {:error, term()}
  def complete(issue_id) when is_binary(issue_id) do
    if coordinator_running?(), do: safe_call({:complete, issue_id}), else: :ok
  end

  @spec bind_worker(String.t(), pid()) :: :ok | {:error, term()}
  def bind_worker(issue_id, worker) when is_binary(issue_id) and is_pid(worker) do
    cond do
      coordinator_running?() -> safe_call({:bind_worker, issue_id, worker})
      enabled?() -> {:error, :claim_service_unavailable}
      true -> :ok
    end
  end

  @spec active?(String.t()) :: boolean()
  def active?(issue_id) when is_binary(issue_id) do
    if coordinator_running?() do
      case safe_call({:active?, issue_id}) do
        active when is_boolean(active) -> active
        {:error, _reason} -> false
      end
    else
      true
    end
  end

  @spec effect_context(String.t()) :: {:ok, Postgrex.conn(), map()} | {:error, term()}
  def effect_context(issue_id) when is_binary(issue_id) do
    if coordinator_running?(), do: safe_call({:effect_context, issue_id}), else: {:error, :claim_service_unavailable}
  end

  @spec effect_ledger_ready?() :: boolean()
  def effect_ledger_ready? do
    coordinator_running?() and safe_call(:effect_ledger_ready?) == true
  end

  @doc false
  @spec call_for_test(term()) :: term()
  def call_for_test(request), do: safe_call(request)

  @doc false
  @spec lease_deadline_for_test(integer(), pos_integer()) :: integer()
  def lease_deadline_for_test(grant_started_ms, lease_ms), do: grant_started_ms + lease_ms

  @impl true
  def init(settings) do
    Process.flag(:trap_exit, true)

    with {:ok, connection} <- ClaimConnection.connect(settings) do
      {:ok, schedule_heartbeat(%__MODULE__{connection: connection, settings: settings})}
    end
  end

  @impl true
  def handle_call({:exclusive_route, issue}, _from, state) do
    {:reply, exclusive_route_query(state, issue), state}
  end

  def handle_call({:claim, issue, owner}, _from, state) do
    grant_started_ms = System.monotonic_time(:millisecond)
    local_claim = Map.get(state.claims, issue.id)

    case claim_query(state, issue) do
      {:ok, claim} ->
        acquisition = if same_claim?(local_claim, claim), do: :existing, else: :new

        claim =
          claim
          |> Map.put(:owner, if(acquisition == :existing, do: local_claim.owner, else: owner))
          |> maybe_preserve_worker(local_claim, acquisition)
          |> Map.put(:acquisition, acquisition)
          |> refresh_lease_deadline(state.settings.lease_ms, grant_started_ms)

        {:reply, {:ok, claim}, %{state | claims: Map.put(state.claims, issue.id, claim)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:uncertain, reason} ->
        stop_reason = {:claim_transaction_uncertain, reason}
        notify_claim_lost(state.claims, stop_reason)
        {:stop, stop_reason, {:error, :claim_outcome_uncertain}, %{state | claims: %{}}}
    end
  end

  def handle_call({action, issue_id}, _from, state) when action in [:release, :complete] do
    case Map.fetch(state.claims, issue_id) do
      :error ->
        {:reply, :ok, state}

      {:ok, claim} ->
        function = if action == :complete, do: "complete_claim", else: "release_claim"

        case terminal_query(state, function, claim) do
          :ok -> {:reply, :ok, %{state | claims: Map.delete(state.claims, issue_id)}}
          {:error, reason} -> {:reply, {:error, reason}, %{state | claims: Map.delete(state.claims, issue_id)}}
        end
    end
  end

  def handle_call(
        {:release_if_owned, issue_id, %{claim_id: claim_id, generation: generation}},
        {caller, _tag},
        state
      ) do
    case Map.fetch(state.claims, issue_id) do
      {:ok, %{claim_id: ^claim_id, generation: ^generation, owner: ^caller, worker: worker} = claim}
      when worker in [nil, caller] ->
        case terminal_query(state, "release_claim", claim) do
          :ok ->
            {:reply, :ok, %{state | claims: Map.delete(state.claims, issue_id)}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, _claim} ->
        {:reply, {:error, :claim_ownership_changed}, state}

      :error ->
        {:reply, {:error, :claim_not_owned}, state}
    end
  end

  def handle_call({:active?, issue_id}, _from, state) do
    active =
      case Map.fetch(state.claims, issue_id) do
        {:ok, claim} -> active_query(state, claim)
        :error -> false
      end

    {:reply, active, state}
  end

  def handle_call(:effect_ledger_ready?, _from, state) do
    sql = "select symphony_staging.effect_ledger_ready()"
    ready = match?({:ok, %Postgrex.Result{rows: [[true]]}}, Postgrex.query(state.connection, sql, []))
    {:reply, ready, state}
  end

  def handle_call({:effect_context, issue_id}, {caller, _tag}, state) do
    case Map.fetch(state.claims, issue_id) do
      {:ok, %{worker: ^caller} = claim} ->
        context = %{
          issue_id: issue_id,
          claim_id: claim.claim_id,
          generation: claim.generation,
          node_id: state.settings.node_id,
          node_instance_id: state.settings.node_instance_id
        }

        {:reply, {:ok, state.connection, context}, state}

      {:ok, _claim} ->
        {:reply, {:error, :effect_context_not_owned_by_worker}, state}

      :error ->
        {:reply, {:error, :claim_not_owned}, state}
    end
  end

  def handle_call({:bind_worker, issue_id, worker}, _from, state) do
    case Map.fetch(state.claims, issue_id) do
      {:ok, claim} ->
        claims = Map.put(state.claims, issue_id, Map.put(claim, :worker, worker))
        {:reply, :ok, %{state | claims: claims}}

      :error ->
        {:reply, {:error, :claim_not_owned}, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    if enabled?() do
      renew_claims(state)
    else
      notify_claim_lost(state.claims, :claim_service_disabled)
      {:stop, :normal, %{state | claims: %{}}}
    end
  end

  def handle_info({:EXIT, connection, reason}, %{connection: connection} = state) do
    notify_claim_lost(state.claims, {:connection_lost, reason})
    {:stop, {:connection_lost, reason}, %{state | claims: %{}}}
  end

  def handle_info({:EXIT, _pid, reason}, state) when reason in [:normal, :shutdown] do
    notify_claim_lost(state.claims, {:coordinator_stopping, reason})
    {:stop, reason, %{state | claims: %{}}}
  end

  def handle_info({:EXIT, _pid, {:shutdown, _detail} = reason}, state) do
    notify_claim_lost(state.claims, {:coordinator_stopping, reason})
    {:stop, reason, %{state | claims: %{}}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp renew_claims(state) do
    claims =
      Enum.reduce(state.claims, state.claims, fn {issue_id, claim}, acc ->
        grant_started_ms = System.monotonic_time(:millisecond)

        case renewal_safe?(claim) && renew_query(state, claim) do
          :ok ->
            Map.put(
              acc,
              issue_id,
              refresh_lease_deadline(claim, state.settings.lease_ms, grant_started_ms)
            )

          false ->
            notify_claim_lost(issue_id, claim, :renewal_deadline_uncertain)
            Map.delete(acc, issue_id)

          {:error, reason} ->
            notify_claim_lost(issue_id, claim, reason)
            Map.delete(acc, issue_id)
        end
      end)

    {:noreply, schedule_heartbeat(%{state | claims: claims})}
  end

  defp exclusive_route_query(state, issue) do
    sql = """
    select routing_policy, target_node_id::text, routing_revision
    from symphony_staging.routing_assignments
    where issue_id = $1::text::uuid
    """

    state.connection
    |> routing_query(sql, [issue.id])
    |> exclusive_route_result(state.settings.node_id)
  end

  defp routing_query(connection, sql, params) when is_function(connection, 2),
    do: connection.(sql, params)

  defp routing_query(connection, sql, params), do: Postgrex.query(connection, sql, params)

  defp exclusive_route_result(
         {:ok, %Postgrex.Result{rows: [["exclusive", node_id, routing_revision]], num_rows: 1}},
         node_id
       )
       when is_integer(routing_revision) and routing_revision > 0,
       do: {:ok, %{routing_revision: routing_revision}}

  defp exclusive_route_result(
         {:ok, %Postgrex.Result{rows: [["exclusive", _node_id, routing_revision]], num_rows: 1}},
         _current_node_id
       )
       when is_integer(routing_revision) and routing_revision > 0,
       do: {:ineligible, :wrong_node}

  defp exclusive_route_result(
         {:ok, %Postgrex.Result{rows: [[policy, _node_id, _routing_revision]], num_rows: 1}},
         _current_node_id
       )
       when policy in ["unassigned", "preferred-with-fallback"],
       do: {:ineligible, :non_exclusive_routing}

  defp exclusive_route_result({:ok, %Postgrex.Result{rows: [], num_rows: 0}}, _current_node_id),
    do: {:ineligible, :missing_routing}

  defp exclusive_route_result(_result, _current_node_id), do: {:error, :routing_lookup_failed}

  defp claim_query(state, issue) do
    case issue.routing_revision do
      revision when is_integer(revision) and revision > 0 ->
        exclusive_claim_query(state, issue, revision)

      _legacy_without_routing_receipt ->
        acquire_claim_query(state, issue)
    end
  end

  defp exclusive_claim_query(state, issue, expected_revision) do
    run_transaction(state, fn transaction_connection ->
      with :ok <- lock_expected_exclusive_route(state, transaction_connection, issue, expected_revision),
           {:ok, claim} <- acquire_claim_query(state, transaction_connection, issue) do
        {:commit, claim}
      else
        {:error, reason} -> {:rollback, reason}
      end
    end)
  end

  defp lock_expected_exclusive_route(state, connection, issue, expected_revision) do
    sql = """
    select routing_policy, target_node_id::text, routing_revision
    from symphony_staging.routing_assignments
    where issue_id = $1::text::uuid
      and routing_policy = 'exclusive'
      and target_node_id = $2::text::uuid
      and routing_revision = $3
    for share
    """

    case query(connection, sql, [issue.id, state.settings.node_id, expected_revision]) do
      {:ok, %Postgrex.Result{rows: [["exclusive", node_id, ^expected_revision]], num_rows: 1}}
      when node_id == state.settings.node_id ->
        :ok

      {:ok, %Postgrex.Result{}} ->
        {:error, :routing_changed}

      {:error, _reason} ->
        {:error, :routing_revalidation_failed}
    end
  end

  defp acquire_claim_query(state, issue), do: acquire_claim_query(state, state.connection, issue)

  defp acquire_claim_query(state, connection, issue) do
    params = [
      issue.id,
      state.settings.node_id,
      state.settings.node_instance_id,
      issue_updated_at(issue),
      normalize_state(issue.state),
      configured_active_states(),
      state.settings.lease_ms,
      state.settings.fallback_grace_ms
    ]

    sql = """
    select claim_id::text, generation
    from symphony_staging.claim_issue($1, $2::text::uuid, $3::text::uuid, $4, $5, $6::text[], $7, $8)
    """

    case query(connection, sql, params) do
      {:ok, %Postgrex.Result{rows: [[claim_id, generation]]}} ->
        {:ok, %{issue_id: issue.id, claim_id: claim_id, generation: generation}}

      {:ok, result} ->
        {:error, {:unexpected_claim_result, result.num_rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(connection, sql, params) when is_function(connection, 2),
    do: connection.(sql, params)

  defp query(connection, sql, params), do: Postgrex.query(connection, sql, params)

  defp run_transaction(%{transaction_fun: transaction_fun, connection: connection}, callback)
       when is_function(transaction_fun, 2),
       do: transaction_fun.(connection, callback)

  defp run_transaction(%{connection: connection}, callback) do
    case Postgrex.transaction(
           connection,
           fn transaction_connection ->
             case callback.(transaction_connection) do
               {:commit, value} -> value
               {:rollback, reason} -> Postgrex.rollback(transaction_connection, {:expected, reason})
             end
           end,
           timeout: @call_timeout_ms
         ) do
      {:ok, value} -> {:ok, value}
      {:error, {:expected, reason}} -> {:error, reason}
      {:error, _reason} -> {:uncertain, :transaction_failed}
    end
  rescue
    _exception -> {:uncertain, :transaction_failed}
  catch
    :exit, _reason -> {:uncertain, :transaction_failed}
  end

  defp renew_query(state, claim) do
    sql = "select symphony_staging.renew_claim($1::text::uuid, $2, $3::text::uuid, $4::text::uuid, $5)"

    params = [
      claim.claim_id,
      claim.generation,
      state.settings.node_id,
      state.settings.node_instance_id,
      state.settings.lease_ms
    ]

    query_ok(state.connection, sql, params)
  end

  defp terminal_query(state, function, claim) do
    sql = "select symphony_staging.#{function}($1::text::uuid, $2, $3::text::uuid, $4::text::uuid)"
    params = [claim.claim_id, claim.generation, state.settings.node_id, state.settings.node_instance_id]
    query_ok(state.connection, sql, params)
  end

  defp active_query(state, claim) do
    sql =
      "select symphony_staging.validate_active_claim($1::text::uuid, $2, $3::text::uuid, $4::text::uuid)"

    params = [claim.claim_id, claim.generation, state.settings.node_id, state.settings.node_instance_id]

    match?({:ok, %Postgrex.Result{rows: [[true]]}}, Postgrex.query(state.connection, sql, params))
  end

  defp query_ok(connection, sql, params) do
    case Postgrex.query(connection, sql, params) do
      {:ok, %Postgrex.Result{rows: [[true]]}} -> :ok
      {:ok, _result} -> {:error, :claim_rejected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_heartbeat(state) do
    if is_reference(state.timer_ref), do: Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: Process.send_after(self(), :heartbeat, heartbeat_delay(state))}
  end

  defp heartbeat_delay(%{claims: claims, settings: settings}) when map_size(claims) > 0 do
    earliest_deadline_ms = claims |> Map.values() |> Enum.map(& &1.lease_deadline_ms) |> Enum.min()
    safe_remaining_ms = earliest_deadline_ms - System.monotonic_time(:millisecond) - @call_timeout_ms
    min(settings.heartbeat_ms, max(safe_remaining_ms, 0))
  end

  defp heartbeat_delay(%{settings: settings}), do: settings.heartbeat_ms

  defp issue_updated_at(%Issue{updated_at: %DateTime{} = updated_at}), do: updated_at
  defp issue_updated_at(_issue), do: nil

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp configured_active_states do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_state/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp safe_call(request) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :claim_service_unavailable}

      _pid ->
        try do
          GenServer.call(__MODULE__, request, @call_timeout_ms)
        catch
          :exit, reason -> {:error, {:claim_service_unavailable, reason}}
        end
    end
  end

  defp coordinator_running?, do: Process.whereis(__MODULE__) != nil

  defp renewal_safe?(%{lease_deadline_ms: deadline_ms}) do
    deadline_ms - System.monotonic_time(:millisecond) > @call_timeout_ms
  end

  defp renewal_safe?(_claim), do: false

  defp refresh_lease_deadline(claim, lease_ms, grant_started_ms) do
    Map.put(claim, :lease_deadline_ms, lease_deadline_for_test(grant_started_ms, lease_ms))
  end

  defp same_claim?(%{claim_id: claim_id, generation: generation}, %{claim_id: claim_id, generation: generation}),
    do: true

  defp same_claim?(_local_claim, _remote_claim), do: false

  defp maybe_preserve_worker(claim, %{worker: worker}, :existing), do: Map.put(claim, :worker, worker)
  defp maybe_preserve_worker(claim, _local_claim, _acquisition), do: claim

  defp notify_claim_lost(claims, reason) do
    Enum.each(claims, fn {issue_id, claim} ->
      notify_claim_lost(issue_id, claim, reason)
    end)
  end

  defp notify_claim_lost(issue_id, claim, reason) do
    case Map.get(claim, :worker) do
      worker when is_pid(worker) -> Process.exit(worker, :kill)
      _other -> :ok
    end

    send(claim.owner, {:claim_lost, issue_id, reason})
  end
end
