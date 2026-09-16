defmodule SymphonyElixir.Codex.BrokerLaunchLockTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.BrokerLaunchLock

  test "start_link reports the existing durable lock process" do
    assert {:error, {:already_started, pid}} = BrokerLaunchLock.start_link([])
    assert is_pid(pid)
    assert {:error, {:already_started, default_pid}} = BrokerLaunchLock.start_link()
    assert is_pid(default_pid)
  end

  test "lock ownership survives the short-lived caller process after wrapper startup handoff" do
    command = unique_command()
    owner = self()

    holder =
      Task.async(fn ->
        {:ok, token} = BrokerLaunchLock.acquire(command)
        :ok = BrokerLaunchLock.mark_wrapper_starting(token)
        send(owner, {:held, token})
      end)

    token =
      receive do
        {:held, token} -> token
      after
        1_000 -> flunk("broker lock was not acquired")
      end

    Task.await(holder)

    waiter = Task.async(fn -> BrokerLaunchLock.acquire(command) end)

    refute Task.yield(waiter, 100)

    assert :ok = BrokerLaunchLock.release(token)
    assert {:ok, next_token} = Task.await(waiter)
    assert next_token.command == command
    assert next_token.cleanup_ack != token.cleanup_ack
    assert :ok = BrokerLaunchLock.release(next_token)
  end

  test "release tolerates absent commands" do
    command = unique_command()

    assert :ok =
             BrokerLaunchLock.release(%{
               command: command,
               cleanup_ack: Path.join(System.tmp_dir!(), "missing.ack")
             })
  end

  test "cancelled waiters are removed while the durable lock remains held" do
    command = unique_command()
    assert {:ok, token} = BrokerLaunchLock.acquire(command)

    waiter = Task.async(fn -> BrokerLaunchLock.acquire(command) end)
    wait_until(fn -> queued_waiters(command) == 1 end)
    Task.shutdown(waiter, :brutal_kill)
    wait_until(fn -> queued_waiters(command) == 0 end)

    assert :ok = BrokerLaunchLock.release(token)
  end

  test "release skips dead queued waiters" do
    command = unique_command()
    assert {:ok, token} = BrokerLaunchLock.acquire(command)

    dead_pid = spawn(fn -> :ok end)
    death_monitor = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^death_monitor, :process, ^dead_pid, _reason}, 1_000
    refute Process.alive?(dead_pid)
    monitor = Process.monitor(dead_pid)

    :sys.replace_state(BrokerLaunchLock, fn state ->
      update_in(state, [:locks, command, :queue], &:queue.in({{dead_pid, make_ref()}, monitor}, &1))
    end)

    assert :ok = BrokerLaunchLock.release(token)
  end

  test "pre-wrapper holder death releases the next waiter without cleanup acknowledgement" do
    command = unique_command()
    owner = self()

    holder =
      Task.async(fn ->
        {:ok, token} = BrokerLaunchLock.acquire(command)
        send(owner, {:held_before_wrapper, token})
      end)

    token =
      receive do
        {:held_before_wrapper, token} -> token
      after
        1_000 -> flunk("broker lock was not acquired")
      end

    Task.await(holder)
    wait_until(fn -> not lock_active?(command) end)

    waiter = Task.async(fn -> BrokerLaunchLock.acquire(command) end)
    assert {:ok, next_token} = Task.await(waiter, 1_000)
    assert next_token.command == command
    assert next_token.cleanup_ack != token.cleanup_ack
    assert :ok = BrokerLaunchLock.release(next_token)
  end

  test "post-wrapper holder death releases the next waiter only after cleanup acknowledgement" do
    command = unique_command()
    owner = self()

    holder =
      Task.async(fn ->
        {:ok, token} = BrokerLaunchLock.acquire(command)
        :ok = BrokerLaunchLock.mark_wrapper_starting(token)
        send(owner, {:held_for_ack, token})
      end)

    token =
      receive do
        {:held_for_ack, token} -> token
      after
        1_000 -> flunk("broker lock was not acquired")
      end

    Task.await(holder)

    waiter = Task.async(fn -> BrokerLaunchLock.acquire(command) end)
    refute Task.yield(waiter, 100)

    File.write!(token.cleanup_ack, "done")

    assert {:ok, next_token} = Task.await(waiter, 1_000)
    assert next_token.command == command
    assert :ok = BrokerLaunchLock.release(next_token)
  end

  test "defensive messages for stale monitors and stale handoff tokens are harmless" do
    missing_command = unique_command()

    assert :ok = BrokerLaunchLock.mark_wrapper_starting(nil)
    assert :ok = BrokerLaunchLock.mark_wrapper_starting(%{command: missing_command, cleanup_ack: "missing"})
    refute lock_active?(missing_command)

    command = unique_command()
    assert {:ok, token} = BrokerLaunchLock.acquire(command)
    assert :ok = BrokerLaunchLock.mark_wrapper_starting(%{token | cleanup_ack: token.cleanup_ack <> ".stale"})
    assert :ok = BrokerLaunchLock.release(token)

    holder_monitor = make_ref()
    waiter_monitor = make_ref()
    absent_holder_command = unique_command()
    absent_waiter_command = unique_command()

    :sys.replace_state(BrokerLaunchLock, fn state ->
      state
      |> put_in([:monitors, holder_monitor], {:holder, absent_holder_command})
      |> put_in([:monitors, waiter_monitor], {:waiter, absent_waiter_command})
    end)

    send(BrokerLaunchLock, {:DOWN, holder_monitor, :process, self(), :normal})
    send(BrokerLaunchLock, {:DOWN, waiter_monitor, :process, self(), :normal})
    send(BrokerLaunchLock, {:DOWN, make_ref(), :process, self(), :normal})

    wait_until(fn -> not Map.has_key?(:sys.get_state(BrokerLaunchLock).monitors, holder_monitor) end)
    refute lock_active?(absent_holder_command)
    refute lock_active?(absent_waiter_command)
  end

  test "cleanup acknowledgement paths are not reused" do
    command = unique_command()

    assert {:ok, first} = BrokerLaunchLock.acquire(command)
    assert :ok = BrokerLaunchLock.release(first)
    assert {:ok, second} = BrokerLaunchLock.acquire(command)
    assert :ok = BrokerLaunchLock.release(second)

    assert first.cleanup_ack != second.cleanup_ack
    assert Path.basename(first.cleanup_ack) =~ ~r/^symphony-broker-cleanup-[A-Za-z0-9_-]+\.ack$/
  end

  defp unique_command do
    "codex-command-#{System.unique_integer([:positive, :monotonic])}.ps1"
  end

  defp lock_active?(command) do
    BrokerLaunchLock
    |> :sys.get_state()
    |> Map.fetch!(:locks)
    |> Map.has_key?(command)
  end

  defp queued_waiters(command) do
    BrokerLaunchLock
    |> :sys.get_state()
    |> Map.fetch!(:locks)
    |> Map.fetch!(command)
    |> Map.fetch!(:queue)
    |> :queue.len()
  end

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was not met")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
