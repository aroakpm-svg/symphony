defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, GitBranchResolver, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_readiness_marker "__SYMPHONY_READINESS_STATE__"
  @readiness_state_suffix ".symphony-readiness-v1.json"
  @readiness_state_version 1
  @max_readiness_state_bytes 65_536
  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/

  defmodule ReadinessState do
    @moduledoc "Typed durable workspace provenance used by the pre-dispatch readiness gate."

    @enforce_keys [
      :version,
      :provenance,
      :phase,
      :issue_id,
      :issue_identifier,
      :issue_branch,
      :workspace_path,
      :verified_head_sha
    ]
    defstruct [
      :version,
      :provenance,
      :phase,
      :issue_id,
      :issue_identifier,
      :issue_branch,
      :workspace_path,
      :verified_head_sha
    ]

    @type t :: %__MODULE__{
            version: pos_integer(),
            provenance: :created | :legacy,
            phase: :unverified | :ready,
            issue_id: String.t() | nil,
            issue_identifier: String.t(),
            issue_branch: String.t() | nil,
            workspace_path: Path.t(),
            verified_head_sha: String.t() | nil
          }
  end

  @type worker_host :: String.t() | nil
  @type preparation :: %{
          path: Path.t(),
          created_now: boolean(),
          readiness_state: ReadinessState.t()
        }

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    case prepare_for_issue(issue_or_identifier, worker_host) do
      {:ok, %{path: workspace}} -> {:ok, workspace}
      {:error, _reason} = error -> error
    end
  end

  @spec prepare_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, preparation()} | {:error, term()}
  def prepare_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           {:ok, readiness_state} <-
             prepare_readiness_state(workspace, issue_context, created?, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok,
         %{
           path: workspace,
           created_now: created?,
           readiness_state: readiness_state
         }}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  @spec readiness_state_path(Path.t()) :: Path.t()
  def readiness_state_path(workspace) when is_binary(workspace) do
    workspace <> @readiness_state_suffix
  end

  @spec mark_readiness_ready(preparation(), map() | String.t() | nil, map()) ::
          :ok | {:error, term()}
  def mark_readiness_ready(preparation, issue_or_identifier, receipt) do
    mark_readiness_ready(preparation, issue_or_identifier, receipt, nil)
  end

  @spec mark_readiness_ready(preparation(), map() | String.t() | nil, map(), worker_host()) ::
          :ok | {:error, term()}
  def mark_readiness_ready(
        preparation,
        issue_or_identifier,
        receipt,
        worker_host
      ) do
    mark_readiness_ready(preparation, issue_or_identifier, receipt, worker_host, [])
  end

  @spec mark_readiness_ready(
          preparation(),
          map() | String.t() | nil,
          map(),
          worker_host(),
          keyword()
        ) :: :ok | {:error, term()}
  def mark_readiness_ready(
        %{path: workspace, readiness_state: %ReadinessState{} = expected_state},
        issue_or_identifier,
        receipt,
        worker_host,
        opts
      )
      when is_binary(workspace) and is_list(opts) do
    issue_context = issue_context(issue_or_identifier)

    with :ok <- validate_readiness_identity(expected_state, workspace, issue_context),
         :ok <- validate_readiness_receipt(receipt, expected_state, workspace),
         {:ok, %ReadinessState{} = current_state} <-
           read_existing_readiness_state(workspace, worker_host),
         :ok <- compare_readiness_state(current_state, expected_state, workspace),
         :ok <-
           verify_live_readiness_checkout(
             workspace,
             receipt,
             worker_host,
             opts
           ) do
      ready_state = %{
        expected_state
        | phase: :ready,
          verified_head_sha: String.downcase(receipt.head_sha)
      }

      write_readiness_state(workspace, ready_state, worker_host)
    end
  end

  def mark_readiness_ready(
        %{path: workspace},
        _issue_or_identifier,
        _receipt,
        _worker_host,
        _opts
      )
      when is_binary(workspace) do
    {:error, {:workspace_readiness_state_invalid, workspace, "typed preparation state is missing"}}
  end

  def mark_readiness_ready(
        _preparation,
        _issue_or_identifier,
        _receipt,
        _worker_host,
        _opts
      ) do
    {:error, {:workspace_readiness_state_invalid, "unknown", "typed preparation state is missing"}}
  end

  defp prepare_readiness_state(workspace, issue_context, true, worker_host) do
    state = new_readiness_state(workspace, issue_context, :created)

    case write_readiness_state(workspace, state, worker_host) do
      :ok -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_readiness_state(workspace, issue_context, false, worker_host) do
    case read_readiness_state(workspace, worker_host) do
      {:ok, :missing} ->
        state = new_readiness_state(workspace, issue_context, :legacy)

        case write_readiness_state(workspace, state, worker_host) do
          :ok -> {:ok, state}
          {:error, _reason} = error -> error
        end

      {:ok, %ReadinessState{} = state} ->
        case reconcile_readiness_identity(state, workspace, issue_context) do
          {:ok, ^state} ->
            {:ok, state}

          {:ok, enriched_state} ->
            persist_enriched_readiness_state(workspace, enriched_state, worker_host)

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_enriched_readiness_state(workspace, enriched_state, worker_host) do
    with :ok <- write_readiness_state(workspace, enriched_state, worker_host) do
      {:ok, enriched_state}
    end
  end

  defp new_readiness_state(workspace, issue_context, provenance) do
    %ReadinessState{
      version: @readiness_state_version,
      provenance: provenance,
      phase: :unverified,
      issue_id: issue_context.issue_id,
      issue_identifier: issue_context.issue_identifier,
      issue_branch: issue_context.issue_branch,
      workspace_path: workspace,
      verified_head_sha: nil
    }
  end

  defp validate_readiness_identity(%ReadinessState{} = state, workspace, issue_context) do
    expected = %{
      issue_id: issue_context.issue_id,
      issue_identifier: issue_context.issue_identifier,
      issue_branch: issue_context.issue_branch,
      workspace_path: workspace
    }

    mismatches =
      expected
      |> Enum.flat_map(fn {field, expected_value} ->
        actual_value = Map.fetch!(state, field)

        if actual_value == expected_value do
          []
        else
          ["#{field} expected=#{inspect(expected_value)} actual=#{inspect(actual_value)}"]
        end
      end)
      |> Enum.sort()

    case mismatches do
      [] ->
        :ok

      _ ->
        {:error, {:workspace_readiness_identity_mismatch, workspace, "persisted readiness identity mismatch: #{Enum.join(mismatches, "; ")}"}}
    end
  end

  defp reconcile_readiness_identity(%ReadinessState{} = state, workspace, issue_context) do
    case validate_readiness_identity(state, workspace, issue_context) do
      :ok ->
        {:ok, state}

      {:error, _reason} = identity_error ->
        if readiness_identity_enrichable?(state, workspace, issue_context) do
          {:ok,
           %{
             state
             | issue_id: issue_context.issue_id,
               issue_branch: issue_context.issue_branch
           }}
        else
          identity_error
        end
    end
  end

  defp readiness_identity_enrichable?(state, workspace, issue_context) do
    state.phase == :unverified and
      state.workspace_path == workspace and
      state.issue_identifier == issue_context.issue_identifier and
      complete_issue_identity?(issue_context) and
      missing_or_matching_identity?(state.issue_id, issue_context.issue_id) and
      missing_or_matching_identity?(state.issue_branch, issue_context.issue_branch) and
      (is_nil(state.issue_id) or is_nil(state.issue_branch))
  end

  defp complete_issue_identity?(issue_context) do
    non_empty_binary?(issue_context.issue_id) and
      non_empty_binary?(issue_context.issue_identifier) and
      non_empty_binary?(issue_context.issue_branch)
  end

  defp missing_or_matching_identity?(nil, _expected), do: true
  defp missing_or_matching_identity?(actual, expected), do: actual == expected

  defp non_empty_binary?(value), do: is_binary(value) and value != ""

  defp validate_readiness_receipt(receipt, expected_state, workspace) do
    cond do
      not is_struct(receipt, SymphonyElixir.ReadinessGate.Receipt) ->
        {:error, {:workspace_readiness_receipt_mismatch, workspace, :receipt_type}}

      receipt.issue_branch != expected_state.issue_branch ->
        {:error, {:workspace_readiness_receipt_mismatch, workspace, :issue_branch}}

      not (is_binary(receipt.head_sha) and Regex.match?(@sha_pattern, receipt.head_sha)) ->
        {:error, {:workspace_readiness_receipt_mismatch, workspace, :head_sha}}

      true ->
        :ok
    end
  end

  defp compare_readiness_state(%ReadinessState{} = state, %ReadinessState{} = state, _workspace),
    do: :ok

  defp compare_readiness_state(_current_state, _expected_state, workspace) do
    {:error, {:workspace_readiness_state_changed, workspace, "persisted readiness state changed during verification"}}
  end

  defp verify_live_readiness_checkout(workspace, receipt, worker_host, opts) do
    runner =
      case Keyword.get(opts, :command_runner) do
        runner when is_function(runner, 1) -> runner
        nil -> fn args -> run_git_command(workspace, args, worker_host) end
      end

    expected_branch = receipt.issue_branch
    expected_head = String.downcase(receipt.head_sha)

    case GitBranchResolver.current_checkout(runner) do
      {:ok, %{branch: ^expected_branch, head_sha: ^expected_head}} ->
        :ok

      {:ok, checkout} ->
        readiness_checkout_changed(workspace, expected_branch, expected_head, checkout)

      {:error, %GitBranchResolver.Failure{} = failure} ->
        {:error, {:workspace_changed_before_readiness_persist, workspace, "expected #{expected_branch}@#{expected_head}; live checkout could not be verified: #{failure.detail}"}}
    end
  end

  defp readiness_checkout_changed(workspace, expected_branch, expected_head, checkout) do
    {:error, {:workspace_changed_before_readiness_persist, workspace, "expected #{expected_branch}@#{expected_head}, found #{checkout.branch}@#{checkout.head_sha}"}}
  end

  defp read_existing_readiness_state(workspace, worker_host) do
    case read_readiness_state(workspace, worker_host) do
      {:ok, %ReadinessState{} = state} ->
        {:ok, state}

      {:ok, :missing} ->
        {:error, {:workspace_readiness_state_missing, workspace, "persisted readiness state disappeared during verification"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp read_readiness_state(workspace, nil) do
    state_path = readiness_state_path(workspace)

    case File.lstat(state_path) do
      {:error, :enoent} ->
        {:ok, :missing}

      {:ok, %File.Stat{type: :regular, size: size}}
      when size <= @max_readiness_state_bytes ->
        case File.read(state_path) do
          {:ok, json} -> decode_readiness_state(json, workspace)
          {:error, reason} -> readiness_state_read_error(workspace, reason)
        end

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:error, {:workspace_readiness_state_invalid, workspace, "readiness state exceeds #{@max_readiness_state_bytes} bytes: #{size}"}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:workspace_readiness_state_invalid, workspace, "readiness state must be a regular file, got #{type}"}}

      {:error, reason} ->
        readiness_state_read_error(workspace, reason)
    end
  end

  defp read_readiness_state(workspace, worker_host) when is_binary(worker_host) do
    state_path = readiness_state_path(workspace)

    script =
      [
        "set -eu",
        remote_shell_assign("readiness_state", state_path),
        "if [ ! -e \"$readiness_state\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_readiness_marker}' 'missing'",
        "elif [ -L \"$readiness_state\" ] || [ ! -f \"$readiness_state\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_readiness_marker}' 'invalid-type'",
        "else",
        "  state_size=\"$(wc -c < \"$readiness_state\")\"",
        "  if [ \"$state_size\" -gt #{@max_readiness_state_bytes} ]; then",
        "    printf '%s\\t%s\\t%s\\n' '#{@remote_readiness_marker}' 'too-large' \"$state_size\"",
        "  else",
        "    printf '%s\\t%s\\t' '#{@remote_readiness_marker}' 'present'",
        "    cat \"$readiness_state\"",
        "    printf '\\n'",
        "  fi",
        "fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_readiness_state(output, workspace)

      {:ok, {output, status}} ->
        readiness_state_read_error(
          workspace,
          "worker=#{worker_host} status=#{status} output=#{sanitize_hook_output_for_log(output)}"
        )

      {:error, reason} ->
        readiness_state_read_error(workspace, reason)
    end
  end

  defp parse_remote_readiness_state(output, workspace) do
    result =
      output
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)
      |> Enum.find_value(&parse_remote_readiness_state_line/1)

    case result do
      {:ok, :missing} ->
        {:ok, :missing}

      {:present, json} ->
        decode_readiness_state(json, workspace)

      {:invalid, detail} ->
        {:error, {:workspace_readiness_state_invalid, workspace, "remote readiness state #{detail}"}}

      nil ->
        readiness_state_read_error(workspace, "remote state command returned no typed marker")
    end
  end

  defp parse_remote_readiness_state_line(line) do
    case String.split(line, "\t", parts: 3) do
      [@remote_readiness_marker, "missing"] -> {:ok, :missing}
      [@remote_readiness_marker, "present", json] -> {:present, json}
      [@remote_readiness_marker, "invalid-type"] -> {:invalid, "must be a regular file"}
      [@remote_readiness_marker, "too-large", size] -> {:invalid, "is too large: #{size}"}
      _ -> nil
    end
  end

  defp decode_readiness_state(json, workspace) do
    case Jason.decode(json) do
      {:ok,
       %{
         "version" => @readiness_state_version,
         "provenance" => provenance,
         "phase" => phase,
         "issue_id" => issue_id,
         "issue_identifier" => issue_identifier,
         "issue_branch" => issue_branch,
         "workspace_path" => workspace_path,
         "verified_head_sha" => verified_head_sha
       } = decoded}
      when map_size(decoded) == 8 ->
        build_readiness_state(
          workspace,
          provenance,
          phase,
          issue_id,
          issue_identifier,
          issue_branch,
          workspace_path,
          verified_head_sha
        )

      {:ok, _decoded} ->
        {:error, {:workspace_readiness_state_invalid, workspace, "readiness state JSON has an unsupported schema"}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:workspace_readiness_state_invalid, workspace, "readiness state JSON is malformed: #{Exception.message(error)}"}}
    end
  end

  defp build_readiness_state(
         workspace,
         provenance,
         phase,
         issue_id,
         issue_identifier,
         issue_branch,
         workspace_path,
         verified_head_sha
       ) do
    with {:ok, provenance_atom} <- parse_readiness_provenance(provenance),
         {:ok, phase_atom} <- parse_readiness_phase(phase, verified_head_sha),
         true <- is_nil(issue_id) or is_binary(issue_id),
         true <- is_binary(issue_identifier) and issue_identifier != "",
         true <- is_nil(issue_branch) or is_binary(issue_branch),
         true <- is_binary(workspace_path) and workspace_path != "" do
      {:ok,
       %ReadinessState{
         version: @readiness_state_version,
         provenance: provenance_atom,
         phase: phase_atom,
         issue_id: issue_id,
         issue_identifier: issue_identifier,
         issue_branch: issue_branch,
         workspace_path: workspace_path,
         verified_head_sha: normalize_verified_head(verified_head_sha)
       }}
    else
      _ ->
        {:error, {:workspace_readiness_state_invalid, workspace, "readiness state JSON contains invalid typed values"}}
    end
  end

  defp parse_readiness_provenance("created"), do: {:ok, :created}
  defp parse_readiness_provenance("legacy"), do: {:ok, :legacy}
  defp parse_readiness_provenance(_provenance), do: :error

  defp parse_readiness_phase("unverified", nil), do: {:ok, :unverified}

  defp parse_readiness_phase("ready", sha) when is_binary(sha) do
    if Regex.match?(@sha_pattern, sha), do: {:ok, :ready}, else: :error
  end

  defp parse_readiness_phase(_phase, _sha), do: :error

  defp normalize_verified_head(nil), do: nil
  defp normalize_verified_head(sha), do: String.downcase(sha)

  defp write_readiness_state(workspace, %ReadinessState{} = state, nil) do
    state_path = readiness_state_path(workspace)
    temporary_path = state_path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"
    json = encode_readiness_state(state)

    result =
      with :ok <- File.write(temporary_path, json, [:binary, :exclusive]),
           :ok <- File.chmod(temporary_path, 0o600) do
        File.rename(temporary_path, state_path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(temporary_path)

        {:error, {:workspace_readiness_state_write_failed, workspace, sanitize_hook_output_for_log(inspect(reason))}}
    end
  end

  defp write_readiness_state(workspace, %ReadinessState{} = state, worker_host)
       when is_binary(worker_host) do
    state_path = readiness_state_path(workspace)
    json = encode_readiness_state(state)

    script =
      [
        "set -eu",
        "umask 077",
        remote_shell_assign("readiness_state", state_path),
        "readiness_tmp=\"${readiness_state}.tmp.$$\"",
        "trap 'rm -f \"$readiness_tmp\"' EXIT HUP INT TERM",
        "printf '%s' #{shell_escape(json)} > \"$readiness_tmp\"",
        "chmod 600 \"$readiness_tmp\"",
        "mv -f \"$readiness_tmp\" \"$readiness_state\"",
        "trap - EXIT HUP INT TERM"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, {:workspace_readiness_state_write_failed, workspace, "worker=#{worker_host} status=#{status} output=#{sanitize_hook_output_for_log(output)}"}}

      {:error, reason} ->
        {:error, {:workspace_readiness_state_write_failed, workspace, sanitize_hook_output_for_log(inspect(reason))}}
    end
  end

  defp encode_readiness_state(%ReadinessState{} = state) do
    Jason.encode!(%{
      "version" => state.version,
      "provenance" => Atom.to_string(state.provenance),
      "phase" => Atom.to_string(state.phase),
      "issue_id" => state.issue_id,
      "issue_identifier" => state.issue_identifier,
      "issue_branch" => state.issue_branch,
      "workspace_path" => state.workspace_path,
      "verified_head_sha" => state.verified_head_sha
    })
  end

  defp readiness_state_read_error(workspace, reason) do
    {:error, {:workspace_readiness_state_read_failed, workspace, sanitize_hook_output_for_log(inspect(reason))}}
  end

  defp remove_local_readiness_state(state_path) do
    case File.rm(state_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:workspace_readiness_state_remove_failed, state_path, reason}, ""}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    state_path = readiness_state_path(workspace)

    case File.exists?(workspace) or File.exists?(state_path) do
      true ->
        remove_existing_local_workspace(workspace, state_path)

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("readiness_state", readiness_state_path(workspace)),
        "rm -rf \"$workspace\"",
        "rm -f \"$readiness_state\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp remove_existing_local_workspace(workspace, state_path) do
    case validate_workspace_path(workspace, nil) do
      :ok ->
        maybe_run_before_remove_hook(workspace, nil)

        with {:ok, removed} <- File.rm_rf(workspace),
             :ok <- remove_local_readiness_state(state_path) do
          {:ok, removed}
        end

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec preflight(Path.t(), map() | String.t() | nil, worker_host()) :: :ok | {:error, term()}
  def preflight(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    Logger.info("Running workspace preflight #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")

    case worker_host do
      nil -> local_preflight(workspace)
      host when is_binary(host) -> remote_preflight(workspace, host)
    end
  end

  @spec run_git_command(Path.t(), [String.t()], worker_host()) ::
          {:ok, String.t()}
          | {:error, {:git_command_failed, String.t(), integer(), String.t()}}
          | {:error, {:git_command_failed, String.t(), String.t()}}
          | {:error, {:workspace_hook_timeout, String.t(), pos_integer()}}
  def run_git_command(workspace, args, worker_host \\ nil)
      when is_binary(workspace) and is_list(args) do
    command = git_command_for_log(args)

    case worker_host do
      nil -> run_local_git_command(workspace, args, command)
      host when is_binary(host) -> run_remote_git_command(workspace, args, host, command)
    end
  end

  @doc false
  @spec run_git_command_with_status(Path.t(), [String.t()], worker_host()) ::
          {:ok, non_neg_integer(), binary()} | {:error, term()}
  def run_git_command_with_status(workspace, args, worker_host \\ nil)
      when is_binary(workspace) and is_list(args) do
    command = git_command_for_log(args)

    case worker_host do
      nil ->
        case run_local_preflight_command("git", ["-C", workspace | args], command) do
          {output, status} when is_integer(status) -> {:ok, status, IO.iodata_to_binary(output)}
          {:error, reason} -> {:error, {:git_command_failed, command, inspect(reason)}}
        end

      host when is_binary(host) ->
        script = "cd #{shell_escape(workspace)} && #{remote_git_command(args)}"

        case run_remote_command(host, script, Config.settings!().hooks.timeout_ms) do
          {:ok, {output, status}} when is_integer(status) ->
            {:ok, status, IO.iodata_to_binary(output)}

          {:error, reason} ->
            {:error, {:git_command_failed, command, inspect(reason)}}
        end
    end
  end

  @spec sanitize_command_output(iodata(), non_neg_integer()) :: String.t()
  def sanitize_command_output(output, max_bytes \\ 2_048) do
    sanitize_hook_output_for_log(output, max_bytes)
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        try do
          System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
        rescue
          error in ErlangError -> {:error, error.original}
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:error, reason}} ->
        {:error, {:workspace_hook_failed, hook_name, reason}}

      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:exit, reason} ->
        {:error, {:workspace_hook_failed, hook_name, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp local_preflight(workspace) do
    with :ok <- require_workspace_dir(workspace),
         :ok <- run_git_preflight_command(workspace, ["rev-parse", "--is-inside-work-tree"], :workspace_not_git_repo),
         :ok <- maybe_validate_origin_remote(workspace),
         :ok <- run_git_preflight_command(workspace, ["status", "--short"], :git_status_failed) do
      run_git_preflight_command(workspace, ["fetch", "origin", "--prune"], :git_fetch_failed)
    end
  end

  defp remote_preflight(workspace, worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "cd \"$workspace\"",
        "git rev-parse --is-inside-work-tree >/dev/null",
        remote_expected_repo_script(),
        "git status --short >/dev/null",
        "git fetch origin --prune >/dev/null"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, workspace_preflight_error(:remote_workspace_preflight_failed, "remote preflight", status, output)}

      {:error, reason} ->
        {:error, {:workspace_preflight_failed, :remote_workspace_preflight_failed, "remote preflight", reason}}
    end
  end

  defp require_workspace_dir(workspace) do
    if File.dir?(workspace) do
      :ok
    else
      {:error, {:workspace_preflight_failed, :workspace_missing, "test -d workspace", workspace}}
    end
  end

  defp maybe_validate_origin_remote(workspace) do
    case expected_source_repo_url() do
      nil ->
        run_git_preflight_command(workspace, ["config", "--get", "remote.origin.url"], :git_remote_missing)

      expected_url ->
        case run_local_preflight_command(
               "git",
               ["-C", workspace, "config", "--get", "remote.origin.url"],
               "git config --get remote.origin.url"
             ) do
          {output, 0} ->
            validate_origin_remote(String.trim(output), expected_url)

          {output, status} when is_integer(status) ->
            {:error, workspace_preflight_error(:git_remote_missing, "git config --get remote.origin.url", status, output)}

          {:error, reason} ->
            {:error, workspace_preflight_error(:git_remote_missing, "git config --get remote.origin.url", reason)}
        end
    end
  end

  defp validate_origin_remote(actual_url, expected_url) do
    if comparable_repo_url(actual_url) == comparable_repo_url(expected_url) do
      :ok
    else
      message = "expected #{redacted_repo_url(expected_url)}, got #{redacted_repo_url(actual_url)}"
      {:error, {:workspace_preflight_failed, :git_remote_mismatch, "git config --get remote.origin.url", message}}
    end
  end

  defp run_git_preflight_command(workspace, args, error_type) do
    command = Enum.join(["git" | args], " ")

    case run_local_preflight_command("git", ["-C", workspace | args], command) do
      {_output, 0} ->
        :ok

      {output, status} when is_integer(status) ->
        {:error, workspace_preflight_error(error_type, command, status, output)}

      {:error, reason} ->
        {:error, workspace_preflight_error(error_type, command, reason)}
    end
  end

  defp run_local_git_command(workspace, args, command) do
    case run_local_preflight_command("git", ["-C", workspace | args], command) do
      {output, 0} ->
        {:ok, IO.iodata_to_binary(output)}

      {output, status} when is_integer(status) ->
        {:error, {:git_command_failed, command, status, sanitize_hook_output_for_log(output)}}

      {:error, {:workspace_hook_timeout, _timed_command, timeout_ms}} ->
        {:error, {:workspace_hook_timeout, command, timeout_ms}}

      {:error, reason} ->
        {:error, {:git_command_failed, command, sanitize_hook_output_for_log(inspect(reason))}}
    end
  end

  defp run_remote_git_command(workspace, args, worker_host, command) do
    script = "cd #{shell_escape(workspace)} && #{remote_git_command(args)}"

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, IO.iodata_to_binary(output)}

      {:ok, {output, status}} when is_integer(status) ->
        {:error, {:git_command_failed, command, status, sanitize_hook_output_for_log(output)}}

      {:error, {:workspace_hook_timeout, _timed_command, timeout_ms}} ->
        {:error, {:workspace_hook_timeout, command, timeout_ms}}

      {:error, reason} ->
        {:error, {:git_command_failed, command, sanitize_hook_output_for_log(inspect(reason))}}
    end
  end

  defp git_command_for_log(args) do
    ["git" | Enum.map(args, &sanitize_hook_output_for_log/1)]
    |> Enum.join(" ")
  end

  defp remote_git_command(args) do
    "git " <> Enum.map_join(args, " ", &shell_escape/1)
  end

  defp workspace_preflight_error(error_type, command, status, output) do
    {:workspace_preflight_failed, error_type, command, status, sanitize_hook_output_for_log(output)}
  end

  defp workspace_preflight_error(error_type, command, {:workspace_hook_timeout, _command, timeout_ms}) do
    {:workspace_preflight_failed, error_type, command, "timed out after #{timeout_ms}ms"}
  end

  defp workspace_preflight_error(error_type, command, reason) do
    {:workspace_preflight_failed, error_type, command, inspect(reason)}
  end

  defp run_local_preflight_command(executable, args, command) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    task =
      Task.async(fn ->
        try do
          System.cmd(executable, args,
            stderr_to_stdout: true,
            env: local_git_preflight_env()
          )
        rescue
          error in ErlangError -> {:error, error.original}
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, command, timeout_ms}}
    end
  end

  @doc false
  @spec run_local_preflight_command_for_test(String.t(), [String.t()], String.t()) ::
          {String.t(), non_neg_integer()} | {:error, term()}
  def run_local_preflight_command_for_test(executable, args, command) do
    run_local_preflight_command(executable, args, command)
  end

  defp local_git_preflight_env do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GCM_INTERACTIVE", "Never"}
    ]
    |> maybe_add_git_ssh_command(System.get_env("GIT_SSH_COMMAND"))
  end

  defp maybe_add_git_ssh_command(env, nil), do: env
  defp maybe_add_git_ssh_command(env, ""), do: env

  defp maybe_add_git_ssh_command(env, command) when is_binary(command) do
    [{"GIT_SSH_COMMAND", batch_mode_ssh_command(command)} | env]
  end

  defp batch_mode_ssh_command(nil), do: nil
  defp batch_mode_ssh_command(""), do: nil

  defp batch_mode_ssh_command(command) when is_binary(command) do
    if String.contains?(command, "BatchMode") do
      command
    else
      command <> " -o BatchMode=yes"
    end
  end

  @doc false
  @spec batch_mode_ssh_command_for_test(String.t() | nil) :: String.t() | nil
  def batch_mode_ssh_command_for_test(command), do: batch_mode_ssh_command(command)

  @doc false
  @spec local_git_preflight_env_for_test(String.t() | nil) :: [{String.t(), String.t()}]
  def local_git_preflight_env_for_test(command) do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GCM_INTERACTIVE", "Never"}
    ]
    |> maybe_add_git_ssh_command(command)
  end

  defp remote_expected_repo_script do
    case expected_source_repo_url() do
      nil ->
        "git config --get remote.origin.url >/dev/null"

      expected_url ->
        expected = shell_escape(comparable_repo_url(expected_url))

        [
          "strip_url_userinfo() {",
          "  case \"$1\" in",
          "    *://*@*) printf '%s://%s\\n' \"${1%%://*}\" \"${1#*@}\" ;;",
          "    *) printf '%s\\n' \"$1\" ;;",
          "  esac",
          "}",
          "actual_remote=\"$(git config --get remote.origin.url)\"",
          "actual_remote=\"$(strip_url_userinfo \"$actual_remote\")\"",
          "actual_remote=\"${actual_remote%/}\"",
          "actual_remote=\"${actual_remote%.git}\"",
          "expected_remote=#{expected}",
          "expected_remote=\"${expected_remote%/}\"",
          "expected_remote=\"${expected_remote%.git}\"",
          "test \"$actual_remote\" = \"$expected_remote\""
        ]
        |> Enum.join("\n")
    end
  end

  @doc false
  @spec remote_expected_repo_script_for_test() :: String.t()
  def remote_expected_repo_script_for_test, do: remote_expected_repo_script()

  @doc false
  @spec sanitize_hook_output_for_test(iodata(), non_neg_integer()) :: String.t()
  def sanitize_hook_output_for_test(output, max_bytes), do: sanitize_hook_output_for_log(output, max_bytes)

  defp expected_source_repo_url do
    case System.get_env("SOURCE_REPO_URL") do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp comparable_repo_url(url) when is_binary(url) do
    url
    |> strip_url_userinfo()
    |> normalized_repo_url()
  end

  defp normalized_repo_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    redacted_output =
      output
      |> IO.iodata_to_binary()
      |> redact_url_userinfo()

    case byte_size(redacted_output) <= max_bytes do
      true ->
        redacted_output

      false ->
        binary_part(redacted_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp redacted_repo_url(url) when is_binary(url) do
    url
    |> normalized_repo_url()
    |> redact_url_userinfo()
  end

  defp redact_url_userinfo(value) when is_binary(value) do
    String.replace(value, ~r{([a-z][a-z0-9+.-]*://)([^/@\s]+)@}i, "\\1[redacted]@")
  end

  defp strip_url_userinfo(value) when is_binary(value) do
    String.replace(value, ~r{^([a-z][a-z0-9+.-]*://)([^/@\s]+)@}i, "\\1")
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_branch: Map.get(issue, :branch_name)
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_branch: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_branch: nil
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
