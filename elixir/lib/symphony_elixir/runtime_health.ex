defmodule SymphonyElixir.RuntimeHealth do
  @moduledoc """
  Owns bounded, secret-safe runtime health evidence and the final stop receipt.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.RuntimeReceiptContract

  @stages [
    :candidate_fetch,
    :issue_refresh,
    :routing,
    :profile_resolution,
    :preflight,
    :claim,
    :dispatch
  ]
  @dependencies [:linear, :claim_store]
  @stage_statuses [:started, :succeeded, :failed, :skipped, :retrying]
  @dependency_statuses [:unknown, :connected, :failed]
  @stop_categories [:normal_shutdown, :startup_failure, :unexpected_exit, :restart_limit]
  @failure_categories [
    :callback_exception,
    :callback_failure,
    :candidate_fetch_failed,
    :claim_rejected,
    :claim_service_unavailable,
    :claim_timeout,
    :default_branch_mismatch,
    :default_branch_unresolvable,
    :dispatch_exception,
    :dispatch_failure,
    :inactive_state,
    :linear_forbidden,
    :linear_identity_missing,
    :linear_response_invalid,
    :linear_unauthorized,
    :linear_workspace_mismatch,
    :linear_unavailable,
    :missing,
    :missing_routing,
    :missing_worker_label,
    :non_exclusive_routing,
    :poll_error,
    :poll_timeout,
    :preflight_unavailable,
    :project_changed,
    :project_mapping_missing,
    :refresh_unavailable,
    :repository_metadata_invalid,
    :repository_mismatch,
    :repository_unavailable,
    :required_check_contract_invalid,
    :required_check_contract_missing,
    :required_check_contract_unreadable,
    :routing_unavailable,
    :stale_issue,
    :unknown_project,
    :wrong_node
  ]
  @context_schema %{
    profile_key: :profile_key,
    issue_id: :issue_id,
    issue_identifier: :issue_identifier,
    repository: :repository,
    canonical_branch: :canonical_branch,
    workspace_namespace: :workspace_namespace,
    environment: :environment,
    routing_revision: :routing_revision
  }
  @stage_schema Map.merge(@context_schema, %{
                  status: :stage_status,
                  failure_category: :failure_category,
                  detail: :detail
                })
  @dependency_schema %{status: :dependency_status, failure_category: :failure_category}
  @stop_schema Map.merge(@context_schema, %{
                 category: :stop_category,
                 failure_category: :failure_category,
                 detail: :detail
               })
  @default_history_limit 100
  @default_receipt_limit 10
  defstruct [
    :clock,
    :history_limit,
    :receipt_limit,
    :receipt_root_path,
    :canonical_receipt_root,
    :runtime_state_path,
    :receipt_path,
    :canonical_runtime_state_dir,
    :canonical_workspace_root,
    :path_resolver,
    :runtime_epoch,
    :restart_attempt,
    :receipt_writer,
    :before_receipt_publish,
    :last_successful_poll_at,
    :final_stop,
    stages: %{},
    dependencies: %{
      linear: %{status: :unknown, failure_category: nil},
      claim_store: %{status: :unknown, failure_category: nil}
    },
    history: []
  ]

  @type server :: GenServer.server()
  @type stage ::
          :candidate_fetch
          | :issue_refresh
          | :routing
          | :profile_resolution
          | :preflight
          | :claim
          | :dispatch
  @type dependency :: :linear | :claim_store
  @type error_reason ::
          :unknown_stage
          | :unknown_dependency
          | :invalid_status
          | :invalid_field_value
          | :invalid_clock
          | :secret_bearing_value
          | {:unknown_field, atom()}
          | {:invalid_field, atom()}
          | {:unsafe_runtime_state_root, atom()}
          | :invalid_runtime_epoch
          | :invalid_restart_attempt
          | :receipt_write_failed

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    path_resolver = Keyword.get(opts, :path_resolver, &PathSafety.canonicalize/1)

    with {:ok, paths} <- runtime_paths(opts, path_resolver),
         {:ok, runtime_epoch} <- runtime_epoch(opts),
         {:ok, restart_attempt} <- restart_attempt(opts),
         {:ok, receipt_path} <- validate_receipt_contract_path(paths, runtime_epoch, opts) do
      name = Keyword.get(opts, :name, __MODULE__)

      opts =
        opts
        |> Keyword.put(:validated_runtime_paths, paths)
        |> Keyword.put(:validated_runtime_epoch, runtime_epoch)
        |> Keyword.put(:validated_restart_attempt, restart_attempt)
        |> Keyword.put(:validated_receipt_path, receipt_path)
        |> Keyword.put(:path_resolver, path_resolver)

      GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
    end
  end

  @spec stage(server(), stage() | atom(), map()) :: :ok | {:error, error_reason()}
  def stage(server, stage, fields) do
    GenServer.call(server, {:stage, stage, fields})
  end

  @spec dependency(server(), dependency() | atom(), map()) :: :ok | {:error, error_reason()}
  def dependency(server, dependency, fields) do
    GenServer.call(server, {:dependency, dependency, fields})
  end

  @spec poll_succeeded(server()) :: :ok | {:error, :invalid_clock}
  def poll_succeeded(server) do
    GenServer.call(server, :poll_succeeded)
  end

  @spec stop(server(), map()) :: :ok | {:error, error_reason()}
  def stop(server, fields) do
    GenServer.call(server, {:stop, fields})
  end

  @spec snapshot(server()) :: map()
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    paths = Keyword.fetch!(opts, :validated_runtime_paths)
    path_resolver = Keyword.fetch!(opts, :path_resolver)
    runtime_epoch = Keyword.fetch!(opts, :validated_runtime_epoch)
    restart_attempt = Keyword.fetch!(opts, :validated_restart_attempt)
    receipt_path = Keyword.fetch!(opts, :validated_receipt_path)

    with :ok <- File.mkdir_p(paths.runtime_state_path),
         {:ok, current_runtime_state_dir} <- resolve_path(path_resolver, paths.runtime_state_path),
         :ok <-
           validate_runtime_state_target(
             current_runtime_state_dir,
             paths.canonical_receipt_root,
             paths.canonical_workspace_root
           ),
         :ok <- ensure_same_path(current_runtime_state_dir, paths.canonical_runtime_state_dir),
         {:ok, receipt_writer} <-
           start_receipt_writer(
             current_runtime_state_dir,
             runtime_epoch,
             paths,
             path_resolver,
             opts
           ) do
      {:ok,
       %__MODULE__{
         clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
         history_limit:
           positive_limit(
             Keyword.get(opts, :history_limit, @default_history_limit),
             @default_history_limit
           ),
         receipt_limit:
           positive_limit(
             Keyword.get(opts, :receipt_limit, @default_receipt_limit),
             @default_receipt_limit
           ),
         receipt_root_path: paths.receipt_root_path,
         canonical_receipt_root: paths.canonical_receipt_root,
         runtime_state_path: paths.runtime_state_path,
         receipt_path: receipt_path,
         canonical_runtime_state_dir: paths.canonical_runtime_state_dir,
         canonical_workspace_root: paths.canonical_workspace_root,
         path_resolver: path_resolver,
         runtime_epoch: runtime_epoch,
         restart_attempt: restart_attempt,
         receipt_writer: receipt_writer,
         before_receipt_publish: Keyword.get(opts, :before_receipt_publish, fn _path -> :ok end),
         last_successful_poll_at: nil,
         final_stop: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{receipt_writer: receipt_writer}) do
    close_receipt_writer(receipt_writer)
  end

  @impl true
  def handle_call({:stage, stage, fields}, _from, state) do
    with :ok <- validate_member(stage, @stages, :unknown_stage),
         {:ok, fields} <- validate_fields(fields, @stage_schema, [:status]) do
      event = fields |> Map.put(:type, :stage) |> Map.put(:stage, stage)
      key = {stage, fields[:profile_key], fields[:issue_id]}

      case Map.get(state.stages, key) do
        existing when is_map(existing) ->
          if Map.delete(existing, :at) == event do
            {:reply, :ok, state}
          else
            record_stage_reply(state, key, event)
          end

        _missing ->
          record_stage_reply(state, key, event)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:dependency, dependency, fields}, _from, state) do
    with :ok <- validate_member(dependency, @dependencies, :unknown_dependency),
         {:ok, fields} <- validate_fields(fields, @dependency_schema, [:status]) do
      evidence = %{status: fields.status, failure_category: Map.get(fields, :failure_category)}

      if Map.get(state.dependencies, dependency) == evidence do
        {:reply, :ok, state}
      else
        event = Map.merge(evidence, %{type: :dependency, dependency: dependency})

        case timestamp(state) do
          {:ok, at} ->
            state = %{
              state
              | dependencies: Map.put(state.dependencies, dependency, evidence)
            }

            {:reply, :ok, append_history_at(state, event, at)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:poll_succeeded, _from, state) do
    case timestamp(state) do
      {:ok, at} ->
        state = %{state | last_successful_poll_at: at}

        {:reply, :ok, append_history_at(state, %{type: :poll_succeeded, status: :succeeded}, at)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, fields}, _from, state) do
    with {:ok, fields} <- validate_fields(fields, @stop_schema, [:category]) do
      if is_nil(state.final_stop) do
        case timestamp(state) do
          {:ok, at} ->
            final_stop = Map.put(fields, :at, at)

            case write_stop_receipt(state, final_stop) do
              {:ok, final_stop, receipt_writer} ->
                event = Map.merge(final_stop, %{type: :stop, status: :stopped})
                state = %{state | final_stop: final_stop, receipt_writer: receipt_writer}
                {:reply, :ok, append_history_at(state, event, at)}

              {:error, reason, receipt_writer} ->
                {:reply, {:error, reason}, %{state | receipt_writer: receipt_writer}}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      else
        {:reply, :ok, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    stages =
      state.stages
      |> Map.values()
      |> Enum.sort_by(&{&1.stage, Map.get(&1, :profile_key, ""), Map.get(&1, :issue_id, "")})

    {:reply,
     %{
       last_successful_poll_at: state.last_successful_poll_at || :unknown,
       dependencies: state.dependencies,
       stages: stages,
       final_stop: state.final_stop || :unknown,
       runtime_epoch: state.runtime_epoch,
       runtime_state_root: state.canonical_runtime_state_dir,
       receipt_path: state.receipt_path,
       restart_attempt: state.restart_attempt,
       history: state.history
     }, state}
  end

  defp runtime_paths(opts, path_resolver) when is_function(path_resolver, 1) do
    {receipt_root_path, runtime_state_path} =
      case Keyword.get(opts, :runtime_state_root) do
        runtime_state_root when is_binary(runtime_state_root) ->
          expanded_runtime_state_root = Path.expand(runtime_state_root)
          {Path.dirname(expanded_runtime_state_root), expanded_runtime_state_root}

        _other ->
          receipt_root = Keyword.get(opts, :receipt_root, default_receipt_root())
          {receipt_root, if(is_binary(receipt_root), do: Path.join(receipt_root, "runtime-state"))}
      end

    with true <- is_binary(receipt_root_path),
         true <- is_binary(runtime_state_path),
         receipt_root_path = Path.expand(receipt_root_path),
         runtime_state_path = Path.expand(runtime_state_path),
         {:ok, canonical_receipt_root} <- resolve_path(path_resolver, receipt_root_path),
         {:ok, canonical_runtime_state_dir} <- resolve_path(path_resolver, runtime_state_path),
         {:ok, canonical_workspace_root} <- workspace_root(opts, path_resolver),
         :ok <- validate_receipt_root(canonical_receipt_root),
         :ok <-
           validate_runtime_state_target(
             canonical_runtime_state_dir,
             canonical_receipt_root,
             canonical_workspace_root
           ) do
      {:ok,
       %{
         receipt_root_path: receipt_root_path,
         canonical_receipt_root: canonical_receipt_root,
         runtime_state_path: runtime_state_path,
         canonical_runtime_state_dir: canonical_runtime_state_dir,
         canonical_workspace_root: canonical_workspace_root
       }}
    else
      {:error, {:unsafe_runtime_state_root, _reason}} = error -> error
      _error -> {:error, {:unsafe_runtime_state_root, :invalid_path}}
    end
  end

  defp runtime_paths(_opts, _path_resolver),
    do: {:error, {:unsafe_runtime_state_root, :invalid_path_resolver}}

  defp default_receipt_root do
    :filename.basedir(:user_data, "symphony_elixir")
    |> to_string()
    |> Path.join("health")
  end

  defp runtime_epoch(opts) do
    epoch =
      Keyword.get_lazy(opts, :runtime_epoch, fn ->
        "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
      end)

    cond do
      not is_binary(epoch) ->
        {:error, :invalid_runtime_epoch}

      secret_bearing?(epoch) ->
        {:error, :invalid_runtime_epoch}

      not RuntimeReceiptContract.valid_string_size?(:runtime_epoch, epoch) ->
        {:error, :invalid_runtime_epoch}

      not Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, epoch) ->
        {:error, :invalid_runtime_epoch}

      true ->
        {:ok, epoch}
    end
  end

  defp validate_receipt_contract_path(paths, runtime_epoch, opts) do
    expected_receipt_path =
      Path.join(paths.canonical_runtime_state_dir, "stop-#{runtime_epoch}.json")

    receipt_path =
      opts
      |> Keyword.get(:receipt_path, expected_receipt_path)
      |> then(fn path -> if is_binary(path), do: Path.expand(path), else: path end)

    cond do
      not is_binary(receipt_path) ->
        {:error, {:unsafe_runtime_state_root, :receipt_path_mismatch}}

      normalized_path(receipt_path) != normalized_path(expected_receipt_path) ->
        {:error, {:unsafe_runtime_state_root, :receipt_path_mismatch}}

      String.valid?(receipt_path) and
          RuntimeReceiptContract.valid_string_size?(:receipt_path, receipt_path) ->
        {:ok, expected_receipt_path}

      true ->
        {:error, {:unsafe_runtime_state_root, :receipt_path_too_long}}
    end
  end

  defp restart_attempt(opts) do
    case Keyword.get(opts, :restart_attempt) do
      nil ->
        {:ok, nil}

      attempt when is_integer(attempt) ->
        if RuntimeReceiptContract.valid_restart_attempt?(attempt),
          do: {:ok, attempt},
          else: {:error, :invalid_restart_attempt}

      _invalid ->
        {:error, :invalid_restart_attempt}
    end
  end

  defp workspace_root(opts, path_resolver) do
    case Keyword.get(opts, :workspace_root) do
      root when is_binary(root) -> resolve_path(path_resolver, root)
      _other -> canonical_workspace_root(configured_workspace_root(), path_resolver)
    end
  end

  defp canonical_workspace_root(nil, _path_resolver), do: {:ok, nil}
  defp canonical_workspace_root(root, path_resolver), do: resolve_path(path_resolver, root)

  defp configured_workspace_root do
    case SymphonyElixir.Config.settings() do
      {:ok, %{workspace: %{root: root}}} when is_binary(root) -> Path.expand(root)
      _other -> nil
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp filesystem_root?(path) do
    case Path.split(path) do
      [_root] -> true
      _parts -> false
    end
  end

  defp validate_receipt_root(path) do
    if filesystem_root?(path),
      do: {:error, {:unsafe_runtime_state_root, :filesystem_root}},
      else: :ok
  end

  defp validate_runtime_state_target(runtime_state_dir, receipt_root, workspace_root) do
    cond do
      filesystem_root?(runtime_state_dir) ->
        {:error, {:unsafe_runtime_state_root, :filesystem_root}}

      not strictly_inside?(runtime_state_dir, receipt_root) ->
        {:error, {:unsafe_runtime_state_root, :outside_receipt_root}}

      workspace_root && inside?(runtime_state_dir, workspace_root) ->
        {:error, {:unsafe_runtime_state_root, :workspace_target}}

      true ->
        :ok
    end
  end

  defp resolve_path(path_resolver, path) do
    case path_resolver.(Path.expand(path)) do
      {:ok, resolved} when is_binary(resolved) ->
        resolved = Path.expand(resolved)
        if Path.type(resolved) == :absolute, do: {:ok, resolved}, else: {:error, :relative_path}

      _error ->
        {:error, :path_resolution_failed}
    end
  rescue
    _exception -> {:error, :path_resolution_failed}
  catch
    _kind, _reason -> {:error, :path_resolution_failed}
  end

  defp inside?(path, parent) do
    path = normalized_path(path)
    parent = parent |> normalized_path() |> String.trim_trailing("/")
    path == parent or String.starts_with?(path, parent <> "/")
  end

  defp strictly_inside?(path, parent), do: inside?(path, parent) and not same_path?(path, parent)

  defp same_path?(left, right), do: normalized_path(left) == normalized_path(right)

  defp ensure_same_path(left, right) do
    case {normalized_path(left), normalized_path(right)} do
      {path, path} -> :ok
      {_left, _right} -> {:error, {:unsafe_runtime_state_root, :path_changed}}
    end
  end

  defp normalized_path(path) do
    path = path |> Path.expand() |> String.replace("\\", "/")
    if match?({:win32, _}, :os.type()), do: String.downcase(path), else: path
  end

  defp validate_fields(fields, schema, required_keys) when is_map(fields) do
    case Enum.find(Map.keys(fields), &(!Map.has_key?(schema, &1))) do
      nil ->
        case Enum.find(required_keys, &(!Map.has_key?(fields, &1))) do
          nil ->
            Enum.reduce_while(fields, {:ok, %{}}, fn {key, value}, {:ok, validated} ->
              case validate_field(key, value, Map.fetch!(schema, key)) do
                {:ok, safe_value} -> {:cont, {:ok, Map.put(validated, key, safe_value)}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)

          key ->
            {:error, {:invalid_field, key}}
        end

      key ->
        {:error, {:unknown_field, key}}
    end
  end

  defp validate_fields(_fields, _schema, _required_keys), do: {:error, :invalid_field_value}

  defp validate_field(key, value, type) when is_binary(value) do
    if secret_bearing?(value) do
      {:error, :secret_bearing_value}
    else
      validate_string_field(key, value, type)
    end
  end

  defp validate_field(_key, value, :stage_status) when value in @stage_statuses, do: {:ok, value}

  defp validate_field(_key, value, :dependency_status) when value in @dependency_statuses,
    do: {:ok, value}

  defp validate_field(_key, value, :stop_category) when value in @stop_categories, do: {:ok, value}

  defp validate_field(_key, value, :failure_category) when value in @failure_categories,
    do: {:ok, value}

  defp validate_field(_key, nil, :failure_category), do: {:ok, nil}

  defp validate_field(_key, value, :routing_revision) do
    if RuntimeReceiptContract.valid_routing_revision?(value),
      do: {:ok, value},
      else: {:error, {:invalid_field, :routing_revision}}
  end

  defp validate_field(key, _value, _type), do: {:error, {:invalid_field, key}}

  defp validate_string_field(key, value, :profile_key),
    do:
      validate_string(
        key,
        value,
        ~r/^[a-z0-9]+(?:[-_][a-z0-9]+)*$/,
        RuntimeReceiptContract.max_string_bytes(:profile_key)
      )

  defp validate_string_field(key, value, :issue_id),
    do:
      validate_string(
        key,
        value,
        ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/,
        RuntimeReceiptContract.max_string_bytes(:issue_id)
      )

  defp validate_string_field(key, value, :issue_identifier),
    do:
      validate_string(
        key,
        value,
        ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/,
        RuntimeReceiptContract.max_string_bytes(:issue_identifier)
      )

  defp validate_string_field(key, value, :repository),
    do:
      validate_string(
        key,
        value,
        ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/,
        RuntimeReceiptContract.max_string_bytes(:repository)
      )

  defp validate_string_field(key, value, :canonical_branch) do
    valid? =
      RuntimeReceiptContract.valid_string_size?(:canonical_branch, value) and
        String.valid?(value) and
        not Regex.match?(~r/[\x00-\x20\x7F\\]/, value) and
        not String.starts_with?(value, "/") and not String.ends_with?(value, "/") and
        not String.contains?(value, ["..", "@{"]) and not String.ends_with?(value, ".lock")

    if valid?, do: {:ok, value}, else: {:error, {:invalid_field, key}}
  end

  defp validate_string_field(key, value, :workspace_namespace),
    do:
      validate_string(
        key,
        value,
        ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
        RuntimeReceiptContract.max_string_bytes(:workspace_namespace)
      )

  defp validate_string_field(_key, "local_non_production" = value, :environment), do: {:ok, value}

  defp validate_string_field(key, value, :detail) do
    valid? = String.valid?(value) and not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, value)

    if valid?,
      do: {:ok, RuntimeReceiptContract.truncate_detail(value)},
      else: {:error, {:invalid_field, key}}
  end

  defp validate_string_field(key, _value, _type), do: {:error, {:invalid_field, key}}

  defp validate_string(key, value, pattern, max_bytes) do
    if String.valid?(value) and byte_size(value) in 1..max_bytes and Regex.match?(pattern, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, key}}
  end

  defp secret_bearing?(value), do: SymphonyElixir.SecretSafety.contains_secret?(value)

  defp validate_member(value, allowed, error) do
    if value in allowed, do: :ok, else: {:error, error}
  end

  defp timestamp(state) do
    case RuntimeReceiptContract.canonical_utc_timestamp(state.clock.()) do
      {:ok, timestamp} -> {:ok, timestamp}
      {:error, :invalid_timestamp} -> {:error, :invalid_clock}
    end
  rescue
    _exception -> {:error, :invalid_clock}
  catch
    _kind, _reason -> {:error, :invalid_clock}
  end

  defp record_stage_reply(state, key, event) do
    case timestamp(state) do
      {:ok, at} ->
        event = Map.put(event, :at, at)
        state = %{state | stages: Map.put(state.stages, key, event)}
        {:reply, :ok, append_history_at(state, event, at)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp append_history_at(state, event, at) do
    event = Map.put(event, :at, at)

    history =
      case List.last(state.history) do
        ^event -> state.history
        _other -> Enum.take(state.history ++ [event], -state.history_limit)
      end

    %{state | history: history}
  end

  defp write_stop_receipt(state, final_stop) do
    with {:ok, current_receipt_root} <- resolve_path(state.path_resolver, state.receipt_root_path),
         :ok <- ensure_same_path(current_receipt_root, state.canonical_receipt_root),
         {:ok, current_runtime_state_dir} <- resolve_path(state.path_resolver, state.runtime_state_path),
         :ok <-
           validate_runtime_state_target(
             current_runtime_state_dir,
             current_receipt_root,
             state.canonical_workspace_root
           ),
         :ok <- ensure_same_path(current_runtime_state_dir, state.canonical_runtime_state_dir) do
      receipt_path = state.receipt_path

      final_stop =
        final_stop
        |> Map.put(:runtime_epoch, state.runtime_epoch)
        |> Map.put(:receipt_path, receipt_path)
        |> maybe_put_restart_attempt(state.restart_attempt)

      case publish_immutable_receipt(state, current_runtime_state_dir, receipt_path, final_stop) do
        {:ok, receipt_writer} ->
          {:ok, final_stop, receipt_writer}

        {:error, reason, receipt_writer} ->
          Logger.error("Runtime receipt publication failed reason=#{inspect(reason)}")
          {:error, :receipt_write_failed, receipt_writer}
      end
    else
      {:error, {:unsafe_runtime_state_root, _reason}} = error ->
        {:error, elem(error, 1), state.receipt_writer}

      {:error, _reason} ->
        {:error, {:unsafe_runtime_state_root, :path_resolution_failed}, state.receipt_writer}
    end
  end

  defp maybe_put_restart_attempt(final_stop, nil), do: final_stop

  defp maybe_put_restart_attempt(final_stop, restart_attempt) do
    Map.put(final_stop, :restart_attempt, restart_attempt)
  end

  defp publish_immutable_receipt(state, runtime_state_dir, receipt_path, final_stop) do
    temp_name = ".stop-#{System.unique_integer([:positive, :monotonic])}.tmp"

    with {:ok, encoded} <- Jason.encode(final_stop),
         true <- RuntimeReceiptContract.valid_encoded_size?(encoded),
         :ok <- run_before_receipt_publish(state.before_receipt_publish, runtime_state_dir),
         {:ok, :ok, receipt_writer} <-
           receipt_writer_command(
             state.receipt_writer,
             {
               :publish,
               temp_name,
               Path.basename(receipt_path),
               encoded,
               state.receipt_limit
             },
             state.receipt_writer.command_timeout_ms
           ) do
      {:ok, receipt_writer}
    else
      {:ok, {:error, reason}, receipt_writer} ->
        {:error, reason, receipt_writer}

      {:ok, _invalid_reply, receipt_writer} ->
        {:error, :invalid_writer_response, retire_receipt_writer(receipt_writer, :force)}

      {:error, reason, receipt_writer} ->
        {:error, reason, receipt_writer}

      {:error, reason} ->
        {:error, reason, state.receipt_writer}

      false ->
        {:error, :receipt_too_large, state.receipt_writer}
    end
  end

  defp start_receipt_writer(runtime_state_dir, runtime_epoch, paths, path_resolver, opts) do
    guard_name = ".runtime-health-#{runtime_epoch}.lock"

    token =
      {:runtime_health_guard, node(), self(), make_ref()}
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    before_open =
      Keyword.get(opts, :before_receipt_writer_open, fn validated_directory ->
        {:ok, validated_directory}
      end)

    port_opener = Keyword.get(opts, :receipt_writer_port_opener, &open_receipt_writer/3)
    command_timeout_ms = positive_timeout(Keyword.get(opts, :receipt_writer_command_timeout_ms, 5_000))
    retirement_timeout_ms = positive_timeout(Keyword.get(opts, :receipt_writer_retirement_timeout_ms, 1_000))
    publish_delay_ms = nonnegative_delay(Keyword.get(opts, :receipt_writer_publish_delay_ms, 0))

    with {:ok, executable} <- receipt_writer_executable(opts),
         {:ok, ebin_path} <- receipt_writer_ebin_path(),
         {:ok, acquisition_dir} <- run_before_receipt_writer_open(before_open, runtime_state_dir),
         {:ok, port} <- run_receipt_writer_port_opener(port_opener, executable, ebin_path, acquisition_dir) do
      writer = %{
        port: port,
        usable: true,
        attested: false,
        guard_name: guard_name,
        guard_path: Path.join(acquisition_dir, guard_name),
        guard_token: token,
        command_timeout_ms: command_timeout_ms,
        retirement_timeout_ms: retirement_timeout_ms
      }

      case initialize_receipt_writer(writer, publish_delay_ms) do
        {:ok, attestation, initialized_writer} ->
          case attest_receipt_writer(
                 initialized_writer,
                 attestation,
                 paths,
                 path_resolver,
                 runtime_state_dir
               ) do
            :ok ->
              {:ok,
               %{
                 initialized_writer
                 | attested: true,
                   guard_path: Path.join(runtime_state_dir, guard_name)
               }}

            {:error, _reason} ->
              _retired_writer = retire_receipt_writer(initialized_writer, :graceful)
              {:error, {:receipt_writer_unavailable, :capability_attestation_failed}}
          end

        {:error, reason, failed_writer} ->
          _retired_writer = retire_receipt_writer(failed_writer, :force)
          {:error, {:receipt_writer_unavailable, reason}}
      end
    else
      {:error, reason} -> {:error, {:receipt_writer_unavailable, reason}}
    end
  end

  defp initialize_receipt_writer(writer, publish_delay_ms) do
    command =
      {:init, writer.guard_name, writer.guard_token, writer.guard_path, publish_delay_ms}

    case receipt_writer_command(writer, command, 5_000) do
      {:ok, {:ok, attestation}, writer} when is_map(attestation) ->
        {:ok, attestation, writer}

      {:ok, {:error, reason}, writer} ->
        {:error, reason, writer}

      {:ok, _other, writer} ->
        {:error, :invalid_writer_response, retire_receipt_writer(writer, :force)}

      {:error, reason, writer} ->
        {:error, reason, writer}
    end
  end

  defp attest_receipt_writer(writer, attestation, paths, path_resolver, startup_runtime_state_dir) do
    expected_guard_path = Path.join(startup_runtime_state_dir, writer.guard_name)

    with {:ok, current_receipt_root} <- resolve_path(path_resolver, paths.receipt_root_path),
         true <- same_path?(current_receipt_root, paths.canonical_receipt_root),
         {:ok, current_runtime_state_dir} <- resolve_path(path_resolver, paths.runtime_state_path),
         :ok <-
           validate_runtime_state_target(
             current_runtime_state_dir,
             current_receipt_root,
             paths.canonical_workspace_root
           ),
         true <- same_path?(current_runtime_state_dir, startup_runtime_state_dir),
         {:ok, pinned_cwd} <- attestation_path(attestation),
         true <- same_path?(pinned_cwd, current_runtime_state_dir),
         {:ok, directory_identity} <- file_identity(current_runtime_state_dir),
         true <- Map.get(attestation, :directory_identity) == directory_identity,
         {:ok, guard_identity} <- file_identity(expected_guard_path),
         true <- Map.get(attestation, :guard_identity) == guard_identity,
         true <- Map.get(attestation, :guard_token) == writer.guard_token,
         {:ok, guard_token} <- File.read(expected_guard_path),
         true <- guard_token == writer.guard_token do
      :ok
    else
      _mismatch -> {:error, :capability_attestation_failed}
    end
  end

  defp attestation_path(%{cwd: cwd}) when is_binary(cwd), do: PathSafety.canonicalize(cwd)
  defp attestation_path(_attestation), do: {:error, :invalid_attestation}

  defp file_identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        {:ok,
         %{
           size: stat.size,
           type: stat.type,
           mode: stat.mode,
           links: stat.links,
           major_device: stat.major_device,
           minor_device: stat.minor_device,
           inode: stat.inode
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receipt_writer_executable(opts) do
    executable_name = if match?({:win32, _}, :os.type()), do: "erl.exe", else: "erl"
    otp_root = Keyword.get(opts, :otp_root, to_string(:code.root_dir())) |> Path.expand()
    erts_version = Keyword.get(opts, :erts_version, to_string(:erlang.system_info(:version)))
    resolver = Keyword.get(opts, :receipt_writer_executable_path_resolver, &PathSafety.canonicalize/1)

    candidates = [
      Path.join([otp_root, "bin", executable_name]),
      Path.join([otp_root, "erts-#{erts_version}", "bin", executable_name])
    ]

    with {:ok, canonical_root} <- resolve_path(resolver, otp_root) do
      Enum.find_value(candidates, {:error, :erl_not_found}, fn candidate ->
        with true <- File.regular?(candidate),
             {:ok, canonical_candidate} <- resolve_path(resolver, candidate),
             true <- strictly_inside?(canonical_candidate, canonical_root) do
          {:ok, candidate}
        else
          _invalid -> false
        end
      end)
    else
      _error -> {:error, :erl_not_found}
    end
  end

  defp receipt_writer_ebin_path do
    case :code.which(:symphony_runtime_receipt_writer) do
      path when is_list(path) -> validate_writer_beam_path(path)
      :cover_compiled -> bundled_writer_ebin_path()
      _missing -> {:error, :writer_module_not_found}
    end
  end

  defp bundled_writer_ebin_path do
    case :code.lib_dir(:symphony_elixir) do
      path when is_list(path) ->
        path
        |> to_string()
        |> Path.join("ebin")
        |> Path.join("symphony_runtime_receipt_writer.beam")
        |> validate_writer_beam_path()

      _missing ->
        {:error, :writer_module_not_found}
    end
  end

  defp validate_writer_beam_path(path) do
    path = path |> to_string() |> Path.expand()

    case {Path.basename(path), File.stat(path)} do
      {"symphony_runtime_receipt_writer.beam", {:ok, %File.Stat{type: :regular}}} ->
        {:ok, Path.dirname(path)}

      _invalid ->
        {:error, :writer_module_not_found}
    end
  end

  defp open_receipt_writer(executable, ebin_path, runtime_state_dir) do
    args = ["-noshell", "-pa", ebin_path, "-s", "symphony_runtime_receipt_writer", "start"]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:cd, String.to_charlist(runtime_state_dir)},
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:line, 65_536}
        ]
      )

    {:ok, port}
  rescue
    _exception -> {:error, :port_open_failed}
  catch
    _kind, _reason -> {:error, :port_open_failed}
  end

  defp run_before_receipt_writer_open(callback, runtime_state_dir) when is_function(callback, 1) do
    case callback.(runtime_state_dir) do
      {:ok, acquisition_dir} when is_binary(acquisition_dir) ->
        acquisition_dir = Path.expand(acquisition_dir)

        if Path.type(acquisition_dir) == :absolute,
          do: {:ok, acquisition_dir},
          else: {:error, :acquisition_boundary_failed}

      _other ->
        {:error, :acquisition_boundary_failed}
    end
  rescue
    _exception -> {:error, :acquisition_boundary_failed}
  catch
    _kind, _reason -> {:error, :acquisition_boundary_failed}
  end

  defp run_before_receipt_writer_open(_callback, _runtime_state_dir),
    do: {:error, :acquisition_boundary_failed}

  defp run_receipt_writer_port_opener(opener, executable, ebin_path, acquisition_dir)
       when is_function(opener, 3) do
    case opener.(executable, ebin_path, acquisition_dir) do
      {:ok, port} when is_port(port) -> {:ok, port}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :port_open_failed}
    end
  rescue
    _exception -> {:error, :port_open_failed}
  catch
    _kind, _reason -> {:error, :port_open_failed}
  end

  defp run_receipt_writer_port_opener(_opener, _executable, _ebin_path, _acquisition_dir),
    do: {:error, :port_open_failed}

  defp receipt_writer_command(%{usable: false} = writer, _command, _timeout_ms),
    do: {:error, :writer_retired, writer}

  defp receipt_writer_command(%{port: port} = writer, command, timeout_ms) when is_port(port) do
    request_id = receipt_writer_request_id()
    envelope = {:request, request_id, command}
    payload = envelope |> :erlang.term_to_binary() |> Base.encode64()

    Port.command(port, [payload, "\n"])

    receive do
      {^port, {:data, {:eol, encoded_reply}}} ->
        case decode_receipt_writer_reply(encoded_reply, request_id) do
          {:ok, reply} -> {:ok, reply, writer}
          {:error, reason} -> {:error, reason, retire_receipt_writer(writer, :force)}
        end

      {^port, {:data, {:noeol, _partial_reply}}} ->
        {:error, :response_too_large, retire_receipt_writer(writer, :force)}

      {^port, {:exit_status, status}} ->
        {:error, {:writer_exit, status}, retire_receipt_writer(writer, :force)}
    after
      timeout_ms -> {:error, :writer_timeout, retire_receipt_writer(writer, :force)}
    end
  rescue
    _exception -> {:error, :writer_closed, retire_receipt_writer(writer, :force)}
  catch
    _kind, _reason -> {:error, :writer_closed, retire_receipt_writer(writer, :force)}
  end

  defp receipt_writer_request_id do
    {node(), self(), make_ref(), System.unique_integer([:positive, :monotonic])}
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp decode_receipt_writer_reply(encoded_reply, request_id) do
    with {:ok, encoded_reply} <- Base.decode64(String.trim(encoded_reply)),
         reply <- :erlang.binary_to_term(encoded_reply, [:safe]) do
      case reply do
        {:reply, ^request_id, response} -> {:ok, response}
        {:reply, _other_request_id, _response} -> {:error, :writer_protocol_mismatch}
        _other -> {:error, :invalid_writer_response}
      end
    else
      _error -> {:error, :invalid_writer_response}
    end
  rescue
    _exception -> {:error, :invalid_writer_response}
  end

  defp run_before_receipt_publish(callback, runtime_state_dir) when is_function(callback, 1) do
    callback.(runtime_state_dir)
    :ok
  rescue
    _exception -> {:error, :publication_boundary_failed}
  catch
    _kind, _reason -> {:error, :publication_boundary_failed}
  end

  defp run_before_receipt_publish(_callback, _runtime_state_dir),
    do: {:error, :publication_boundary_failed}

  defp close_receipt_writer(%{usable: true} = writer) do
    _retired_writer = retire_receipt_writer(writer, :graceful)
    :ok
  end

  defp close_receipt_writer(_writer), do: :ok

  defp retire_receipt_writer(%{usable: false} = writer, _mode), do: writer

  defp retire_receipt_writer(writer, :graceful) do
    writer = %{writer | usable: false}
    request_id = receipt_writer_request_id()
    payload = {:request, request_id, :close} |> :erlang.term_to_binary() |> Base.encode64()

    _graceful? =
      try do
        Port.command(writer.port, [payload, "\n"])

        receive do
          {port, {:data, {:eol, encoded_reply}}} when port == writer.port ->
            decode_receipt_writer_reply(encoded_reply, request_id) == {:ok, :ok}

          {port, {:exit_status, _status}} when port == writer.port ->
            false
        after
          writer.retirement_timeout_ms -> false
        end
      rescue
        _exception -> false
      catch
        _kind, _reason -> false
      end

    _closed = close_and_await_writer(writer)
    cleanup_guard(writer)
    writer
  end

  defp retire_receipt_writer(writer, :force) do
    writer = %{writer | usable: false}
    _closed = close_and_await_writer(writer)
    cleanup_guard(writer)
    writer
  end

  defp close_and_await_writer(%{port: port, retirement_timeout_ms: timeout_ms}) do
    monitor = :erlang.monitor(:port, port)

    try do
      if Port.info(port), do: Port.close(port)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end

    receive do
      {:DOWN, ^monitor, :port, ^port, _reason} -> :ok
    after
      timeout_ms ->
        :erlang.demonitor(monitor, [:flush])
        :timeout
    end
  rescue
    _exception -> :closed
  catch
    _kind, _reason -> :closed
  end

  defp cleanup_guard(%{guard_path: guard_path, guard_token: guard_token}) do
    case File.read(guard_path) do
      {:ok, ^guard_token} -> File.rm(guard_path)
      _other -> :ok
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp positive_timeout(value) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value), do: 5_000

  defp nonnegative_delay(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_delay(_value), do: 0

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default
end
