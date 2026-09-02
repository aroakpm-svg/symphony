defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.CoreSupervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.ClaimService,
      {SymphonyElixir.Orchestrator, orchestrator_opts()}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp orchestrator_opts do
    Application.get_env(:symphony_elixir, :orchestrator_opts, [])
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    with {:ok, runtime_health_opts} <- runtime_health_opts() do
      children = [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        SymphonyElixir.WorkflowStore,
        {SymphonyElixir.RuntimeHealth, runtime_health_opts},
        SymphonyElixir.CoreSupervisor,
        SymphonyElixir.HttpServer,
        SymphonyElixir.StatusDashboard
      ]

      Supervisor.start_link(
        children,
        strategy: :one_for_one,
        name: SymphonyElixir.Supervisor
      )
    end
  end

  @impl true
  def prep_stop(state) do
    record_runtime_stop()
    state
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp runtime_health_opts do
    base_opts = Application.get_env(:symphony_elixir, :runtime_health_opts, [])
    expected_root = SymphonyElixir.Config.settings!().observability.runtime_state_root

    watchdog_runtime_health_opts_for_test(System.get_env(), base_opts, expected_root)
  end

  @watchdog_runtime_keys ~w(
    SYMPHONY_RUNTIME_EPOCH
    SYMPHONY_RUNTIME_RECEIPT_PATH
    SYMPHONY_RUNTIME_STATE_ROOT
    SYMPHONY_RESTART_ATTEMPT
  )

  @doc false
  @spec watchdog_runtime_health_opts_for_test(map(), keyword(), Path.t()) ::
          {:ok, keyword()}
          | {:error,
             :incomplete_watchdog_runtime_contract
             | :invalid_watchdog_runtime_contract
             | :watchdog_runtime_state_root_mismatch}
  def watchdog_runtime_health_opts_for_test(environment, base_opts, expected_root)
      when is_map(environment) and is_list(base_opts) and is_binary(expected_root) do
    values = Map.take(environment, @watchdog_runtime_keys)

    case map_size(values) do
      0 ->
        {:ok, Keyword.put_new(base_opts, :runtime_state_root, Path.expand(expected_root))}

      4 ->
        validate_watchdog_runtime_contract(values, base_opts, expected_root)

      _partial ->
        {:error, :incomplete_watchdog_runtime_contract}
    end
  end

  def watchdog_runtime_health_opts_for_test(_environment, _base_opts, _expected_root),
    do: {:error, :invalid_watchdog_runtime_contract}

  defp validate_watchdog_runtime_contract(values, base_opts, expected_root) do
    epoch = values["SYMPHONY_RUNTIME_EPOCH"]
    receipt_path = values["SYMPHONY_RUNTIME_RECEIPT_PATH"]
    runtime_state_root = values["SYMPHONY_RUNTIME_STATE_ROOT"]
    restart_attempt = parse_positive_integer(values["SYMPHONY_RESTART_ATTEMPT"])

    cond do
      not valid_watchdog_epoch?(epoch) ->
        {:error, :invalid_watchdog_runtime_contract}

      not absolute_path?(receipt_path) or not absolute_path?(runtime_state_root) ->
        {:error, :invalid_watchdog_runtime_contract}

      normalized_path(runtime_state_root) != normalized_path(expected_root) ->
        {:error, :watchdog_runtime_state_root_mismatch}

      normalized_path(receipt_path) !=
          normalized_path(Path.join(runtime_state_root, "stop-#{epoch}.json")) ->
        {:error, :invalid_watchdog_runtime_contract}

      not is_integer(restart_attempt) ->
        {:error, :invalid_watchdog_runtime_contract}

      true ->
        {:ok,
         Keyword.merge(base_opts,
           runtime_epoch: epoch,
           runtime_state_root: Path.expand(runtime_state_root),
           receipt_path: Path.expand(receipt_path),
           restart_attempt: restart_attempt
         )}
    end
  end

  defp valid_watchdog_epoch?(epoch) when is_binary(epoch) do
    byte_size(epoch) in 1..128 and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, epoch)
  end

  defp valid_watchdog_epoch?(_epoch), do: false

  defp absolute_path?(path) when is_binary(path), do: Path.type(path) == :absolute
  defp absolute_path?(_path), do: false

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {attempt, ""} ->
        if SymphonyElixir.RuntimeReceiptContract.valid_restart_attempt?(attempt),
          do: attempt,
          else: nil

      _invalid ->
        nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp normalized_path(path) do
    normalized = path |> Path.expand() |> String.replace("\\", "/")
    if match?({:win32, _}, :os.type()), do: String.downcase(normalized), else: normalized
  end

  defp record_runtime_stop do
    server = Application.get_env(:symphony_elixir, :runtime_health_server, SymphonyElixir.RuntimeHealth)
    SymphonyElixir.RuntimeHealth.stop(server, %{category: :normal_shutdown})
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
