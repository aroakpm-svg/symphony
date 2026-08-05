defmodule SymphonyElixir.ClaimService do
  @moduledoc """
  Owns the PostgreSQL connection used for cross-machine issue claims.

  When enabled, every dispatch must first obtain a database claim. Owned leases are
  renewed in the background; uncertain renewals are reported to the orchestrator so
  the affected worker stops before performing more work.
  """

  use GenServer

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @call_timeout_ms 15_000

  defstruct [:connection, :settings, :timer_ref, claims: %{}]

  @type claim :: %{
          issue_id: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          lease_deadline_ms: integer(),
          owner: pid()
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

  @doc false
  @spec call_for_test(term()) :: term()
  def call_for_test(request), do: safe_call(request)

  @impl true
  def init(settings) do
    Process.flag(:trap_exit, true)

    with {:ok, connection} <- Postgrex.start_link(url: settings.database_url) do
      {:ok, schedule_heartbeat(%__MODULE__{connection: connection, settings: settings})}
    end
  end

  @impl true
  def handle_call({:claim, issue, owner}, _from, state) do
    case claim_query(state, issue) do
      {:ok, claim} ->
        claim =
          claim
          |> Map.put(:owner, owner)
          |> refresh_lease_deadline(state.settings.lease_ms)

        {:reply, {:ok, claim}, %{state | claims: Map.put(state.claims, issue.id, claim)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

  def handle_call({:active?, issue_id}, _from, state) do
    active =
      case Map.fetch(state.claims, issue_id) do
        {:ok, claim} -> active_query(state, claim)
        :error -> false
      end

    {:reply, active, state}
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

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp renew_claims(state) do
    claims =
      Enum.reduce(state.claims, state.claims, fn {issue_id, claim}, acc ->
        case renewal_safe?(claim) && renew_query(state, claim) do
          :ok ->
            Map.put(acc, issue_id, refresh_lease_deadline(claim, state.settings.lease_ms))

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

  defp claim_query(state, issue) do
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
    from symphony_staging.claim_issue($1, $2::uuid, $3::uuid, $4::timestamptz, $5, $6::text[], $7, $8)
    """

    case Postgrex.query(state.connection, sql, params) do
      {:ok, %Postgrex.Result{rows: [[claim_id, generation]]}} ->
        {:ok, %{issue_id: issue.id, claim_id: claim_id, generation: generation}}

      {:ok, result} ->
        {:error, {:unexpected_claim_result, result.num_rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp renew_query(state, claim) do
    sql = "select symphony_staging.renew_claim($1::uuid, $2, $3::uuid, $4::uuid, $5)"

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
    sql = "select symphony_staging.#{function}($1::uuid, $2, $3::uuid, $4::uuid)"
    params = [claim.claim_id, claim.generation, state.settings.node_id, state.settings.node_instance_id]
    query_ok(state.connection, sql, params)
  end

  defp active_query(state, claim) do
    sql = "select symphony_staging.validate_active_claim($1::uuid, $2, $3::uuid, $4::uuid)"
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

  defp issue_updated_at(%Issue{updated_at: %DateTime{} = updated_at}), do: DateTime.to_iso8601(updated_at)
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

  defp refresh_lease_deadline(claim, lease_ms) do
    Map.put(claim, :lease_deadline_ms, System.monotonic_time(:millisecond) + lease_ms)
  end

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
