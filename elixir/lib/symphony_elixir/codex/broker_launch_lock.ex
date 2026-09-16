defmodule SymphonyElixir.Codex.BrokerLaunchLock do
  @moduledoc false

  use GenServer

  @ack_poll_ms 50

  @type token :: %{required(:command) => String.t(), required(:cleanup_ack) => Path.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec acquire(String.t()) :: {:ok, token()}
  def acquire(command) when is_binary(command) do
    GenServer.call(__MODULE__, {:acquire, command}, :infinity)
  end

  @spec mark_wrapper_starting(token() | nil) :: :ok
  def mark_wrapper_starting(nil), do: :ok

  def mark_wrapper_starting(%{command: command, cleanup_ack: cleanup_ack})
      when is_binary(command) and is_binary(cleanup_ack) do
    GenServer.call(__MODULE__, {:mark_wrapper_starting, command, cleanup_ack}, :infinity)
  end

  @spec release(token()) :: :ok
  def release(%{command: command}) when is_binary(command) do
    GenServer.call(__MODULE__, {:release, command}, :infinity)
  end

  @impl true
  def init(_opts), do: {:ok, %{locks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, command}, from, state) do
    case Map.fetch(state.locks, command) do
      :error ->
        {token, active, state} = new_active(command, from, state)
        {:reply, {:ok, token}, put_in(state, [:locks, command], active)}

      {:ok, active} ->
        {pid, _tag} = from
        monitor = Process.monitor(pid)
        active = update_in(active.queue, &:queue.in({from, monitor}, &1))

        state =
          state
          |> put_in([:locks, command], active)
          |> put_in([:monitors, monitor], {:waiter, command})

        {:noreply, state}
    end
  end

  def handle_call({:mark_wrapper_starting, command, cleanup_ack}, _from, state) do
    state =
      case Map.fetch(state.locks, command) do
        {:ok, %{cleanup_ack: ^cleanup_ack} = active} ->
          put_in(state, [:locks, command], %{active | wrapper_starting?: true})

        _missing_or_replaced ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:release, command}, _from, state) do
    case Map.fetch(state.locks, command) do
      :error ->
        {:reply, :ok, state}

      {:ok, active} ->
        state = demonitor_holder(state, active)
        cleanup_ack(active.cleanup_ack)
        {:reply, :ok, grant_next_or_delete(command, active.queue, state)}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {role, state} = pop_in(state, [:monitors, monitor])
    {:noreply, handle_down(role, monitor, state)}
  end

  def handle_info({:check_ack, command, cleanup_ack}, state) do
    {:noreply, handle_ack_check(state, command, cleanup_ack)}
  end

  defp handle_down({:holder, command}, _monitor, state) do
    case Map.fetch(state.locks, command) do
      {:ok, %{wrapper_starting?: true} = active} ->
        schedule_ack_check(command, active.cleanup_ack)
        put_in(state, [:locks, command, :holder_monitor], nil)

      {:ok, active} ->
        cleanup_ack(active.cleanup_ack)
        grant_next_or_delete(command, active.queue, state)

      :error ->
        state
    end
  end

  defp handle_down({:waiter, command}, monitor, state) do
    case Map.fetch(state.locks, command) do
      {:ok, active} ->
        put_in(state, [:locks, command, :queue], remove_waiter(active.queue, monitor))

      :error ->
        state
    end
  end

  defp handle_down(_unknown, _monitor, state), do: state

  defp handle_ack_check(state, command, cleanup_ack) do
    case Map.fetch(state.locks, command) do
      {:ok, %{cleanup_ack: ^cleanup_ack, holder_monitor: nil} = active} ->
        if File.exists?(cleanup_ack) do
          cleanup_ack(cleanup_ack)
          grant_next_or_delete(command, active.queue, state)
        else
          schedule_ack_check(command, cleanup_ack)
          state
        end

      _missing_or_replaced ->
        state
    end
  end

  defp grant_next_or_delete(command, queue, state) do
    case :queue.out(queue) do
      {{:value, {waiter = {pid, _tag}, monitor}}, rest} ->
        state = pop_monitor(state, monitor)
        Process.demonitor(monitor, [:flush])

        if Process.alive?(pid) do
          {token, active, state} = new_active(command, waiter, state, rest)
          GenServer.reply(waiter, {:ok, token})
          put_in(state, [:locks, command], active)
        else
          grant_next_or_delete(command, rest, state)
        end

      {:empty, _queue} ->
        update_in(state.locks, &Map.delete(&1, command))
    end
  end

  defp new_active(command, holder, state, queue \\ :queue.new()) do
    {pid, _tag} = holder
    token = new_token(command)
    monitor = Process.monitor(pid)

    active = %{
      queue: queue,
      holder_monitor: monitor,
      cleanup_ack: token.cleanup_ack,
      wrapper_starting?: false
    }

    {token, active, put_in(state, [:monitors, monitor], {:holder, command})}
  end

  defp demonitor_holder(state, %{holder_monitor: nil}), do: state

  defp demonitor_holder(state, %{holder_monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    pop_monitor(state, monitor)
  end

  defp pop_monitor(state, monitor), do: update_in(state.monitors, &Map.delete(&1, monitor))

  defp remove_waiter(queue, monitor) do
    :queue.filter(
      fn
        {_from, waiter_monitor} -> waiter_monitor != monitor
      end,
      queue
    )
  end

  defp schedule_ack_check(command, cleanup_ack) do
    Process.send_after(self(), {:check_ack, command, cleanup_ack}, @ack_poll_ms)
  end

  defp cleanup_ack(path) when is_binary(path), do: File.rm(path)

  defp new_token(command) do
    %{command: command, cleanup_ack: cleanup_ack_path()}
  end

  defp cleanup_ack_path do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "symphony-broker-cleanup-#{suffix}.ack")
  end
end
