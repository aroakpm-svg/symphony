defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, CodexAuthHome, Config, PathSafety, SSH, Workspace}
  alias SymphonyElixir.SubprocessEnvironment

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @account_read_id 4
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          protocol_thread_id: (-> String.t()),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          managed_session: boolean(),
          managed_issue_id: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    redaction_values = redaction_values(opts)

    with {:ok, expanded_workspace} <-
           validate_workspace_cwd(
             workspace,
             worker_host,
             Keyword.get(opts, :execution_context),
             Keyword.get(opts, :workspace_attestation)
           ),
         {:ok, codex_home} <- CodexAuthHome.resolve(Keyword.get(opts, :execution_context)),
         {:ok, port_environment} <- port_environment(opts),
         {:ok, port} <- start_port(expanded_workspace, worker_host, port_environment, opts, codex_home) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           managed_session = Keyword.get(opts, :managed_session, false),
           {:ok, protocol_thread_id} <-
             do_start_session(
               port,
               expanded_workspace,
               session_policies,
               managed_session,
               redaction_values,
               codex_child_config(opts, codex_home)
             ) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: sanitize_string(protocol_thread_id, redaction_values),
           protocol_thread_id: fn -> protocol_thread_id end,
           workspace: expanded_workspace,
           worker_host: worker_host,
           managed_session: managed_session,
           managed_issue_id: Keyword.get(opts, :managed_issue_id)
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, sanitize_term(reason, redaction_values)}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          protocol_thread_id: protocol_thread_id,
          workspace: workspace
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    redaction_values = redaction_values(opts)

    on_message =
      opts
      |> Keyword.get(:on_message, &default_on_message/1)
      |> sanitized_message_handler(redaction_values)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments,
          managed_session: Map.get(session, :managed_session, false),
          managed_issue_id: Map.get(session, :managed_issue_id)
        )
      end)

    raw_thread_id = protocol_thread_id.()

    case start_turn(
           port,
           raw_thread_id,
           prompt,
           issue,
           workspace,
           approval_policy,
           turn_sandbox_policy,
           redaction_values
         ) do
      {:ok, raw_turn_id} ->
        thread_id = sanitize_string(raw_thread_id, redaction_values)
        turn_id = sanitize_string(raw_turn_id, redaction_values)
        session_id = sanitize_string("#{raw_thread_id}-#{raw_turn_id}", redaction_values)
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(
               port,
               on_message,
               tool_executor,
               auto_approve_requests,
               redaction_values
             ) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            reason = sanitize_term(reason, redaction_values)
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        reason = sanitize_term(reason, redaction_values)
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, worker_host, nil, nil) do
    validate_workspace_cwd(workspace, worker_host)
  end

  defp validate_workspace_cwd(
         workspace,
         worker_host,
         execution_context,
         workspace_attestation
       )
       when is_binary(workspace) do
    with :ok <-
           Workspace.validate_execution_workspace(
             workspace,
             worker_host,
             execution_context,
             workspace_attestation
           ),
         {:ok, validated_workspace} <- validate_workspace_cwd(workspace, worker_host) do
      {:ok, validated_workspace}
    else
      {:error, {:workspace_issue_identity_mismatch, actual, expected}} ->
        {:error, {:invalid_workspace_cwd, :execution_context_mismatch, actual, expected}}

      {:error, {:workspace_issue_identity_changed, actual, expected}} ->
        {:error, {:invalid_workspace_cwd, :workspace_identity_changed, actual, expected}}

      {:error, reason} ->
        {:error, {:invalid_workspace_cwd, :execution_context_invalid, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, port_environment, opts, codex_home) do
    {shell_name, shell_flag} = local_shell_contract(:os.type())
    executable = System.find_executable(shell_name)

    if is_nil(executable) do
      {:error, :shell_not_found}
    else
      port_opener = Keyword.get(opts, :port_opener, &Port.open/2)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [String.to_charlist(shell_flag), String.to_charlist(Config.settings!().codex.command)],
          cd: String.to_charlist(workspace),
          line: @port_line_bytes
        ]
        |> maybe_put_port_environment(codex_port_environment(port_environment, codex_home))

      with {:ok, _revalidated_workspace} <-
             validate_workspace_cwd(
               workspace,
               nil,
               Keyword.get(opts, :execution_context),
               Keyword.get(opts, :workspace_attestation)
             ),
           :ok <-
             Workspace.validate_private_home_effect(
               workspace,
               nil,
               Keyword.get(opts, :execution_context),
               Keyword.get(opts, :workspace_attestation),
               opts
             ),
           {:ok, ^codex_home} <- CodexAuthHome.resolve(Keyword.get(opts, :execution_context)) do
        port =
          port_opener.(
            {:spawn_executable, String.to_charlist(executable)},
            port_opts
          )

        {:ok, port}
      else
        {:ok, _changed_home} -> {:error, :codex_auth_home_invalid}
        {:error, _reason} = error -> error
      end
    end
  end

  defp start_port(workspace, worker_host, [], opts, nil) when is_binary(worker_host) do
    remote_command =
      remote_launch_command(
        workspace,
        Keyword.get(opts, :execution_context),
        Keyword.get(opts, :workspace_attestation)
      )

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp start_port(_workspace, worker_host, _port_environment, _opts, _codex_home)
       when is_binary(worker_host),
       do: {:error, :remote_subprocess_environment_unsupported}

  defp local_shell_contract({:win32, _name}), do: {"sh", "-c"}
  defp local_shell_contract({:unix, _name}), do: {"bash", "-lc"}

  defp codex_child_config(_opts, nil), do: nil

  defp codex_child_config(opts, _home) do
    paths = SubprocessEnvironment.private_home_paths(Keyword.fetch!(opts, :execution_context))
    %{"shell_environment_policy.set" => %{"CODEX_HOME" => paths.codex}}
  end

  defp codex_port_environment(environment, nil), do: environment

  defp codex_port_environment(environment, home) do
    [
      {~c"CODEX_HOME", String.to_charlist(home)}
      | Enum.reject(environment, fn {key, _value} -> String.upcase(to_string(key)) == "CODEX_HOME" end)
    ]
  end

  defp port_environment(opts) do
    case Keyword.get(opts, :env, %{}) do
      environment when is_map(environment) ->
        environment
        |> Enum.reduce_while({:ok, []}, &accumulate_port_environment/2)
        |> case do
          {:ok, entries} -> {:ok, Enum.reverse(entries)}
          {:error, _reason} = error -> error
        end

      _environment ->
        {:error, :invalid_subprocess_environment}
    end
  end

  defp accumulate_port_environment(entry, {:ok, entries}) do
    case port_environment_entry(entry) do
      {:ok, converted_entry} -> {:cont, {:ok, [converted_entry | entries]}}
      :error -> {:halt, {:error, :invalid_subprocess_environment}}
    end
  end

  defp port_environment_entry({key, value})
       when is_binary(key) and key != "" and is_binary(value) do
    if String.contains?(key, ["=", <<0>>]) or String.contains?(value, <<0>>),
      do: :error,
      else: {:ok, {String.to_charlist(key), String.to_charlist(value)}}
  end

  defp port_environment_entry({key, false}) when is_binary(key) and key != "" do
    if String.contains?(key, ["=", <<0>>]),
      do: :error,
      else: {:ok, {String.to_charlist(key), false}}
  end

  defp port_environment_entry(_entry), do: :error

  defp maybe_put_port_environment(port_opts, []), do: port_opts

  defp maybe_put_port_environment(port_opts, port_environment) do
    Keyword.put(port_opts, :env, port_environment)
  end

  defp remote_launch_command(workspace, execution_context, workspace_attestation)
       when is_binary(workspace) do
    Workspace.remote_execution_guard(workspace, execution_context, workspace_attestation) <>
      "exec #{Config.settings!().codex.command}"
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port, redaction_values) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id, redaction_values) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, managed_session, redaction_values, child_config) do
    with :ok <- send_initialize(port, redaction_values),
         :ok <- authenticate_codex(port, child_config) do
      start_thread(port, workspace, session_policies, managed_session, redaction_values, child_config)
    end
  end

  defp authenticate_codex(_port, nil), do: :ok

  defp authenticate_codex(port, _home) do
    send_message(port, %{"id" => @account_read_id, "method" => "account/read", "params" => %{"refreshToken" => true}})
    deadline = System.monotonic_time(:millisecond) + Config.settings!().codex.read_timeout_ms
    await_authentication(port, deadline, "")
  end

  # Account responses can contain private details. Never log or return their raw payloads.
  # Use one deadline, including partial lines and unrelated notifications.
  defp await_authentication(port, deadline, pending) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {ending, chunk}}} ->
        line = pending <> to_string(chunk)

        cond do
          byte_size(line) > @port_line_bytes or remaining == 0 ->
            {:error, :codex_authentication_unavailable}

          ending == :noeol ->
            await_authentication(port, deadline, line)

          true ->
            case Jason.decode(line) do
              {:ok, %{"id" => @account_read_id, "result" => result}} -> account_status(result)
              {:ok, %{"id" => @account_read_id}} -> {:error, :codex_authentication_unavailable}
              _other -> await_authentication(port, deadline, "")
            end
        end

      {^port, {:exit_status, _status}} ->
        {:error, :codex_authentication_unavailable}
    after
      remaining -> {:error, :codex_authentication_unavailable}
    end
  end

  defp account_status(%{"requiresOpenaiAuth" => false}), do: :ok

  defp account_status(%{"requiresOpenaiAuth" => true, "account" => %{"type" => type}})
       when type in ["chatgpt", "apiKey"], do: :ok

  defp account_status(%{"requiresOpenaiAuth" => true, "account" => nil}),
    do: {:error, :codex_authentication_required}

  defp account_status(_result), do: {:error, :codex_authentication_unavailable}

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         managed_session,
         redaction_values,
         child_config
       ) do
    params = %{
      "approvalPolicy" => approval_policy,
      "sandbox" => thread_sandbox,
      "cwd" => workspace,
      "dynamicTools" => DynamicTool.tool_specs(managed_session: managed_session)
    }

    params = if is_nil(child_config), do: params, else: Map.put(params, "config", child_config)

    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => params
    })

    case await_response(port, @thread_start_id, redaction_values) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(
         port,
         thread_id,
         prompt,
         issue,
         workspace,
         approval_policy,
         turn_sandbox_policy,
         redaction_values
       ) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id, redaction_values) do
      {:ok, %{"turn" => %{"id" => turn_id}}} ->
        {:ok, turn_id}

      other ->
        other
    end
  end

  defp await_turn_completion(
         port,
         on_message,
         tool_executor,
         auto_approve_requests,
         redaction_values
       ) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests,
      redaction_values
    )
  end

  defp receive_loop(
         port,
         on_message,
         timeout_ms,
         pending_line,
         tool_executor,
         auto_approve_requests,
         redaction_values
       ) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_incoming(
          port,
          on_message,
          complete_line,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          redaction_values
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests,
          redaction_values
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(
         port,
         on_message,
         data,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         redaction_values
       ) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        payload = sanitize_term(payload, redaction_values)
        payload_string = Jason.encode!(payload)
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        payload = sanitize_term(payload, redaction_values)
        payload_string = Jason.encode!(payload)

        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        payload = sanitize_term(payload, redaction_values)
        payload_string = Jason.encode!(payload)

        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        sanitized_payload_string =
          payload
          |> sanitize_term(redaction_values)
          |> Jason.encode!()

        turn_context = %{
          port: port,
          on_message: on_message,
          timeout_ms: timeout_ms,
          tool_executor: tool_executor,
          auto_approve_requests: auto_approve_requests,
          redaction_values: redaction_values
        }

        handle_turn_method(turn_context, payload, sanitized_payload_string, method)

      {:ok, payload} ->
        payload = sanitize_term(payload, redaction_values)
        payload_string = Jason.encode!(payload)

        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          auto_approve_requests,
          redaction_values
        )

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream", redaction_values)

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          auto_approve_requests,
          redaction_values
        )
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(context, payload, payload_string, method) do
    metadata = metadata_from_message(context.port, payload)

    case maybe_handle_approval_request(
           context.port,
           method,
           payload,
           payload_string,
           context.on_message,
           metadata,
           context.tool_executor,
           context.auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          context.on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(
          context.port,
          context.on_message,
          context.timeout_ms,
          "",
          context.tool_executor,
          context.auto_approve_requests,
          context.redaction_values
        )

      :approval_required ->
        emit_message(
          context.on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            context.on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            context.on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(sanitize_string(method, context.redaction_values))}")

          receive_loop(
            context.port,
            context.on_message,
            context.timeout_ms,
            "",
            context.tool_executor,
            context.auto_approve_requests,
            context.redaction_values
          )
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id, redaction_values) do
    with_timeout_response(
      port,
      request_id,
      Config.settings!().codex.read_timeout_ms,
      "",
      redaction_values
    )
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line, redaction_values) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms, redaction_values)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(
          port,
          request_id,
          timeout_ms,
          pending_line <> to_string(chunk),
          redaction_values
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms, redaction_values) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(sanitize_term(other, redaction_values))}")
        with_timeout_response(port, request_id, timeout_ms, "", redaction_values)

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream", redaction_values)
        with_timeout_response(port, request_id, timeout_ms, "", redaction_values)
    end
  end

  defp log_non_json_stream_line(data, stream_label, redaction_values) do
    text =
      data
      |> to_string()
      |> sanitize_string(redaction_values)
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp redaction_values(opts) do
    opts
    |> Keyword.get_lazy(:sensitive_env_values, fn ->
      case Keyword.get(opts, :env, %{}) do
        environment when is_map(environment) -> Map.values(environment)
        _environment -> []
      end
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp sanitize_string(value, redaction_values) when is_binary(value) do
    Enum.reduce(redaction_values, value, fn sensitive_value, sanitized ->
      String.replace(sanitized, sensitive_value, "[redacted]")
    end)
  end

  defp sanitize_term(value, redaction_values) when is_binary(value),
    do: sanitize_string(value, redaction_values)

  defp sanitize_term(value, redaction_values) when is_list(value),
    do: Enum.map(value, &sanitize_term(&1, redaction_values))

  defp sanitize_term(value, redaction_values) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_term(&1, redaction_values))
    |> List.to_tuple()
  end

  defp sanitize_term(value, _redaction_values) when is_struct(value), do: value

  defp sanitize_term(value, redaction_values) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {sanitize_term(key, redaction_values), sanitize_term(nested_value, redaction_values)}
    end)
  end

  defp sanitize_term(value, _redaction_values), do: value

  defp sanitized_message_handler(on_message, redaction_values) do
    fn message -> on_message.(sanitize_term(message, redaction_values)) end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
