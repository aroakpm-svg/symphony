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

  defstruct [:connection, :settings, :timer_ref, claims: %{}]

  @type claim :: %{
          issue_id: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
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
  def enabled?, do: Process.whereis(__MODULE__) != nil

  @spec claim(Issue.t(), pid()) :: {:ok, claim() | nil} | {:error, term()}
  def claim(%Issue{} = issue, owner \\ self()) when is_pid(owner) do
    if enabled?(), do: GenServer.call(__MODULE__, {:claim, issue, owner}, 15_000), else: {:ok, nil}
  end

  @spec release(String.t()) :: :ok | {:error, term()}
  def release(issue_id) when is_binary(issue_id) do
    if enabled?(), do: GenServer.call(__MODULE__, {:release, issue_id}, 15_000), else: :ok
  end

  @spec complete(String.t()) :: :ok | {:error, term()}
  def complete(issue_id) when is_binary(issue_id) do
    if enabled?(), do: GenServer.call(__MODULE__, {:complete, issue_id}, 15_000), else: :ok
  end

  @spec active?(String.t()) :: boolean()
  def active?(issue_id) when is_binary(issue_id) do
    if enabled?(), do: GenServer.call(__MODULE__, {:active?, issue_id}, 15_000), else: true
  end

  @impl true
  def init(settings) do
    with {:ok, connection} <- Postgrex.start_link(url: settings.database_url) do
      {:ok, schedule_heartbeat(%__MODULE__{connection: connection, settings: settings})}
    end
  end

  @impl true
  def handle_call({:claim, issue, owner}, _from, state) do
    case claim_query(state, issue) do
      {:ok, claim} ->
        claim = Map.put(claim, :owner, owner)
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
          {:error, reason} -> {:reply, {:error, reason}, state}
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

  @impl true
  def handle_info(:heartbeat, state) do
    claims =
      Enum.reduce(state.claims, state.claims, fn {issue_id, claim}, acc ->
        case renew_query(state, claim) do
          :ok ->
            acc

          {:error, reason} ->
            send(claim.owner, {:claim_lost, issue_id, reason})
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
      state.settings.lease_ms,
      state.settings.fallback_grace_ms
    ]

    sql = """
    select claim_id::text, generation
    from symphony_staging.claim_issue($1, $2::uuid, $3::uuid, $4::timestamptz, $5, $6, $7)
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
    params = [claim.claim_id, claim.generation, state.settings.node_id, state.settings.node_instance_id, state.settings.lease_ms]
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
    %{state | timer_ref: Process.send_after(self(), :heartbeat, state.settings.heartbeat_ms)}
  end

  defp issue_updated_at(%Issue{updated_at: %DateTime{} = updated_at}), do: DateTime.to_iso8601(updated_at)
  defp issue_updated_at(_issue), do: nil

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
