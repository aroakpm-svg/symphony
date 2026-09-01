defmodule SymphonyElixir.PrivateHome.WindowsCapability do
  @moduledoc false

  @max_response_bytes 4_096
  @default_timeout_ms 10_000

  defstruct [:port, :state, timeout_ms: @default_timeout_ms]

  @opaque t :: %__MODULE__{
            port: port(),
            state: :atomics.atomics_ref(),
            timeout_ms: pos_integer()
          }

  @spec open([{Path.t(), String.t()}], [{Path.t(), String.t() | nil}]) ::
          {:ok, t()} | {:error, :private_home_capability_failed}
  def open(anchors, components), do: open(anchors, components, [])

  @spec open([{Path.t(), String.t()}], [{Path.t(), String.t() | nil}], keyword()) ::
          {:ok, t()} | {:error, :private_home_capability_failed}
  def open(anchors, components, opts)
      when is_list(anchors) and is_list(components) and is_list(opts) do
    with {:ok, executable} <- powershell_executable(),
         {:ok, script} <- helper_script(),
         {:ok, port} <- open_port(executable, script) do
      capability = new_capability(port, @default_timeout_ms)

      case request(capability, %{
             "op" => "init",
             "anchors" => encode_paths(anchors),
             "components" => encode_paths(components),
             "failCommit" => Keyword.get(opts, :fail_commit, false)
           }) do
        {:ok, %{"code" => "ready"}} ->
          {:ok, capability}

        _failure ->
          _retired = retire(capability)
          {:error, :private_home_capability_failed}
      end
    else
      _failure -> {:error, :private_home_capability_failed}
    end
  rescue
    _error -> {:error, :private_home_capability_failed}
  end

  @spec ensure_component(t(), Path.t(), boolean()) ::
          {:ok, String.t()} | {:error, :private_home_capability_failed}
  def ensure_component(%__MODULE__{} = capability, path, fail_permission?)
      when is_binary(path) and is_boolean(fail_permission?) do
    case request(capability, %{
           "op" => "ensure",
           "path" => Path.expand(path),
           "failPermission" => fail_permission?
         }) do
      {:ok, %{"code" => "ensured", "identity" => identity}}
      when is_binary(identity) and byte_size(identity) == 34 ->
        {:ok, String.downcase(identity)}

      _failure ->
        {:error, :private_home_capability_failed}
    end
  end

  @spec verify(t()) :: :ok | {:error, :private_home_capability_failed}
  def verify(%__MODULE__{} = capability) do
    case request(capability, %{"op" => "verify"}) do
      {:ok, %{"code" => "verified"}} ->
        :ok

      _failure ->
        _retired = retire(capability)
        {:error, :private_home_capability_failed}
    end
  end

  @spec commit(t()) :: :ok | {:error, :private_home_capability_failed}
  def commit(%__MODULE__{} = capability) do
    case request(capability, %{"op" => "commit"}) do
      {:ok, %{"code" => "committed"}} ->
        retire(capability)

      _failure ->
        _retired = retire(capability)
        {:error, :private_home_capability_failed}
    end
  end

  @spec rollback(t()) :: :ok | {:error, :private_home_capability_failed}
  def rollback(%__MODULE__{} = capability) do
    case request(capability, %{"op" => "rollback"}) do
      {:ok, %{"code" => "rolled_back"}} ->
        retire(capability)

      _failure ->
        _retired = retire(capability)
        {:error, :private_home_capability_failed}
    end
  end

  @spec retire(t()) :: :ok | {:error, :private_home_capability_failed}
  def retire(%__MODULE__{port: port, state: state}) do
    :atomics.put(state, 1, 1)
    close_port(port)
  end

  @doc false
  @spec from_port_for_test(port(), pos_integer()) :: t()
  def from_port_for_test(port, timeout_ms)
      when is_port(port) and is_integer(timeout_ms) and timeout_ms > 0 do
    new_capability(port, timeout_ms)
  end

  @doc false
  @spec active_for_test?(t()) :: boolean()
  def active_for_test?(%__MODULE__{port: port, state: state}) do
    :atomics.get(state, 1) == 0 and not is_nil(Port.info(port))
  end

  defp new_capability(port, timeout_ms) do
    state = :atomics.new(1, signed: false)
    %__MODULE__{port: port, state: state, timeout_ms: timeout_ms}
  end

  defp encode_paths(paths) do
    Enum.map(paths, fn {path, identity} ->
      %{"path" => Path.expand(path), "identity" => identity}
    end)
  end

  defp powershell_executable do
    with root when is_binary(root) and root != "" <-
           System.get_env("SystemRoot") || System.get_env("SYSTEMROOT"),
         true <- Path.type(root) == :absolute,
         executable =
           Path.join([root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"]),
         true <- File.regular?(executable) do
      {:ok, executable}
    else
      _failure -> {:error, :private_home_capability_failed}
    end
  end

  defp helper_script do
    case :code.priv_dir(:symphony_elixir) do
      directory when is_list(directory) ->
        script = directory |> List.to_string() |> Path.join("private_home_windows.ps1")
        if File.regular?(script), do: {:ok, script}, else: {:error, :private_home_capability_failed}

      _failure ->
        {:error, :private_home_capability_failed}
    end
  end

  defp open_port(executable, script) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :hide,
          :use_stdio,
          :stderr_to_stdout,
          args:
            Enum.map(
              ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script],
              &String.to_charlist/1
            ),
          line: @max_response_bytes
        ]
      )

    {:ok, port}
  rescue
    _error -> {:error, :private_home_capability_failed}
  end

  defp request(%__MODULE__{port: port, timeout_ms: timeout_ms} = capability, payload)
       when is_port(port) and is_map(payload) do
    if retired?(capability) do
      {:error, :private_home_capability_failed}
    else
      correlation_id = correlation_id()
      encoded = [payload |> Map.put("id", correlation_id) |> Jason.encode_to_iodata!(), "\n"]

      if Port.command(port, encoded) do
        case receive_response(port, correlation_id, timeout_ms) do
          {:ok, _response} = ok ->
            ok

          {:error, :operation_failed} = error ->
            error

          {:error, :protocol_failed} ->
            _retired = retire(capability)
            {:error, :private_home_capability_failed}
        end
      else
        _retired = retire(capability)
        {:error, :private_home_capability_failed}
      end
    end
  rescue
    _error ->
      _retired = retire(capability)
      {:error, :private_home_capability_failed}
  end

  defp retired?(%__MODULE__{state: state}), do: :atomics.get(state, 1) == 1

  defp correlation_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp receive_response(port, correlation_id, timeout_ms) do
    receive do
      {^port, {:data, {:eol, line}}} when byte_size(line) <= @max_response_bytes ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^correlation_id, "ok" => true} = response} ->
            {:ok, response}

          {:ok, %{"id" => ^correlation_id, "ok" => false}} ->
            {:error, :operation_failed}

          _malformed_or_mismatched ->
            {:error, :protocol_failed}
        end

      {^port, {:data, _oversized_or_partial}} ->
        {:error, :protocol_failed}

      {^port, {:exit_status, _status}} ->
        {:error, :protocol_failed}
    after
      timeout_ms -> {:error, :protocol_failed}
    end
  end

  defp close_port(port) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  rescue
    _error -> {:error, :private_home_capability_failed}
  catch
    _kind, _reason -> {:error, :private_home_capability_failed}
  end
end
