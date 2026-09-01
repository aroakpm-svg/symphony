defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger

  alias SymphonyElixir.{
    Config,
    GitBranchResolver,
    PathSafety,
    PrivateHome.WindowsCapability,
    ProjectExecutionContext,
    RepositorySource,
    SSH,
    SubprocessEnvironment
  }

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_readiness_marker "__SYMPHONY_READINESS_STATE__"
  @readiness_state_suffix ".symphony-readiness-v1.json"
  @readiness_state_version 1
  @max_readiness_state_bytes 65_536
  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/
  @private_home_path_keys [:root, :home, :gh, :xdg_config, :xdg_cache, :xdg_data, :codex]
  @private_home_environment_keys %{
    "HOME" => :home,
    "USERPROFILE" => :home,
    "GH_CONFIG_DIR" => :gh,
    "XDG_CONFIG_HOME" => :xdg_config,
    "XDG_CACHE_HOME" => :xdg_cache,
    "XDG_DATA_HOME" => :xdg_data,
    "CODEX_HOME" => :codex
  }

  defmodule ReadinessState do
    @moduledoc "Typed durable workspace provenance used by the pre-dispatch readiness gate."

    @enforce_keys [
      :version,
      :provenance,
      :phase,
      :issue_id,
      :issue_identifier,
      :issue_branch,
      :profile_key,
      :linear_project_id,
      :repository,
      :canonical_branch,
      :workspace_namespace,
      :credential_ref,
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
      :profile_key,
      :linear_project_id,
      :repository,
      :canonical_branch,
      :workspace_namespace,
      :credential_ref,
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
            profile_key: String.t() | nil,
            linear_project_id: String.t() | nil,
            repository: String.t() | nil,
            canonical_branch: String.t() | nil,
            workspace_namespace: String.t() | nil,
            credential_ref: String.t() | nil,
            workspace_path: Path.t(),
            verified_head_sha: String.t() | nil
          }
  end

  defmodule PrivateHomeCapability do
    @moduledoc false

    @enforce_keys [
      :platform,
      :guard,
      :lifecycle,
      :workspace,
      :execution_context,
      :workspace_attestation,
      :namespace_attestation,
      :namespace_path,
      :identities,
      :created
    ]
    defstruct [
      :platform,
      :guard,
      :lifecycle,
      :workspace,
      :execution_context,
      :workspace_attestation,
      :namespace_attestation,
      :namespace_path,
      :identities,
      :created
    ]

    @opaque t :: %__MODULE__{
              platform: :windows | :posix,
              guard: WindowsCapability.t() | nil,
              lifecycle: :atomics.atomics_ref(),
              workspace: Path.t(),
              execution_context: ProjectExecutionContext.t(),
              workspace_attestation: map(),
              namespace_attestation: map(),
              namespace_path: Path.t(),
              identities: map(),
              created: :helper | [{Path.t(), map()}]
            }
  end

  defmodule PrivateHomeOperation do
    @moduledoc false
    defstruct [
      :workspace,
      :execution_context,
      :workspace_attestation,
      :namespace_attestation,
      :namespace_path,
      :canonical_root,
      :root_identity,
      :opts
    ]
  end

  @type worker_host :: String.t() | nil
  @type preparation :: %{
          path: Path.t(),
          created_now: boolean(),
          workspace_attestation: map() | nil,
          private_home_capability: PrivateHomeCapability.t() | nil,
          readiness_state: ReadinessState.t()
        }

  @spec create_for_issue(
          map() | String.t() | nil,
          worker_host(),
          ProjectExecutionContext.t() | nil
        ) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil, execution_context \\ nil) do
    case prepare_for_issue(issue_or_identifier, worker_host, execution_context, []) do
      {:ok, %{path: workspace}} -> {:ok, workspace}
      {:error, _reason} = error -> error
    end
  end

  @spec prepare_for_issue(
          map() | String.t() | nil,
          worker_host(),
          ProjectExecutionContext.t() | nil
        ) ::
          {:ok, preparation()} | {:error, term()}
  def prepare_for_issue(issue_or_identifier, worker_host \\ nil, execution_context \\ nil) do
    prepare_for_issue(issue_or_identifier, worker_host, execution_context, [])
  end

  @spec prepare_for_issue(
          map() | String.t() | nil,
          worker_host(),
          ProjectExecutionContext.t() | nil,
          keyword()
        ) ::
          {:ok, preparation()} | {:error, term()}
  def prepare_for_issue(issue_or_identifier, worker_host, execution_context, opts)
      when is_list(opts) do
    issue_context = issue_context(issue_or_identifier, execution_context)

    try do
      with :ok <- validate_remote_credential_environment(worker_host, opts),
           :ok <- validate_execution_context(execution_context),
           :ok <- validate_issue_execution_context(issue_context),
           safe_id <- safe_identifier(issue_context.issue_identifier),
           {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host, execution_context),
           :ok <- validate_workspace_path(workspace, worker_host, execution_context),
           {:ok, workspace, created?, workspace_attestation} <-
             ensure_workspace(workspace, worker_host, execution_context),
           workspace_effect_opts = Keyword.put(opts, :workspace_attestation, workspace_attestation),
           :ok <-
             validate_execution_workspace(
               workspace,
               worker_host,
               execution_context,
               workspace_attestation
             ),
           {:ok, private_home_capability} <-
             prepare_context_private_home(
               workspace,
               worker_host,
               execution_context,
               workspace_attestation,
               workspace_effect_opts
             ) do
        finish_preparation_with_private_home(
          workspace,
          issue_context,
          created?,
          worker_host,
          workspace_attestation,
          private_home_capability,
          workspace_effect_opts,
          opts
        )
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp finish_preparation_with_private_home(
         workspace,
         issue_context,
         created?,
         worker_host,
         workspace_attestation,
         private_home_capability,
         workspace_effect_opts,
         opts
       ) do
    effect_opts =
      Keyword.put(
        workspace_effect_opts,
        :private_home_capability,
        private_home_capability
      )

    result =
      with {:ok, readiness_state} <-
             prepare_readiness_state_with_attestation(
               workspace,
               issue_context,
               created?,
               worker_host,
               workspace_attestation,
               private_home_capability,
               opts
             ),
           :ok <-
             maybe_run_after_create_hook(
               workspace,
               issue_context,
               created?,
               worker_host,
               effect_opts
             ) do
        {:ok,
         %{
           path: workspace,
           created_now: created?,
           workspace_attestation: workspace_attestation,
           private_home_capability: private_home_capability,
           readiness_state: readiness_state
         }}
      end

    case result do
      {:ok, _preparation} = success ->
        success

      {:error, {:attested_preparation_error, _reason, _workspace, _attestation, ^private_home_capability}} = error ->
        error

      {:error, _reason} = error ->
        rollback_failed_private_home_preparation(private_home_capability, error)
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
        %{path: workspace, readiness_state: %ReadinessState{} = expected_state} = preparation,
        issue_or_identifier,
        receipt,
        worker_host,
        opts
      )
      when is_binary(workspace) and is_list(opts) do
    issue_context = readiness_issue_context(expected_state, issue_or_identifier)
    workspace_attestation = Map.get(preparation, :workspace_attestation)

    with :ok <- validate_remote_credential_environment(worker_host, opts),
         :ok <-
           validate_execution_workspace(
             workspace,
             worker_host,
             Keyword.get(opts, :execution_context),
             workspace_attestation
           ),
         :ok <- validate_readiness_identity(expected_state, workspace, issue_context),
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
        prepare_missing_readiness_state(workspace, issue_context, worker_host)

      {:ok, %ReadinessState{} = state} ->
        reconcile_persisted_readiness_state(state, workspace, issue_context, worker_host)

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_missing_readiness_state(workspace, issue_context, worker_host) do
    if context_aware?(issue_context) do
      {:error, :workspace_context_missing}
    else
      state = new_readiness_state(workspace, issue_context, :legacy)

      case write_readiness_state(workspace, state, worker_host) do
        :ok -> {:ok, state}
        {:error, _reason} = error -> error
      end
    end
  end

  defp reconcile_persisted_readiness_state(state, workspace, issue_context, worker_host) do
    case reconcile_readiness_identity(state, workspace, issue_context) do
      {:ok, ^state} -> {:ok, state}
      {:ok, enriched_state} -> persist_enriched_readiness_state(workspace, enriched_state, worker_host)
      {:error, _reason} = error -> error
    end
  end

  defp prepare_readiness_state_with_attestation(
         workspace,
         issue_context,
         created?,
         worker_host,
         workspace_attestation,
         private_home_capability,
         opts
       ) do
    case prepare_readiness_state(workspace, issue_context, created?, worker_host) do
      {:error, reason} when is_map(workspace_attestation) ->
        if Keyword.get(opts, :attest_preparation_errors, false) do
          {:error, {:attested_preparation_error, reason, workspace, workspace_attestation, private_home_capability}}
        else
          {:error, reason}
        end

      result ->
        result
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
      profile_key: issue_context.profile_key,
      linear_project_id: issue_context.linear_project_id,
      repository: issue_context.repository,
      canonical_branch: issue_context.canonical_branch,
      workspace_namespace: issue_context.workspace_namespace,
      credential_ref: issue_context.credential_ref,
      workspace_path: workspace,
      verified_head_sha: nil
    }
  end

  defp validate_readiness_identity(%ReadinessState{} = state, workspace, issue_context) do
    expected = %{
      issue_id: issue_context.issue_id,
      issue_identifier: issue_context.issue_identifier,
      issue_branch: issue_context.issue_branch,
      profile_key: issue_context.profile_key,
      linear_project_id: issue_context.linear_project_id,
      repository: issue_context.repository,
      canonical_branch: issue_context.canonical_branch,
      workspace_namespace: issue_context.workspace_namespace,
      credential_ref: issue_context.credential_ref,
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
    cond do
      context_aware?(issue_context) and readiness_context_missing?(state) ->
        {:error, :workspace_context_missing}

      context_aware?(issue_context) ->
        validated_readiness_state(state, workspace, issue_context)

      true ->
        validated_or_enriched_readiness_state(state, workspace, issue_context)
    end
  end

  defp validated_readiness_state(state, workspace, issue_context) do
    case validate_readiness_identity(state, workspace, issue_context) do
      :ok -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  defp validated_or_enriched_readiness_state(state, workspace, issue_context) do
    case validate_readiness_identity(state, workspace, issue_context) do
      :ok -> {:ok, state}
      {:error, _reason} = error -> maybe_enrich_readiness_state(error, state, workspace, issue_context)
    end
  end

  defp maybe_enrich_readiness_state(error, state, workspace, issue_context) do
    if readiness_identity_enrichable?(state, workspace, issue_context) do
      {:ok, %{state | issue_id: issue_context.issue_id, issue_branch: issue_context.issue_branch}}
    else
      error
    end
  end

  defp context_aware?(%{execution_context: %ProjectExecutionContext{}}), do: true
  defp context_aware?(_issue_context), do: false

  defp readiness_context_missing?(state) do
    Enum.any?(
      [
        state.profile_key,
        state.linear_project_id,
        state.repository,
        state.canonical_branch,
        state.workspace_namespace,
        state.credential_ref
      ],
      &is_nil/1
    )
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
        nil -> fn args -> run_git_command(workspace, args, worker_host, opts) end
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
         "provenance" => _,
         "phase" => _,
         "issue_id" => _,
         "issue_identifier" => _,
         "issue_branch" => _,
         "profile_key" => _,
         "linear_project_id" => _,
         "repository" => _,
         "canonical_branch" => _,
         "workspace_namespace" => _,
         "credential_ref" => _,
         "workspace_path" => _,
         "verified_head_sha" => _
       } = decoded}
      when map_size(decoded) == 14 ->
        build_readiness_state(workspace, decoded)

      {:ok,
       %{
         "version" => @readiness_state_version,
         "provenance" => _,
         "phase" => _,
         "issue_id" => _,
         "issue_identifier" => _,
         "issue_branch" => _,
         "workspace_path" => _,
         "verified_head_sha" => _
       } = decoded}
      when map_size(decoded) == 8 ->
        build_readiness_state(workspace, decoded)

      {:ok, _decoded} ->
        {:error, {:workspace_readiness_state_invalid, workspace, "readiness state JSON has an unsupported schema"}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:workspace_readiness_state_invalid, workspace, "readiness state JSON is malformed: #{Exception.message(error)}"}}
    end
  end

  defp build_readiness_state(workspace, decoded) do
    provenance = decoded["provenance"]
    phase = decoded["phase"]
    issue_id = decoded["issue_id"]
    issue_identifier = decoded["issue_identifier"]
    issue_branch = decoded["issue_branch"]
    profile_key = decoded["profile_key"]
    linear_project_id = decoded["linear_project_id"]
    repository = decoded["repository"]
    canonical_branch = decoded["canonical_branch"]
    workspace_namespace = decoded["workspace_namespace"]
    credential_ref = decoded["credential_ref"]
    workspace_path = decoded["workspace_path"]
    verified_head_sha = decoded["verified_head_sha"]

    with {:ok, provenance_atom} <- parse_readiness_provenance(provenance),
         {:ok, phase_atom} <- parse_readiness_phase(phase, verified_head_sha),
         true <- is_nil(issue_id) or is_binary(issue_id),
         true <- is_binary(issue_identifier) and issue_identifier != "",
         true <- is_nil(issue_branch) or is_binary(issue_branch),
         true <-
           valid_readiness_context?(
             profile_key,
             linear_project_id,
             repository,
             canonical_branch,
             workspace_namespace,
             credential_ref
           ),
         true <- is_binary(workspace_path) and workspace_path != "" do
      {:ok,
       %ReadinessState{
         version: @readiness_state_version,
         provenance: provenance_atom,
         phase: phase_atom,
         issue_id: issue_id,
         issue_identifier: issue_identifier,
         issue_branch: issue_branch,
         profile_key: profile_key,
         linear_project_id: linear_project_id,
         repository: repository,
         canonical_branch: canonical_branch,
         workspace_namespace: workspace_namespace,
         credential_ref: credential_ref,
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

  defp valid_readiness_context?(profile_key, linear_project_id, repository, canonical_branch, workspace_namespace, credential_ref) do
    fields = [profile_key, linear_project_id, repository, canonical_branch, workspace_namespace, credential_ref]
    Enum.all?(fields, &is_nil/1) or Enum.all?(fields, &non_empty_binary?/1)
  end

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
      "profile_key" => state.profile_key,
      "linear_project_id" => state.linear_project_id,
      "repository" => state.repository,
      "canonical_branch" => state.canonical_branch,
      "workspace_namespace" => state.workspace_namespace,
      "credential_ref" => state.credential_ref,
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

  defp prepare_context_private_home(
         _workspace,
         _worker_host,
         nil,
         _workspace_attestation,
         _opts
       ),
       do: {:ok, nil}

  defp prepare_context_private_home(
         _workspace,
         worker_host,
         %ProjectExecutionContext{},
         _workspace_attestation,
         _opts
       )
       when is_binary(worker_host),
       do: {:ok, nil}

  defp prepare_context_private_home(
         workspace,
         nil,
         %ProjectExecutionContext{} = execution_context,
         workspace_attestation,
         opts
       ) do
    case Keyword.fetch(opts, :subprocess_home_paths) do
      {:ok, paths} ->
        case validate_private_home_contract(paths, execution_context, opts) do
          :ok ->
            prepare_validated_context_private_home(
              workspace,
              execution_context,
              workspace_attestation,
              paths,
              opts
            )

          {:error, _reason} ->
            {:error, :subprocess_home_unavailable}
        end

      :error ->
        if private_home_environment_present?(opts) do
          {:error, :subprocess_home_unavailable}
        else
          {:ok, nil}
        end
    end
  rescue
    _error -> {:error, :subprocess_home_unavailable}
  catch
    _kind, _reason -> {:error, :subprocess_home_unavailable}
  end

  defp prepare_validated_context_private_home(workspace, execution_context, attestation, paths, opts) do
    case create_context_private_home(workspace, execution_context, attestation, paths, opts) do
      {:ok, %PrivateHomeCapability{} = capability} -> {:ok, capability}
      {:error, :private_home_rollback_failed} -> {:error, :subprocess_home_rollback_failed}
      _failure -> {:error, :subprocess_home_unavailable}
    end
  end

  defp validate_private_home_contract(paths, execution_context, opts) when is_map(paths) do
    expected_paths = SubprocessEnvironment.private_home_paths(execution_context)
    environment = Keyword.get(opts, :env)

    valid_environment? =
      is_map(environment) and
        Enum.all?(@private_home_environment_keys, fn {environment_key, path_key} ->
          Map.get(environment, environment_key) == Map.fetch!(expected_paths, path_key)
        end)

    if paths == expected_paths and valid_environment?, do: :ok, else: {:error, :invalid_contract}
  end

  defp validate_private_home_contract(_paths, _execution_context, _opts),
    do: {:error, :invalid_contract}

  defp private_home_environment_present?(opts) do
    case Keyword.get(opts, :env) do
      environment when is_map(environment) ->
        Enum.any?(@private_home_environment_keys, fn {key, _path_key} ->
          Map.has_key?(environment, key)
        end)

      _other ->
        false
    end
  end

  defp create_context_private_home(
         workspace,
         execution_context,
         workspace_attestation,
         paths,
         opts
       ) do
    expanded_root = Path.expand(Config.settings!().workspace.root)
    namespace_path = Path.join(expanded_root, execution_context.workspace_namespace)
    component_paths = Enum.map(@private_home_path_keys, &Map.fetch!(paths, &1))

    with :ok <-
           validate_execution_workspace(
             workspace,
             nil,
             execution_context,
             workspace_attestation
           ),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root),
         true <- local_paths_equal?(canonical_root, expanded_root),
         :ok <- validate_non_reparse_directory(canonical_root),
         {:ok, root_identity} <- local_file_identity(canonical_root),
         true <- local_paths_equal?(Path.dirname(paths.root), namespace_path),
         true <- strict_local_descendant?(paths.root, namespace_path),
         :ok <- validate_non_reparse_directory(namespace_path),
         {:ok, namespace_attestation} <- local_workspace_attestation(namespace_path),
         true <- local_paths_equal?(namespace_attestation.path, namespace_path),
         :ok <- validate_private_component_locations(component_paths, namespace_path),
         {:ok, existing_identities} <-
           preflight_private_home_components(component_paths, namespace_path),
         operation = %PrivateHomeOperation{
           workspace: workspace,
           execution_context: execution_context,
           workspace_attestation: workspace_attestation,
           namespace_attestation: namespace_attestation,
           namespace_path: namespace_path,
           canonical_root: canonical_root,
           root_identity: root_identity,
           opts: opts
         },
         {:ok, %PrivateHomeCapability{} = capability} <-
           create_private_home_components(operation, component_paths, existing_identities) do
      {:ok, capability}
    else
      {:error, :private_home_rollback_failed} = error -> error
      _failure -> {:error, :unsafe_private_home}
    end
  end

  defp validate_private_component_locations(component_paths, namespace_path) do
    Enum.reduce_while(component_paths, :ok, fn path, :ok ->
      case validate_private_component_location(path, namespace_path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_private_component_location(path, namespace_path) when is_binary(path) do
    expanded_path = Path.expand(path)

    with true <- strict_local_descendant?(expanded_path, namespace_path),
         {:ok, canonical_path} <- PathSafety.canonicalize(expanded_path),
         true <- local_paths_equal?(canonical_path, expanded_path),
         true <- strict_local_descendant?(canonical_path, namespace_path) do
      :ok
    else
      _failure -> {:error, :unsafe_private_home_path}
    end
  end

  defp validate_private_component_location(_path, _namespace_path),
    do: {:error, :unsafe_private_home_path}

  defp preflight_private_home_components(component_paths, namespace_path) do
    Enum.reduce_while(component_paths, {:ok, %{}}, fn path, {:ok, identities} ->
      preflight_private_home_component(path, identities, namespace_path)
    end)
  end

  defp preflight_private_home_component(path, identities, namespace_path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:cont, {:ok, identities}}
      {:ok, _stat} -> preflight_existing_private_home_component(path, identities, namespace_path)
      {:error, _reason} -> {:halt, {:error, :unsafe_private_home_path}}
    end
  end

  defp preflight_existing_private_home_component(path, identities, namespace_path) do
    with {:ok, identity} <- safe_private_directory_identity(path, namespace_path),
         :ok <- validate_existing_private_permissions(path) do
      {:cont, {:ok, Map.put(identities, path, identity)}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp create_private_home_components(operation, component_paths, existing_identities) do
    case :os.type() do
      {:win32, _name} ->
        create_windows_private_home_components(operation, component_paths, existing_identities)

      {:unix, _name} ->
        create_posix_private_home_components(operation, component_paths, existing_identities)
    end
  end

  defp create_windows_private_home_components(operation, component_paths, existing_identities) do
    anchors = [
      {operation.canonical_root, windows_identity(operation.root_identity)},
      {operation.namespace_path, windows_identity(operation.namespace_attestation.identity)},
      {operation.workspace, windows_identity(operation.workspace_attestation.identity)}
    ]

    components =
      Enum.map(component_paths, fn path ->
        {path, existing_identities |> Map.get(path) |> windows_identity()}
      end)

    case WindowsCapability.open(
           anchors,
           components,
           fail_commit: Keyword.get(operation.opts, :private_home_commit_failure, false)
         ) do
      {:ok, capability} ->
        finish_windows_private_home_creation(operation, capability, component_paths, existing_identities)

      {:error, _reason} = error ->
        error
    end
  end

  defp finish_windows_private_home_creation(operation, capability, component_paths, identities) do
    case ensure_windows_private_home_components(operation, capability, component_paths, identities) do
      {:ok, updated_identities} ->
        finish_validated_windows_private_home(operation, capability, updated_identities)

      {:error, _reason} ->
        rollback_windows_private_home(capability)
    end
  end

  defp finish_validated_windows_private_home(operation, capability, identities) do
    case validate_private_home_state(operation, identities) do
      :ok -> {:ok, windows_private_home_capability(operation, capability, identities)}
      _failure -> rollback_windows_private_home(capability)
    end
  end

  defp windows_private_home_capability(operation, capability, identities) do
    %PrivateHomeCapability{
      platform: :windows,
      guard: capability,
      lifecycle: private_home_lifecycle(),
      workspace: operation.workspace,
      execution_context: operation.execution_context,
      workspace_attestation: operation.workspace_attestation,
      namespace_attestation: operation.namespace_attestation,
      namespace_path: operation.namespace_path,
      identities: identities,
      created: :helper
    }
  end

  defp ensure_windows_private_home_components(
         operation,
         capability,
         component_paths,
         existing_identities
       ) do
    Enum.reduce_while(component_paths, {:ok, existing_identities}, fn path, {:ok, identities} ->
      state =
        validate_private_home_state(
          operation.workspace,
          operation.execution_context,
          operation.workspace_attestation,
          operation.namespace_attestation,
          operation.namespace_path,
          identities
        )

      cond do
        state != :ok ->
          {:halt, {:error, :private_home_identity_changed}}

        Map.has_key?(identities, path) ->
          {:cont, {:ok, identities}}

        true ->
          ensure_windows_private_home_component(operation, capability, path, identities)
      end
    end)
  end

  defp ensure_windows_private_home_component(operation, capability, path, identities) do
    with :ok <- invoke_private_home_creation_seam(path, operation.opts),
         :ok <- validate_private_home_state(operation, identities),
         {:ok, file_id} <-
           WindowsCapability.ensure_component(
             capability,
             path,
             permission_failure_injected?(path, operation.opts)
           ),
         updated_identities =
           Map.put(identities, path, %{type: :directory, windows_file_id: file_id}),
         :ok <- invoke_private_home_post_creation_seam(path, operation.opts),
         :ok <- validate_private_home_state(operation, updated_identities) do
      {:cont, {:ok, updated_identities}}
    else
      _failure -> {:halt, {:error, :private_home_create_failed}}
    end
  end

  defp rollback_windows_private_home(capability) do
    case WindowsCapability.rollback(capability) do
      :ok -> {:error, :private_home_create_failed}
      {:error, :private_home_capability_failed} -> {:error, :private_home_rollback_failed}
    end
  end

  defp rollback_failed_private_home_preparation(private_home_capability, original_error) do
    case rollback_private_home_capability(private_home_capability) do
      :ok -> original_error
      {:error, :subprocess_home_rollback_failed} = rollback_error -> rollback_error
    end
  end

  defp rollback_private_home_capability(nil), do: :ok

  defp rollback_private_home_capability(%PrivateHomeCapability{
         platform: :windows,
         guard: guard,
         lifecycle: lifecycle
       }) do
    case WindowsCapability.rollback(guard) do
      :ok -> :ok
      {:error, :private_home_capability_failed} -> {:error, :subprocess_home_rollback_failed}
    end
  after
    :atomics.put(lifecycle, 1, 1)
  end

  defp rollback_private_home_capability(%PrivateHomeCapability{
         platform: :posix,
         lifecycle: lifecycle,
         created: created,
         namespace_path: namespace_path
       }) do
    case rollback_posix_private_home(created, namespace_path) do
      :ok -> :ok
      {:error, :private_home_rollback_failed} -> {:error, :subprocess_home_rollback_failed}
    end
  after
    :atomics.put(lifecycle, 1, 1)
  end

  defp private_home_lifecycle, do: :atomics.new(1, signed: false)

  defp create_posix_private_home_components(operation, component_paths, existing_identities) do
    result =
      Enum.reduce_while(
        component_paths,
        {:ok, existing_identities, []},
        fn path, {:ok, identities, created} ->
          state =
            validate_private_home_state(
              operation.workspace,
              operation.execution_context,
              operation.workspace_attestation,
              operation.namespace_attestation,
              operation.namespace_path,
              identities
            )

          cond do
            state != :ok ->
              {:halt, {:error, :private_home_identity_changed, created}}

            Map.has_key?(identities, path) ->
              {:cont, {:ok, identities, created}}

            true ->
              create_posix_private_home_component(operation, path, identities, created)
          end
        end
      )

    case result do
      {:ok, identities, created} ->
        {:ok,
         %PrivateHomeCapability{
           platform: :posix,
           guard: nil,
           lifecycle: private_home_lifecycle(),
           workspace: operation.workspace,
           execution_context: operation.execution_context,
           workspace_attestation: operation.workspace_attestation,
           namespace_attestation: operation.namespace_attestation,
           namespace_path: operation.namespace_path,
           identities: identities,
           created: created
         }}

      {:error, failure_reason, created} ->
        rollback_result = rollback_posix_private_home(created, operation.namespace_path)

        if failure_reason == :private_home_rollback_failed or rollback_result != :ok do
          {:error, :private_home_rollback_failed}
        else
          {:error, :private_home_create_failed}
        end
    end
  end

  defp create_posix_private_home_component(operation, path, identities, created) do
    with :ok <- invoke_private_home_creation_seam(path, operation.opts),
         :ok <-
           validate_private_home_state(
             operation.workspace,
             operation.execution_context,
             operation.workspace_attestation,
             operation.namespace_attestation,
             operation.namespace_path,
             identities
           ) do
      case posix_mkdir_and_track(
             path,
             created,
             &File.mkdir/1,
             &safe_private_directory_identity(&1, operation.namespace_path)
           ) do
        {:ok, identity, updated_created} ->
          finish_posix_private_home_component(
            operation,
            path,
            identity,
            identities,
            updated_created
          )

        {:error, reason, unchanged_created} ->
          {:halt, {:error, reason, unchanged_created}}
      end
    else
      _failure -> {:halt, {:error, :private_home_create_failed, created}}
    end
  end

  defp finish_posix_private_home_component(operation, path, identity, identities, created) do
    with false <- permission_failure_injected?(path, operation.opts),
         :ok <- File.chmod(path, 0o700),
         :ok <- validate_existing_private_permissions(path),
         updated_identities = Map.put(identities, path, identity),
         :ok <- invoke_private_home_post_creation_seam(path, operation.opts),
         :ok <- validate_private_home_state(operation, updated_identities) do
      {:cont, {:ok, updated_identities, created}}
    else
      _failure -> {:halt, {:error, :private_home_create_failed, created}}
    end
  end

  defp rollback_posix_private_home(created, namespace_path) do
    rollback_posix_created(
      created,
      &safe_private_directory_identity(&1, namespace_path),
      &File.rmdir/1
    )
  end

  defp posix_mkdir_and_track(path, created, mkdir, identity_reader)
       when is_binary(path) and is_list(created) and is_function(mkdir, 1) and
              is_function(identity_reader, 1) do
    mkdir_result =
      try do
        mkdir.(path)
      rescue
        _error -> {:error, :private_home_create_failed}
      catch
        _kind, _reason -> {:error, :private_home_create_failed}
      end

    case mkdir_result do
      :ok ->
        capture_posix_created_identity(path, created, identity_reader)

      {:error, _reason} ->
        {:error, :private_home_create_failed, created}

      _invalid ->
        {:error, :private_home_create_failed, created}
    end
  end

  defp capture_posix_created_identity(path, created, identity_reader) do
    case identity_reader.(path) do
      {:ok, identity} when is_map(identity) ->
        {:ok, identity, [{path, identity} | created]}

      _identity_failure ->
        {:error, :private_home_rollback_failed, created}
    end
  rescue
    _error -> {:error, :private_home_rollback_failed, created}
  catch
    _kind, _reason -> {:error, :private_home_rollback_failed, created}
  end

  @doc false
  @spec posix_mkdir_and_track_for_test(Path.t(), list(), function(), function()) ::
          {:ok, map(), list()}
          | {:error, :private_home_create_failed | :private_home_rollback_failed, list()}
  def posix_mkdir_and_track_for_test(path, created, mkdir, identity_reader),
    do: posix_mkdir_and_track(path, created, mkdir, identity_reader)

  defp rollback_posix_created(created, identity_reader, remove_directory)
       when is_list(created) and is_function(identity_reader, 1) and
              is_function(remove_directory, 1) do
    result =
      Enum.reduce(created, :ok, fn {path, expected_identity}, accumulated_result ->
        removal_result =
          try do
            with {:ok, ^expected_identity} <- identity_reader.(path),
                 :ok <- remove_directory.(path) do
              :ok
            else
              _failure -> {:error, :private_home_rollback_failed}
            end
          rescue
            _error -> {:error, :private_home_rollback_failed}
          catch
            _kind, _reason -> {:error, :private_home_rollback_failed}
          end

        if accumulated_result == :ok and removal_result == :ok,
          do: :ok,
          else: {:error, :private_home_rollback_failed}
      end)

    result
  end

  @doc false
  @spec rollback_posix_private_home_for_test(list(), function(), function()) ::
          :ok | {:error, :private_home_rollback_failed}
  def rollback_posix_private_home_for_test(created, identity_reader, remove_directory),
    do: rollback_posix_created(created, identity_reader, remove_directory)

  defp windows_identity(nil), do: nil
  defp windows_identity(%{windows_file_id: identity}) when is_binary(identity), do: identity
  defp windows_identity(_invalid), do: nil

  defp permission_failure_injected?(path, opts),
    do: Keyword.get(opts, :private_home_permission_failure) == path

  defp invoke_private_home_creation_seam(path, opts) do
    case Keyword.get(opts, :private_home_before_create) do
      nil ->
        :ok

      callback when is_function(callback, 1) ->
        case callback.(path) do
          :ok -> :ok
          _other -> {:error, :private_home_create_failed}
        end

      _invalid ->
        {:error, :private_home_create_failed}
    end
  rescue
    _error -> {:error, :private_home_create_failed}
  catch
    _kind, _reason -> {:error, :private_home_create_failed}
  end

  defp invoke_private_home_post_creation_seam(path, opts) do
    case Keyword.get(opts, :private_home_after_create) do
      nil ->
        :ok

      callback when is_function(callback, 1) ->
        case callback.(path) do
          :ok -> :ok
          _other -> {:error, :private_home_create_failed}
        end

      _invalid ->
        {:error, :private_home_create_failed}
    end
  rescue
    _error -> {:error, :private_home_create_failed}
  catch
    _kind, _reason -> {:error, :private_home_create_failed}
  end

  @spec finalize_private_home_capability(PrivateHomeCapability.t() | nil) ::
          :ok | {:error, :subprocess_home_finalize_failed}
  def finalize_private_home_capability(nil), do: :ok

  def finalize_private_home_capability(
        %PrivateHomeCapability{
          platform: :windows,
          guard: guard,
          lifecycle: lifecycle
        } = capability
      ) do
    with :ok <- validate_platform_private_home_capability(:windows, capability),
         :ok <- WindowsCapability.commit(guard) do
      :ok
    else
      _failure -> {:error, :subprocess_home_finalize_failed}
    end
  after
    :atomics.put(lifecycle, 1, 1)
  end

  def finalize_private_home_capability(%PrivateHomeCapability{
        platform: :posix,
        lifecycle: lifecycle,
        workspace: workspace,
        execution_context: execution_context,
        workspace_attestation: workspace_attestation,
        namespace_attestation: namespace_attestation,
        namespace_path: namespace_path,
        identities: identities
      }) do
    case validate_private_home_state(
           workspace,
           execution_context,
           workspace_attestation,
           namespace_attestation,
           namespace_path,
           identities
         ) do
      :ok -> :ok
      {:error, _reason} -> {:error, :subprocess_home_finalize_failed}
    end
  after
    :atomics.put(lifecycle, 1, 1)
  end

  @spec validate_private_home_effect(
          Path.t(),
          worker_host(),
          ProjectExecutionContext.t() | nil,
          map() | nil,
          keyword()
        ) :: :ok | {:error, :subprocess_home_unavailable}
  def validate_private_home_effect(
        _workspace,
        worker_host,
        _execution_context,
        _workspace_attestation,
        _opts
      )
      when is_binary(worker_host),
      do: :ok

  def validate_private_home_effect(
        workspace,
        nil,
        %ProjectExecutionContext{} = execution_context,
        workspace_attestation,
        opts
      )
      when is_binary(workspace) and is_list(opts) do
    capability = Keyword.get(opts, :private_home_capability)

    if is_nil(capability) and not private_home_environment_present?(opts) do
      :ok
    else
      validate_private_home_capability(
        capability,
        workspace,
        execution_context,
        workspace_attestation
      )
    end
  end

  def validate_private_home_effect(
        _workspace,
        nil,
        nil,
        _workspace_attestation,
        _opts
      ),
      do: :ok

  def validate_private_home_effect(
        _workspace,
        _worker_host,
        _execution_context,
        _workspace_attestation,
        _opts
      ),
      do: {:error, :subprocess_home_unavailable}

  defp validate_private_home_capability(
         %PrivateHomeCapability{
           platform: platform,
           lifecycle: lifecycle,
           workspace: expected_workspace,
           execution_context: expected_context,
           workspace_attestation: expected_workspace_attestation
         } = capability,
         workspace,
         execution_context,
         workspace_attestation
       ) do
    with 0 <- :atomics.get(lifecycle, 1),
         true <- local_paths_equal?(expected_workspace, workspace),
         true <- expected_context == execution_context,
         true <- expected_workspace_attestation == workspace_attestation,
         :ok <- validate_platform_private_home_capability(platform, capability) do
      :ok
    else
      _failure -> {:error, :subprocess_home_unavailable}
    end
  rescue
    _error -> {:error, :subprocess_home_unavailable}
  catch
    _kind, _reason -> {:error, :subprocess_home_unavailable}
  end

  defp validate_private_home_capability(
         _capability,
         _workspace,
         _execution_context,
         _workspace_attestation
       ),
       do: {:error, :subprocess_home_unavailable}

  defp validate_platform_private_home_capability(
         :windows,
         %PrivateHomeCapability{
           guard: guard,
           workspace: workspace,
           execution_context: execution_context,
           workspace_attestation: workspace_attestation,
           namespace_attestation: namespace_attestation,
           namespace_path: namespace_path,
           identities: identities
         }
       ) do
    validate_private_home_state(
      workspace,
      execution_context,
      workspace_attestation,
      namespace_attestation,
      namespace_path,
      identities
    )
    |> case do
      :ok -> WindowsCapability.verify(guard)
      {:error, _reason} = error -> error
    end
  end

  defp validate_platform_private_home_capability(
         :posix,
         %PrivateHomeCapability{
           workspace: workspace,
           execution_context: execution_context,
           workspace_attestation: workspace_attestation,
           namespace_attestation: namespace_attestation,
           namespace_path: namespace_path,
           identities: identities
         }
       ) do
    validate_private_home_state(
      workspace,
      execution_context,
      workspace_attestation,
      namespace_attestation,
      namespace_path,
      identities
    )
  end

  @doc false
  @spec private_home_capability_active_for_test?(PrivateHomeCapability.t() | nil) :: boolean()
  def private_home_capability_active_for_test?(nil), do: false

  def private_home_capability_active_for_test?(%PrivateHomeCapability{
        platform: :windows,
        guard: guard,
        lifecycle: lifecycle
      }) do
    :atomics.get(lifecycle, 1) == 0 and WindowsCapability.active_for_test?(guard)
  end

  def private_home_capability_active_for_test?(%PrivateHomeCapability{lifecycle: lifecycle}) do
    :atomics.get(lifecycle, 1) == 0
  end

  defp validate_private_home_state(
         workspace,
         execution_context,
         workspace_attestation,
         namespace_attestation,
         namespace_path,
         identities
       ) do
    with :ok <- validate_execution_workspace(workspace, nil, execution_context, workspace_attestation),
         :ok <- validate_workspace_attestation(namespace_path, nil, namespace_attestation),
         :ok <- validate_private_home_identities(identities, namespace_path) do
      validate_private_permissions(identities)
    end
  end

  defp validate_private_home_state(%PrivateHomeOperation{} = operation, identities) do
    validate_private_home_state(
      operation.workspace,
      operation.execution_context,
      operation.workspace_attestation,
      operation.namespace_attestation,
      operation.namespace_path,
      identities
    )
  end

  defp validate_private_home_identities(identities, namespace_path) do
    Enum.reduce_while(identities, :ok, fn {path, expected_identity}, :ok ->
      case safe_private_directory_identity(path, namespace_path) do
        {:ok, ^expected_identity} -> {:cont, :ok}
        _changed_or_unsafe -> {:halt, {:error, :private_home_identity_changed}}
      end
    end)
  end

  defp safe_private_directory_identity(path, namespace_path) do
    with :ok <- validate_private_component_location(path, namespace_path),
         :ok <- validate_non_reparse_directory(path),
         {:ok, identity} <- private_directory_identity(path) do
      {:ok, identity}
    else
      _failure -> {:error, :unsafe_private_home_path}
    end
  end

  defp private_directory_identity(path) do
    case :os.type() do
      {:unix, _name} -> posix_private_file_identity(path)
      {:win32, _name} -> windows_directory_identity(path)
    end
  end

  defp validate_non_reparse_directory(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         :ok <- validate_platform_reparse_state(path) do
      :ok
    else
      _failure -> {:error, :unsafe_private_home_path}
    end
  end

  defp validate_platform_reparse_state(path) do
    case :os.type() do
      {:unix, _name} -> :ok
      {:win32, _name} -> validate_windows_reparse_state(path)
    end
  end

  defp validate_windows_reparse_state(path) do
    with system_root when is_binary(system_root) and system_root != "" <-
           System.get_env("SystemRoot") || System.get_env("SYSTEMROOT"),
         executable = Path.join([system_root, "System32", "fsutil.exe"]),
         true <- File.regular?(executable),
         {output, status} <-
           System.cmd(executable, ["reparsepoint", "query", Path.expand(path)], stderr_to_stdout: true) do
      classify_windows_reparse_query(output, status)
    else
      _failure -> {:error, :unsafe_private_home_path}
    end
  end

  @doc false
  @spec classify_windows_reparse_query_for_test(binary(), integer()) ::
          :ok | {:error, :unsafe_private_home_path}
  def classify_windows_reparse_query_for_test(output, status),
    do: classify_windows_reparse_query(output, status)

  defp classify_windows_reparse_query(output, 1) when is_binary(output) do
    if Regex.match?(~r/\AError\s+4390\s*:[^\r\n]*\z/i, String.trim(output)) do
      :ok
    else
      {:error, :unsafe_private_home_path}
    end
  end

  defp classify_windows_reparse_query(_output, _status),
    do: {:error, :unsafe_private_home_path}

  defp validate_existing_private_permissions(path) do
    case :os.type() do
      {:unix, _name} ->
        with {:ok, effective_uid} <- posix_effective_uid(),
             {:ok, stat} <- File.stat(path, time: :posix) do
          validate_posix_private_permissions(stat, effective_uid)
        else
          _failure -> {:error, :private_home_permissions_failed}
        end

      {:win32, _name} ->
        # Existing Windows ACLs are checked while the helper retains the exact handle.
        :ok
    end
  end

  defp validate_private_permissions(identities) when is_map(identities) do
    case :os.type() do
      {:win32, _name} ->
        :ok

      {:unix, _name} ->
        Enum.reduce_while(Map.keys(identities), :ok, &validate_private_permission/2)
    end
  end

  defp validate_private_permission(path, :ok) do
    case validate_existing_private_permissions(path) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  @doc false
  @spec validate_posix_private_permissions_for_test(File.Stat.t(), non_neg_integer()) ::
          :ok | {:error, :private_home_permissions_failed}
  def validate_posix_private_permissions_for_test(stat, effective_uid),
    do: validate_posix_private_permissions(stat, effective_uid)

  defp validate_posix_private_permissions(
         %File.Stat{type: :directory, mode: mode, uid: effective_uid},
         effective_uid
       )
       when is_integer(effective_uid) and effective_uid >= 0 do
    if Bitwise.band(mode, 0o777) == 0o700,
      do: :ok,
      else: {:error, :private_home_permissions_failed}
  end

  defp validate_posix_private_permissions(_stat, _effective_uid),
    do: {:error, :private_home_permissions_failed}

  defp posix_effective_uid do
    with {:ok, executable} <- trusted_posix_executable("id"),
         {output, 0} <- System.cmd(executable, ["-u"], stderr_to_stdout: true),
         trimmed = String.trim(output),
         true <- Regex.match?(~r/\A[0-9]{1,10}\z/, trimmed),
         {uid, ""} <- Integer.parse(trimmed),
         true <- uid >= 0 do
      {:ok, uid}
    else
      _failure -> {:error, :private_home_permissions_failed}
    end
  rescue
    _error -> {:error, :private_home_permissions_failed}
  catch
    _kind, _reason -> {:error, :private_home_permissions_failed}
  end

  defp trusted_posix_executable(name) do
    [Path.join("/usr/bin", name), Path.join("/bin", name)]
    |> Enum.find(&File.regular?/1)
    |> case do
      executable when is_binary(executable) -> {:ok, executable}
      nil -> {:error, :private_home_permissions_failed}
    end
  end

  defp strict_local_descendant?(path, parent) when is_binary(path) and is_binary(parent) do
    path_parts = path |> local_path_comparison_key() |> Path.split()
    parent_parts = parent |> local_path_comparison_key() |> Path.split()

    length(path_parts) > length(parent_parts) and
      Enum.take(path_parts, length(parent_parts)) == parent_parts
  end

  defp local_paths_equal?(left, right) when is_binary(left) and is_binary(right) do
    local_path_comparison_key(left) == local_path_comparison_key(right)
  end

  defp local_path_comparison_key(path) do
    normalized = Path.expand(path)

    if match?({:win32, _}, :os.type()), do: String.downcase(normalized), else: normalized
  end

  defp ensure_workspace(workspace, nil, execution_context) do
    cond do
      File.dir?(workspace) ->
        with {:ok, attestation} <- maybe_local_workspace_attestation(workspace, execution_context) do
          {:ok, workspace, false, attestation}
        end

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace, execution_context)

      true ->
        create_workspace(workspace, execution_context)
    end
  end

  defp ensure_workspace(workspace, worker_host, nil) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "workspace_namespace=\"$(dirname \"$workspace\")\"",
        "workspace_root=\"$(dirname \"$workspace_namespace\")\"",
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
        "workspace_physical=\"$(pwd -P)\"",
        "namespace_physical=\"$(cd \"$workspace_namespace\" && pwd -P)\"",
        "root_physical=\"$(cd \"$workspace_root\" && pwd -P)\"",
        "case \"$namespace_physical/\" in \"$root_physical/\"*) ;; *)",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_marker}' 'unsafe-namespace'",
        "  exit 0",
        "esac",
        "case \"$workspace_physical/\" in \"$namespace_physical/\"*) ;; *)",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_marker}' 'unsafe-workspace'",
        "  exit 0",
        "esac",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$workspace_physical\""
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

  defp ensure_workspace(
         workspace,
         worker_host,
         %ProjectExecutionContext{workspace_namespace: namespace}
       )
       when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("workspace_root", Config.settings!().workspace.root),
        remote_shell_assign("workspace_namespace", namespace),
        "if [ ! -d \"$workspace_root\" ]; then mkdir -p \"$workspace_root\"; fi",
        "root_physical=\"$(cd \"$workspace_root\" && pwd -P)\"",
        "expected_namespace=\"$root_physical/$workspace_namespace\"",
        "namespace_path=\"$workspace_root/$workspace_namespace\"",
        "if [ -e \"$namespace_path\" ] && [ ! -d \"$namespace_path\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_marker}' 'unsafe-namespace'",
        "  exit 0",
        "fi",
        "if [ ! -e \"$namespace_path\" ]; then mkdir \"$namespace_path\"; fi",
        "namespace_physical=\"$(cd \"$namespace_path\" && pwd -P)\"",
        "if [ \"$namespace_physical\" != \"$expected_namespace\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_marker}' 'unsafe-namespace'",
        "  exit 0",
        "fi",
        "if [ -L \"$workspace\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_marker}' 'unsafe-workspace'",
        "  exit 0",
        "fi",
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
        "workspace_physical=\"$(cd \"$workspace\" && pwd -P)\"",
        "expected_workspace=\"$namespace_physical/$(basename \"$workspace\")\"",
        "if [ \"$workspace_physical\" != \"$expected_workspace\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_marker}' 'unsafe-workspace'",
        "  exit 0",
        "fi",
        remote_workspace_identity_script(),
        "if ! workspace_identity=\"$(read_workspace_identity \"$workspace\")\"; then",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_marker}' 'unsafe-workspace'",
        "  exit 0",
        "fi",
        "printf '%s\\t%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$workspace_physical\" \"$workspace_identity\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        case parse_remote_workspace_output(output) do
          {:ok, physical_workspace, created?, %{kind: :remote} = attestation} ->
            {:ok, physical_workspace, created?,
             Map.merge(attestation, %{
               lexical_path: workspace,
               physical_path: physical_workspace
             })}

          {:ok, _physical_workspace, _created?, nil} ->
            {:error, {:workspace_prepare_failed, :missing_workspace_identity, output}}

          {:error, _reason} = error ->
            error
        end

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace, execution_context) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    with {:ok, attestation} <- maybe_local_workspace_attestation(workspace, execution_context) do
      {:ok, workspace, true, attestation}
    end
  end

  defp maybe_local_workspace_attestation(_workspace, nil), do: {:ok, nil}

  defp maybe_local_workspace_attestation(
         workspace,
         %ProjectExecutionContext{}
       ),
       do: local_workspace_attestation(workspace)

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
        remote_shell_assign("workspace_root", Config.settings!().workspace.root),
        remote_shell_assign("readiness_state", readiness_state_path(workspace)),
        "if [ ! -d \"$workspace_root\" ]; then exit 0; fi",
        "workspace_parent=\"$(dirname \"$workspace\")\"",
        "workspace_name=\"$(basename \"$workspace\")\"",
        "if [ ! -d \"$workspace_parent\" ]; then exit 0; fi",
        "root_physical=\"$(cd \"$workspace_root\" && pwd -P)\"",
        "parent_physical=\"$(cd \"$workspace_parent\" && pwd -P)\"",
        "workspace_physical=\"$parent_physical/$workspace_name\"",
        "case \"$workspace_physical/\" in \"$root_physical/\"*) ;; *) exit 1 ;; esac",
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

  defp remove_existing_local_workspace(
         workspace,
         state_path,
         execution_context,
         workspace_attestation,
         opts
       ) do
    with :ok <-
           validate_execution_workspace(
             workspace,
             nil,
             execution_context,
             workspace_attestation
           ),
         :ok <-
           run_context_cleanup_hook(
             workspace,
             execution_context,
             workspace_attestation,
             opts
           ) do
      with :ok <-
             validate_execution_workspace(
               workspace,
               nil,
               execution_context,
               workspace_attestation
             ),
           {:ok, removed} <- File.rm_rf(workspace),
           :ok <- remove_local_readiness_state(state_path),
           :ok <- remove_context_private_home(execution_context, opts) do
        {:ok, removed}
      else
        {:error, _file, _reason} = error -> error
        {:error, reason} -> {:error, reason, ""}
      end
    else
      {:error, reason} -> {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  @spec remove_issue_workspaces(term(), worker_host(), ProjectExecutionContext.t() | nil) :: :ok
  def remove_issue_workspaces(identifier, worker_host \\ nil, execution_context \\ nil) do
    remove_issue_workspaces(identifier, worker_host, execution_context, [])
  end

  @spec attest_existing_issue_workspace(
          term(),
          worker_host(),
          ProjectExecutionContext.t()
        ) :: {:ok, map() | nil} | {:error, term()}
  def attest_existing_issue_workspace(
        identifier,
        nil,
        %ProjectExecutionContext{} = execution_context
      )
      when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    with :ok <- validate_execution_context(execution_context),
         :ok <- validate_cleanup_execution_context(identifier, execution_context),
         {:ok, workspace} <- workspace_path_for_issue(safe_id, nil, execution_context) do
      attest_existing_local_workspace(workspace, execution_context)
    end
  end

  def attest_existing_issue_workspace(
        identifier,
        worker_host,
        %ProjectExecutionContext{} = execution_context
      )
      when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    with :ok <- validate_execution_context(execution_context),
         :ok <- validate_cleanup_execution_context(identifier, execution_context),
         {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host, execution_context) do
      attest_existing_remote_workspace(workspace, worker_host, execution_context)
    end
  end

  def attest_existing_issue_workspace(_identifier, _worker_host, _execution_context),
    do: {:error, :workspace_attestation_unavailable}

  defp attest_existing_local_workspace(workspace, execution_context) do
    cond do
      File.dir?(workspace) ->
        with {:ok, attestation} <- local_workspace_attestation(workspace),
             :ok <-
               validate_execution_workspace(
                 workspace,
                 nil,
                 execution_context,
                 attestation
               ) do
          {:ok, attestation}
        end

      File.exists?(workspace) ->
        {:error, :workspace_attestation_unavailable}

      true ->
        local_workspace_absence_attestation(workspace, execution_context)
    end
  end

  defp local_workspace_absence_attestation(
         workspace,
         %ProjectExecutionContext{workspace_namespace: namespace}
       ) do
    namespace_path = Path.join(Path.expand(Config.settings!().workspace.root), namespace)

    with {:error, :enoent} <- File.lstat(workspace),
         {:ok, namespace_attestation} <- local_namespace_attestation(namespace_path) do
      {:ok,
       %{
         kind: :local_absent,
         path: Path.expand(workspace),
         namespace_path: namespace_path,
         namespace_attestation: namespace_attestation
       }}
    else
      _failure -> {:error, :workspace_attestation_unavailable}
    end
  end

  defp local_namespace_attestation(namespace_path) do
    case File.lstat(namespace_path) do
      {:ok, %File.Stat{type: :directory}} -> local_workspace_attestation(namespace_path)
      {:error, :enoent} -> {:ok, :absent}
      _other -> {:error, :workspace_attestation_unavailable}
    end
  end

  defp attest_existing_remote_workspace(workspace, worker_host, execution_context) do
    marker = "SYMPHONY_EXISTING_WORKSPACE"

    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ ! -e \"$workspace\" ]; then printf '%s\\t%s\\n' '#{marker}' 'missing'; exit 0; fi",
        remote_execution_guard(workspace, execution_context),
        remote_workspace_identity_script(),
        "workspace_physical=\"$(pwd -P)\"",
        "workspace_identity=\"$(read_workspace_identity \"$workspace\")\"",
        "printf '%s\\t%s\\t%s\\n' '#{marker}' \"$workspace_physical\" \"$workspace_identity\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_existing_remote_attestation(
          output,
          marker,
          workspace,
          execution_context.workspace_namespace
        )

      {:ok, {_output, _status}} ->
        {:error, :workspace_attestation_unavailable}

      {:error, _reason} ->
        {:error, :workspace_attestation_unavailable}
    end
  end

  defp parse_existing_remote_attestation(output, marker, workspace, namespace) do
    output
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.find_value({:error, :workspace_attestation_unavailable}, fn line ->
      case String.split(line, "\t", parts: 3) do
        [^marker, "missing"] ->
          {:ok,
           %{
             kind: :remote_absent,
             lexical_path: workspace,
             workspace_namespace: namespace
           }}

        [^marker, physical_path, identity] when physical_path != "" and identity != "" ->
          {:ok,
           %{
             kind: :remote,
             lexical_path: workspace,
             physical_path: physical_path,
             identity: identity
           }}

        _other ->
          nil
      end
    end)
  end

  @spec remove_issue_workspaces(
          term(),
          worker_host(),
          ProjectExecutionContext.t() | nil,
          keyword()
        ) :: :ok
  def remove_issue_workspaces(identifier, worker_host, execution_context, opts)
      when is_list(opts) do
    workspace_attestation = Keyword.get(opts, :workspace_attestation)
    exact_worker_host? = Keyword.get(opts, :exact_worker_host, false)

    cond do
      is_binary(identifier) and is_binary(worker_host) ->
        remove_issue_workspace(identifier, worker_host, execution_context, workspace_attestation)

      is_binary(identifier) and is_nil(worker_host) ->
        remove_nil_host_issue_workspaces(
          identifier,
          execution_context,
          workspace_attestation,
          exact_worker_host?
        )

      true ->
        :ok
    end

    :ok
  end

  defp remove_nil_host_issue_workspaces(identifier, execution_context, attestation, true) do
    remove_issue_workspace(identifier, nil, execution_context, attestation)
  end

  defp remove_nil_host_issue_workspaces(identifier, execution_context, attestation, false) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        remove_issue_workspace(identifier, nil, execution_context, attestation)

      worker_hosts ->
        Enum.each(
          worker_hosts,
          &remove_issue_workspace(identifier, &1, execution_context, attestation)
        )
    end
  end

  defp remove_issue_workspace(
         identifier,
         worker_host,
         execution_context,
         workspace_attestation
       ) do
    safe_id = safe_identifier(identifier)

    _ =
      with :ok <- validate_execution_context(execution_context),
           :ok <- validate_cleanup_execution_context(identifier, execution_context),
           :ok <- validate_cleanup_attestation(execution_context, workspace_attestation),
           {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host, execution_context),
           :ok <-
             validate_execution_workspace(
               workspace,
               worker_host,
               execution_context,
               workspace_attestation
             ),
           {:ok, cleanup_opts} <-
             cleanup_effect_opts(worker_host, execution_context, workspace_attestation) do
        remove_issue_workspace_path(
          workspace,
          worker_host,
          execution_context,
          workspace_attestation,
          cleanup_opts
        )
      end

    :ok
  end

  defp validate_cleanup_attestation(nil, nil), do: :ok

  defp validate_cleanup_attestation(%ProjectExecutionContext{}, attestation)
       when is_map(attestation),
       do: :ok

  defp validate_cleanup_attestation(_execution_context, _attestation),
    do: {:error, :workspace_attestation_required}

  defp remove_issue_workspace_path(workspace, nil, nil, nil, _opts), do: remove(workspace, nil)

  defp remove_issue_workspace_path(
         workspace,
         nil,
         execution_context,
         %{kind: :local_absent} = workspace_attestation,
         opts
       ) do
    state_path = readiness_state_path(workspace)

    with :ok <-
           validate_execution_workspace(
             workspace,
             nil,
             execution_context,
             workspace_attestation
           ),
         :ok <- remove_local_readiness_state(state_path),
         :ok <- remove_context_private_home(execution_context, opts) do
      {:ok, []}
    else
      {:error, _file, _reason} = error -> error
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_issue_workspace_path(
         workspace,
         nil,
         execution_context,
         workspace_attestation,
         opts
       ) do
    state_path = readiness_state_path(workspace)

    if File.exists?(workspace) or File.exists?(state_path) do
      remove_existing_local_workspace(
        workspace,
        state_path,
        execution_context,
        workspace_attestation,
        opts
      )
    else
      {:ok, []}
    end
  end

  defp remove_issue_workspace_path(workspace, worker_host, nil, nil, _opts),
    do: remove(workspace, worker_host)

  defp remove_issue_workspace_path(
         workspace,
         worker_host,
         %ProjectExecutionContext{workspace_namespace: namespace},
         workspace_attestation,
         _opts
       )
       when is_binary(worker_host) do
    before_remove_hook = Config.settings!().hooks.before_remove

    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("workspace_root", Config.settings!().workspace.root),
        remote_shell_assign("workspace_namespace", namespace),
        remote_shell_assign("readiness_state", readiness_state_path(workspace)),
        "if [ ! -d \"$workspace_root\" ]; then exit 0; fi",
        "root_physical=\"$(cd \"$workspace_root\" && pwd -P)\"",
        "expected_namespace=\"$root_physical/$workspace_namespace\"",
        "namespace_path=\"$workspace_root/$workspace_namespace\"",
        "if [ ! -d \"$namespace_path\" ]; then exit 0; fi",
        "namespace_physical=\"$(cd \"$namespace_path\" && pwd -P)\"",
        "if [ \"$namespace_physical\" != \"$expected_namespace\" ]; then exit 1; fi",
        "workspace_parent=\"$(dirname \"$workspace\")\"",
        "if [ ! -d \"$workspace_parent\" ]; then exit 0; fi",
        "parent_physical=\"$(cd \"$workspace_parent\" && pwd -P)\"",
        "if [ \"$parent_physical\" != \"$namespace_physical\" ]; then exit 1; fi",
        "if [ -L \"$workspace\" ]; then exit 1; fi",
        "if [ -e \"$workspace\" ]; then",
        "  workspace_physical=\"$(cd \"$workspace\" && pwd -P)\"",
        "  expected_workspace=\"$namespace_physical/$(basename \"$workspace\")\"",
        "  if [ \"$workspace_physical\" != \"$expected_workspace\" ]; then exit 1; fi",
        "fi",
        remote_cleanup_attestation_guard(workspace_attestation),
        context_remote_before_remove_hook(before_remove_hook, workspace_attestation),
        remote_cleanup_attestation_guard(workspace_attestation),
        remote_workspace_remove_command(workspace_attestation),
        "rm -f \"$readiness_state\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> {:ok, []}
      {:ok, {output, status}} -> {:error, {:workspace_remove_failed, worker_host, status, output}, ""}
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp cleanup_effect_opts(
         nil,
         %ProjectExecutionContext{} = execution_context,
         workspace_attestation
       ) do
    {:ok, environment} = SubprocessEnvironment.build(%{}, execution_context)

    {:ok,
     [
       env: environment,
       execution_context: execution_context,
       workspace_attestation: workspace_attestation,
       subprocess_home_paths: SubprocessEnvironment.private_home_paths(execution_context)
     ]}
  end

  defp cleanup_effect_opts(
         _worker_host,
         execution_context,
         workspace_attestation
       ) do
    {:ok,
     [
       execution_context: execution_context,
       workspace_attestation: workspace_attestation
     ]}
  end

  defp remove_context_private_home(%ProjectExecutionContext{} = execution_context, opts) do
    with {:ok, paths} <- Keyword.fetch(opts, :subprocess_home_paths),
         :ok <- validate_private_home_contract(paths, execution_context, opts) do
      remove_existing_context_private_home(paths, execution_context)
    else
      _failure -> {:error, :subprocess_home_unavailable}
    end
  end

  defp remove_existing_context_private_home(paths, execution_context) do
    case File.lstat(paths.home) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> remove_attested_context_private_home(paths, execution_context)
      _unsafe -> {:error, :subprocess_home_unavailable}
    end
  end

  defp remove_attested_context_private_home(paths, execution_context) do
    namespace_path =
      Path.join(Path.expand(Config.settings!().workspace.root), execution_context.workspace_namespace)

    with true <- local_paths_equal?(Path.dirname(paths.root), namespace_path),
         :ok <- validate_private_home_cleanup_components(paths, namespace_path),
         {:ok, namespace_attestation} <- local_workspace_attestation(namespace_path),
         {:ok, root_attestation} <- local_workspace_attestation(paths.root),
         {:ok, home_attestation} <- local_workspace_attestation(paths.home),
         :ok <- validate_workspace_attestation(namespace_path, nil, namespace_attestation),
         :ok <- validate_workspace_attestation(paths.root, nil, root_attestation),
         :ok <- validate_workspace_attestation(paths.home, nil, home_attestation),
         {:ok, _removed} <- File.rm_rf(paths.home) do
      :ok
    else
      _failure -> {:error, :subprocess_home_unavailable}
    end
  end

  defp validate_private_home_cleanup_components(paths, namespace_path) do
    paths
    |> Map.values()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case validate_private_home_cleanup_component(path, namespace_path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_private_home_cleanup_component(path, namespace_path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case safe_private_directory_identity(path, namespace_path) do
          {:ok, _identity} -> :ok
          _failure -> {:error, :unsafe_private_home_path}
        end

      {:error, :enoent} ->
        :ok

      _unsafe ->
        {:error, :unsafe_private_home_path}
    end
  end

  defp run_context_cleanup_hook(
         workspace,
         %ProjectExecutionContext{} = execution_context,
         workspace_attestation,
         opts
       ) do
    case Config.settings!().hooks.before_remove do
      nil ->
        :ok

      _command ->
        with {:ok, guard} <-
               open_existing_private_home_guard(
                 workspace,
                 execution_context,
                 workspace_attestation,
                 opts
               ) do
          hook_result = maybe_run_before_remove_hook(workspace, nil, opts)

          finish_existing_private_home_guard(
            guard,
            hook_result,
            workspace,
            execution_context,
            workspace_attestation
          )
        end
    end
  end

  defp open_existing_private_home_guard(
         workspace,
         execution_context,
         workspace_attestation,
         opts
       ) do
    with {:ok, paths} <- Keyword.fetch(opts, :subprocess_home_paths),
         :ok <- validate_private_home_contract(paths, execution_context, opts),
         expanded_root = Path.expand(Config.settings!().workspace.root),
         namespace_path = Path.join(expanded_root, execution_context.workspace_namespace),
         component_paths = Enum.map(@private_home_path_keys, &Map.fetch!(paths, &1)),
         :ok <-
           validate_execution_workspace(
             workspace,
             nil,
             execution_context,
             workspace_attestation
           ),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root),
         true <- local_paths_equal?(canonical_root, expanded_root),
         :ok <- validate_non_reparse_directory(canonical_root),
         {:ok, root_identity} <- local_file_identity(canonical_root),
         true <- local_paths_equal?(Path.dirname(paths.root), namespace_path),
         :ok <- validate_non_reparse_directory(namespace_path),
         {:ok, namespace_attestation} <- local_workspace_attestation(namespace_path),
         :ok <- validate_private_component_locations(component_paths, namespace_path),
         {:ok, identities} <-
           preflight_private_home_components(component_paths, namespace_path),
         true <- map_size(identities) == length(component_paths) do
      operation = %PrivateHomeOperation{
        workspace: workspace,
        execution_context: execution_context,
        workspace_attestation: workspace_attestation,
        namespace_attestation: namespace_attestation,
        namespace_path: namespace_path,
        canonical_root: canonical_root,
        root_identity: root_identity,
        opts: opts
      }

      open_platform_private_home_guard(operation, component_paths, identities)
    else
      _failure -> {:error, :subprocess_home_unavailable}
    end
  end

  defp open_platform_private_home_guard(operation, component_paths, identities) do
    case :os.type() do
      {:unix, _name} ->
        {:ok, {:posix, operation, identities}}

      {:win32, _name} ->
        anchors = [
          {operation.canonical_root, windows_identity(operation.root_identity)},
          {operation.namespace_path, windows_identity(operation.namespace_attestation.identity)},
          {operation.workspace, windows_identity(operation.workspace_attestation.identity)}
        ]

        components =
          Enum.map(component_paths, fn path ->
            {path, identities |> Map.fetch!(path) |> windows_identity()}
          end)

        case WindowsCapability.open(anchors, components) do
          {:ok, capability} -> {:ok, {:windows, capability}}
          {:error, _reason} -> {:error, :subprocess_home_unavailable}
        end
    end
  end

  defp finish_existing_private_home_guard(
         {:windows, capability},
         _hook_result,
         workspace,
         execution_context,
         workspace_attestation
       ) do
    validation_result =
      validate_execution_workspace(workspace, nil, execution_context, workspace_attestation)

    case validation_result do
      :ok ->
        case WindowsCapability.commit(capability) do
          :ok -> :ok
          {:error, :private_home_capability_failed} -> {:error, :subprocess_home_unavailable}
        end

      _failure ->
        case WindowsCapability.rollback(capability) do
          :ok -> {:error, :subprocess_home_unavailable}
          {:error, :private_home_capability_failed} -> {:error, :subprocess_home_rollback_failed}
        end
    end
  end

  defp finish_existing_private_home_guard(
         {:posix, operation, identities},
         hook_result,
         _workspace,
         _execution_context,
         _workspace_attestation
       ) do
    with :ok <- hook_result,
         :ok <-
           validate_private_home_state(
             operation.workspace,
             operation.execution_context,
             operation.workspace_attestation,
             operation.namespace_attestation,
             operation.namespace_path,
             identities
           ) do
      :ok
    else
      _failure -> {:error, :subprocess_home_unavailable}
    end
  end

  defp remote_cleanup_attestation_guard(nil), do: ""

  defp remote_cleanup_attestation_guard(%{kind: :remote, identity: identity})
       when is_binary(identity) and identity != "" do
    remote_workspace_identity_script() <>
      "\nexpected_workspace_identity=#{shell_escape(identity)}\n" <>
      ~S<if [ ! -d "$workspace" ] || [ -L "$workspace" ]; then exit 1; fi
> <>
      ~S<if ! current_workspace_identity="$(read_workspace_identity "$workspace")"; then exit 1; fi
> <>
      ~S<if [ "$current_workspace_identity" != "$expected_workspace_identity" ]; then exit 1; fi>
  end

  defp remote_cleanup_attestation_guard(%{
         kind: :remote_absent,
         workspace_namespace: namespace
       }) do
    "expected_attested_namespace=#{shell_escape(namespace)}\n" <>
      ~S<if [ "$workspace_namespace" != "$expected_attested_namespace" ]; then exit 1; fi
if [ -e "$workspace" ] || [ -L "$workspace" ]; then exit 1; fi>
  end

  defp remote_cleanup_attestation_guard(_invalid), do: "exit 1"

  defp context_remote_before_remove_hook(_command, %{kind: :remote_absent}), do: ""

  defp context_remote_before_remove_hook(nil, _attestation), do: ""

  defp context_remote_before_remove_hook(command, _attestation) when is_binary(command) do
    "if [ -d \"$workspace\" ]; then (cd \"$workspace\" && #{command}) || true; fi"
  end

  defp remote_workspace_remove_command(%{kind: :remote_absent}), do: ""
  defp remote_workspace_remove_command(_attestation), do: "rm -rf \"$workspace\""

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) do
    run_before_run_hook(workspace, issue_or_identifier, worker_host, [])
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host, opts)
      when is_binary(workspace) and is_list(opts) do
    execution_context = Keyword.get(opts, :execution_context)
    issue_context = issue_context(issue_or_identifier, execution_context)
    hooks = Config.settings!().hooks

    with :ok <- validate_remote_credential_environment(worker_host, opts),
         :ok <-
           validate_execution_workspace(
             workspace,
             worker_host,
             execution_context,
             Keyword.get(opts, :workspace_attestation)
           ) do
      case hooks.before_run do
        nil -> :ok
        command -> run_guarded_hook(command, workspace, issue_context, "before_run", worker_host, opts)
      end
    end
  end

  @spec preflight(Path.t(), map() | String.t() | nil, worker_host()) :: :ok | {:error, term()}
  def preflight(workspace, issue_or_identifier, worker_host \\ nil) do
    preflight(workspace, issue_or_identifier, worker_host, [])
  end

  @spec preflight(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def preflight(workspace, issue_or_identifier, worker_host, opts)
      when is_binary(workspace) and is_list(opts) do
    execution_context = Keyword.get(opts, :execution_context)
    issue_context = issue_context(issue_or_identifier, execution_context)

    Logger.info("Running workspace preflight #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")

    with :ok <- validate_remote_credential_environment(worker_host, opts),
         :ok <-
           validate_execution_workspace(
             workspace,
             worker_host,
             execution_context,
             Keyword.get(opts, :workspace_attestation)
           ) do
      case worker_host do
        nil -> local_preflight(workspace, opts)
        host when is_binary(host) -> remote_preflight(workspace, host, opts)
      end
    end
  end

  @spec run_git_command(Path.t(), [String.t()], worker_host()) ::
          {:ok, String.t()}
          | {:error, {:git_command_failed, String.t(), integer(), String.t()}}
          | {:error, {:git_command_failed, String.t(), String.t()}}
          | {:error, {:workspace_hook_timeout, String.t(), pos_integer()}}
  def run_git_command(workspace, args, worker_host \\ nil) do
    run_git_command(workspace, args, worker_host, [])
  end

  @spec run_git_command(Path.t(), [String.t()], worker_host(), keyword()) ::
          {:ok, String.t()}
          | {:error, {:git_command_failed, String.t(), integer(), String.t()}}
          | {:error, {:git_command_failed, String.t(), String.t()}}
          | {:error, {:workspace_hook_timeout, String.t(), pos_integer()}}
  def run_git_command(workspace, args, worker_host, opts)
      when is_binary(workspace) and is_list(args) and is_list(opts) do
    command = git_command_for_log(args)

    with :ok <- validate_remote_credential_environment(worker_host, opts),
         :ok <-
           validate_execution_workspace(
             workspace,
             worker_host,
             Keyword.get(opts, :execution_context),
             Keyword.get(opts, :workspace_attestation)
           ) do
      case worker_host do
        nil -> run_local_git_command(workspace, args, command, opts)
        host when is_binary(host) -> run_remote_git_command(workspace, args, host, command, opts)
      end
    end
  end

  @spec sanitize_command_output(iodata(), non_neg_integer()) :: String.t()
  def sanitize_command_output(output, max_bytes \\ 2_048) do
    sanitize_hook_output_for_log(output, max_bytes)
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) do
    run_after_run_hook(workspace, issue_or_identifier, worker_host, [])
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host, opts)
      when is_binary(workspace) and is_list(opts) do
    execution_context = Keyword.get(opts, :execution_context)
    issue_context = issue_context(issue_or_identifier, execution_context)
    hooks = Config.settings!().hooks

    with :ok <- validate_remote_credential_environment(worker_host, opts),
         :ok <-
           validate_execution_workspace(
             workspace,
             worker_host,
             execution_context,
             Keyword.get(opts, :workspace_attestation)
           ) do
      case hooks.after_run do
        nil -> :ok
        command -> run_guarded_hook(command, workspace, issue_context, "after_run", worker_host, opts)
      end
    end
    |> ignore_hook_failure()
  end

  defp workspace_path_for_issue(safe_id, nil, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host, nil)
       when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp workspace_path_for_issue(
         safe_id,
         nil,
         %ProjectExecutionContext{workspace_namespace: namespace}
       )
       when is_binary(safe_id) do
    with {:ok, canonical_root} <- PathSafety.canonicalize(Config.settings!().workspace.root) do
      {:ok, Path.join([canonical_root, namespace, safe_id])}
    end
  end

  defp workspace_path_for_issue(
         safe_id,
         worker_host,
         %ProjectExecutionContext{workspace_namespace: namespace}
       )
       when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join([Config.settings!().workspace.root, namespace, safe_id])}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, opts) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil -> :ok
          command -> run_guarded_hook(command, workspace, issue_context, "after_create", worker_host, opts)
        end

      false ->
        :ok
    end
  end

  defp run_guarded_hook(command, workspace, issue_context, hook_name, worker_host, opts) do
    with :ok <-
           validate_private_home_effect(
             workspace,
             worker_host,
             Keyword.get(opts, :execution_context),
             Keyword.get(opts, :workspace_attestation),
             opts
           ) do
      run_hook(command, workspace, issue_context, hook_name, worker_host, opts)
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    maybe_run_before_remove_hook(workspace, nil, [])
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

  defp maybe_run_before_remove_hook(workspace, nil, opts) when is_list(opts) do
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
              nil,
              opts
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil, opts) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        try do
          System.cmd("sh", ["-c", command],
            cd: workspace,
            stderr_to_stdout: true,
            env: system_command_environment(opts)
          )
        rescue
          error in ErlangError -> {:error, error.original}
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:error, reason}} ->
        {:error, {:workspace_hook_failed, hook_name, reason}}

      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name, opts)

      {:exit, reason} ->
        {:error, {:workspace_hook_failed, hook_name, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, opts)
       when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      remote_environment(opts) <>
        remote_execution_guard(
          workspace,
          Keyword.get(opts, :execution_context),
          Keyword.get(opts, :workspace_attestation)
        ) <>
        "#{command}\n"

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name, opts)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result(result, workspace, issue_context, hook_name) do
    handle_hook_command_result(result, workspace, issue_context, hook_name, [])
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name, _opts) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name, opts) do
    sanitized_output = sanitize_process_output(output, opts)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, sanitized_output}}
  end

  defp local_preflight(workspace, opts) do
    with :ok <- require_workspace_dir(workspace),
         :ok <-
           run_git_preflight_command(
             workspace,
             ["rev-parse", "--is-inside-work-tree"],
             :workspace_not_git_repo,
             opts
           ),
         :ok <- maybe_validate_origin_remote(workspace, opts),
         :ok <- run_git_preflight_command(workspace, ["status", "--short"], :git_status_failed, opts) do
      run_git_preflight_command(workspace, ["fetch", "origin", "--prune"], :git_fetch_failed, opts)
    end
  end

  defp remote_preflight(workspace, worker_host, opts) do
    script =
      [
        remote_environment(opts),
        remote_execution_guard(
          workspace,
          Keyword.get(opts, :execution_context),
          Keyword.get(opts, :workspace_attestation)
        ),
        "git rev-parse --is-inside-work-tree >/dev/null",
        remote_expected_repo_script(opts),
        "git status --short >/dev/null",
        "git fetch origin --prune >/dev/null"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error,
         workspace_preflight_error(
           :remote_workspace_preflight_failed,
           "remote preflight",
           status,
           sanitize_process_output(output, opts)
         )}

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

  defp maybe_validate_origin_remote(workspace, opts) do
    case expected_source_repo_url(opts) do
      nil ->
        run_git_preflight_command(
          workspace,
          ["config", "--get", "remote.origin.url"],
          :git_remote_missing,
          opts
        )

      expected_url ->
        case run_attested_local_command(
               workspace,
               "git",
               ["-C", workspace, "config", "--get", "remote.origin.url"],
               "git config --get remote.origin.url",
               opts
             ) do
          {output, 0} ->
            validate_origin_remote(String.trim(output), expected_url)

          {output, status} when is_integer(status) ->
            {:error,
             workspace_preflight_error(
               :git_remote_missing,
               "git config --get remote.origin.url",
               status,
               sanitize_process_output(output, opts)
             )}

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

  defp run_git_preflight_command(workspace, args, error_type, opts) do
    command = Enum.join(["git" | args], " ")

    case run_attested_local_command(
           workspace,
           "git",
           ["-C", workspace | args],
           command,
           opts
         ) do
      {_output, 0} ->
        :ok

      {output, status} when is_integer(status) ->
        {:error, workspace_preflight_error(error_type, command, status, sanitize_process_output(output, opts))}

      {:error, reason} ->
        {:error, workspace_preflight_error(error_type, command, reason)}
    end
  end

  defp run_local_git_command(workspace, args, command, opts) do
    case run_attested_local_command(
           workspace,
           "git",
           ["-C", workspace | args],
           command,
           opts
         ) do
      {output, 0} ->
        {:ok, IO.iodata_to_binary(output)}

      {output, status} when is_integer(status) ->
        {:error, {:git_command_failed, command, status, sanitize_process_output(output, opts)}}

      {:error, {:workspace_hook_timeout, _timed_command, timeout_ms}} ->
        {:error, {:workspace_hook_timeout, command, timeout_ms}}

      {:error, :subprocess_home_unavailable} = error ->
        error

      {:error, reason} ->
        {:error, {:git_command_failed, command, sanitize_process_output(inspect(reason), opts)}}
    end
  end

  defp run_remote_git_command(workspace, args, worker_host, command, opts) do
    script =
      remote_environment(opts) <>
        remote_execution_guard(
          workspace,
          Keyword.get(opts, :execution_context),
          Keyword.get(opts, :workspace_attestation)
        ) <>
        "#{remote_git_command(args)}\n"

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, IO.iodata_to_binary(output)}

      {:ok, {output, status}} when is_integer(status) ->
        {:error, {:git_command_failed, command, status, sanitize_process_output(output, opts)}}

      {:error, {:workspace_hook_timeout, _timed_command, timeout_ms}} ->
        {:error, {:workspace_hook_timeout, command, timeout_ms}}

      {:error, reason} ->
        {:error, {:git_command_failed, command, sanitize_process_output(inspect(reason), opts)}}
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

  defp run_local_preflight_command(executable, args, command, opts) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    task =
      Task.async(fn ->
        try do
          System.cmd(executable, args,
            stderr_to_stdout: true,
            env: system_command_environment(opts, local_git_preflight_env())
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

  defp run_attested_local_command(workspace, executable, args, command, opts) do
    with :ok <-
           validate_private_home_effect(
             workspace,
             nil,
             Keyword.get(opts, :execution_context),
             Keyword.get(opts, :workspace_attestation),
             opts
           ) do
      run_local_preflight_command(executable, args, command, opts)
    end
  end

  @doc false
  @spec run_local_preflight_command_for_test(String.t(), [String.t()], String.t()) ::
          {String.t(), non_neg_integer()} | {:error, term()}
  def run_local_preflight_command_for_test(executable, args, command) do
    run_local_preflight_command(executable, args, command, [])
  end

  defp process_environment(opts, defaults \\ []) do
    opts
    |> Keyword.get(:env, %{})
    |> Enum.reduce(defaults, fn {key, value}, environment ->
      List.keystore(environment, key, 0, {key, value})
    end)
  end

  defp system_command_environment(opts, defaults \\ []) do
    opts
    |> process_environment(defaults)
    |> Enum.map(fn
      {key, false} -> {key, nil}
      entry -> entry
    end)
  end

  defp remote_environment(opts) do
    opts
    |> process_environment()
    |> Enum.map_join("", fn
      {key, false} -> "unset #{key}\n"
      {key, value} -> "export #{key}=#{shell_escape(value)}\n"
    end)
  end

  defp local_workspace_attestation(workspace) when is_binary(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, identity} <- local_file_identity(canonical_workspace) do
      {:ok,
       %{
         kind: :local,
         path: canonical_workspace,
         identity: identity
       }}
    else
      {:error, reason} ->
        {:error, {:workspace_attestation_failed, workspace, reason}}
    end
  end

  defp local_file_identity(path) when is_binary(path) do
    platform = :os.type()

    cond do
      match?({:unix, _name}, platform) -> posix_file_identity(path)
      match?({:win32, _name}, platform) -> windows_directory_identity(path)
      true -> {:error, :unsupported_local_file_identity_platform}
    end
  end

  defp posix_file_identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        posix_file_identity_from_stat(stat)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec posix_file_identity_for_test(term()) ::
          {:ok, map()} | {:error, :invalid_posix_file_identity}
  def posix_file_identity_for_test(stat), do: posix_file_identity_from_stat(stat)

  defp posix_file_identity_from_stat(%File.Stat{
         type: :directory,
         major_device: major_device,
         minor_device: minor_device,
         inode: inode
       })
       when is_integer(major_device) and major_device >= 0 and is_integer(minor_device) and
              minor_device >= 0 and is_integer(inode) and inode >= 0 do
    {:ok,
     %{
       type: :directory,
       major_device: major_device,
       minor_device: minor_device,
       inode: inode
     }}
  end

  defp posix_file_identity_from_stat(_invalid), do: {:error, :invalid_posix_file_identity}

  defp posix_private_file_identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        posix_private_file_identity_from_stat(stat)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec posix_private_file_identity_for_test(term()) ::
          {:ok, map()} | {:error, :invalid_posix_private_file_identity}
  def posix_private_file_identity_for_test(stat),
    do: posix_private_file_identity_from_stat(stat)

  defp posix_private_file_identity_from_stat(%File.Stat{
         type: :directory,
         major_device: major_device,
         minor_device: minor_device,
         inode: inode,
         uid: uid
       })
       when is_integer(major_device) and major_device >= 0 and is_integer(minor_device) and
              minor_device >= 0 and is_integer(inode) and inode >= 0 and is_integer(uid) and
              uid >= 0 do
    {:ok,
     %{
       type: :directory,
       major_device: major_device,
       minor_device: minor_device,
       inode: inode,
       uid: uid
     }}
  end

  defp posix_private_file_identity_from_stat(_invalid),
    do: {:error, :invalid_posix_private_file_identity}

  defp windows_directory_identity(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.stat(path, time: :posix),
         {:ok, identity} <- windows_file_identity(path) do
      {:ok, Map.put(identity, :type, :directory)}
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:local_file_identity_not_directory, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp windows_file_identity(path) do
    with system_root when is_binary(system_root) and system_root != "" <-
           System.get_env("SystemRoot") || System.get_env("SYSTEMROOT"),
         true <- Path.type(system_root) == :absolute,
         executable = Path.join([system_root, "System32", "fsutil.exe"]),
         true <- File.regular?(executable),
         {output, 0} <-
           System.cmd(executable, ["file", "queryfileid", Path.expand(path)], stderr_to_stdout: true),
         {:ok, file_id} <- parse_windows_file_id_for_test(output) do
      {:ok, %{windows_file_id: file_id}}
    else
      _failure -> {:error, :windows_file_identity_unavailable}
    end
  end

  @doc false
  @spec parse_windows_file_id_for_test(term()) ::
          {:ok, String.t()} | {:error, :invalid_windows_file_id_output}
  def parse_windows_file_id_for_test(output) when is_binary(output) do
    case Regex.scan(~r/(?<!\S)0x[0-9a-fA-F]{32}(?!\S)/, output) do
      [[file_id]] -> {:ok, String.downcase(file_id)}
      _failure -> {:error, :invalid_windows_file_id_output}
    end
  end

  def parse_windows_file_id_for_test(_invalid), do: {:error, :invalid_windows_file_id_output}

  defp remote_workspace_identity_script do
    [
      "read_workspace_identity() {",
      "  if stat -Lc '%d:%i' \"$1\" >/dev/null 2>&1; then",
      "    stat -Lc '%d:%i' \"$1\"",
      "  elif stat -f '%d:%i' \"$1\" >/dev/null 2>&1; then",
      "    stat -f '%d:%i' \"$1\"",
      "  else",
      "    return 1",
      "  fi",
      "}"
    ]
    |> Enum.join("\n")
  end

  @doc false
  @spec remote_execution_guard(Path.t(), ProjectExecutionContext.t() | nil) :: String.t()
  def remote_execution_guard(workspace, nil) when is_binary(workspace) do
    "set -eu\ncd #{shell_escape(workspace)}\n"
  end

  def remote_execution_guard(
        workspace,
        %ProjectExecutionContext{
          workspace_namespace: namespace,
          issue_identifier: issue_identifier
        }
      )
      when is_binary(workspace) do
    [
      "set -eu",
      remote_shell_assign("workspace", workspace),
      remote_shell_assign("workspace_root", Config.settings!().workspace.root),
      remote_shell_assign("workspace_namespace", namespace),
      remote_shell_assign("issue_leaf", safe_identifier(issue_identifier)),
      "if [ -L \"$workspace\" ]; then exit 1; fi",
      "if [ ! -d \"$workspace_root\" ]; then exit 1; fi",
      "root_physical=\"$(cd \"$workspace_root\" && pwd -P)\"",
      "namespace_path=\"$workspace_root/$workspace_namespace\"",
      "expected_namespace=\"$root_physical/$workspace_namespace\"",
      "if [ -L \"$namespace_path\" ] || [ ! -d \"$namespace_path\" ]; then exit 1; fi",
      "namespace_physical=\"$(cd \"$namespace_path\" && pwd -P)\"",
      "if [ \"$namespace_physical\" != \"$expected_namespace\" ]; then exit 1; fi",
      "if [ ! -d \"$workspace\" ]; then exit 1; fi",
      "workspace_physical=\"$(cd \"$workspace\" && pwd -P)\"",
      "expected_workspace=\"$namespace_physical/$issue_leaf\"",
      "if [ \"$workspace_physical\" != \"$expected_workspace\" ]; then exit 1; fi",
      "cd \"$workspace\""
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc false
  @spec remote_execution_guard(Path.t(), ProjectExecutionContext.t() | nil, map() | nil) ::
          String.t()
  def remote_execution_guard(workspace, execution_context, workspace_attestation)
      when is_binary(workspace) do
    remote_execution_guard(workspace, execution_context) <>
      remote_workspace_attestation_guard(workspace_attestation)
  end

  defp remote_workspace_attestation_guard(nil), do: ""

  defp remote_workspace_attestation_guard(%{kind: :remote, identity: identity})
       when is_binary(identity) and identity != "" do
    remote_workspace_identity_script() <>
      "\nexpected_workspace_identity=#{shell_escape(identity)}\n" <>
      ~S<if ! current_workspace_identity="$(read_workspace_identity "$workspace")"; then exit 1; fi
> <>
      ~S<if [ "$current_workspace_identity" != "$expected_workspace_identity" ]; then exit 1; fi
>
  end

  defp remote_workspace_attestation_guard(_invalid), do: "exit 1\n"

  defp local_git_preflight_env do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GCM_INTERACTIVE", "Never"},
      {"GIT_SSH_COMMAND", nil},
      {"SSH_AUTH_SOCK", nil},
      {"SSH_AGENT_PID", nil}
    ]
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

  defp maybe_add_git_ssh_command(env, nil), do: env
  defp maybe_add_git_ssh_command(env, ""), do: env

  defp maybe_add_git_ssh_command(env, command) when is_binary(command) do
    [{"GIT_SSH_COMMAND", batch_mode_ssh_command(command)} | env]
  end

  @doc false
  @spec batch_mode_ssh_command_for_test(String.t() | nil) :: String.t() | nil
  def batch_mode_ssh_command_for_test(command), do: batch_mode_ssh_command(command)

  @doc false
  @spec local_git_preflight_env_for_test(String.t() | nil) ::
          [{String.t(), String.t() | nil}]
  def local_git_preflight_env_for_test(command) do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GCM_INTERACTIVE", "Never"}
    ]
    |> maybe_add_git_ssh_command(command)
  end

  defp remote_expected_repo_script(opts) do
    case expected_source_repo_url(opts) do
      nil ->
        "git config --get remote.origin.url >/dev/null"

      expected_url ->
        expected = shell_escape(remote_comparable_repo_url(expected_url))

        [
          "strip_url_userinfo() {",
          "  case \"$1\" in",
          "    *://*@*) printf '%s://%s\\n' \"${1%%://*}\" \"${1#*@}\" ;;",
          "    *) printf '%s\\n' \"$1\" ;;",
          "  esac",
          "}",
          "normalize_windows_local_path() {",
          "  case \"$1\" in",
          "    [A-Za-z]:[\\\\/]*)",
          "      normalized=\"$(printf '%s' \"$1\" | tr '\\\\134' '/')\"",
          "      drive=\"$(printf '%s' \"${normalized%\"${normalized#?}\"}\" | tr '[:upper:]' '[:lower:]')\"",
          "      printf '%s%s\\n' \"$drive\" \"${normalized#?}\"",
          "      ;;",
          "    \\\\\\\\*|//*) printf '%s\\n' \"$1\" | tr '\\\\134' '/' ;;",
          "    *) printf '%s\\n' \"$1\" ;;",
          "  esac",
          "}",
          "actual_remote=\"$(git config --get remote.origin.url)\"",
          "actual_remote=\"$(strip_url_userinfo \"$actual_remote\")\"",
          "remote_os=\"$(uname -s 2>/dev/null || printf 'unknown')\"",
          "case \"$remote_os\" in",
          "  CYGWIN*|MINGW*|MSYS*|Windows_NT*)",
          "    actual_remote=\"$(normalize_windows_local_path \"$actual_remote\")\"",
          "    ;;",
          "esac",
          "actual_remote=\"${actual_remote%/}\"",
          "actual_remote=\"${actual_remote%.git}\"",
          "expected_remote=#{expected}",
          "case \"$remote_os\" in",
          "  CYGWIN*|MINGW*|MSYS*|Windows_NT*)",
          "    expected_remote=\"$(normalize_windows_local_path \"$expected_remote\")\"",
          "    ;;",
          "esac",
          "expected_remote=\"${expected_remote%/}\"",
          "expected_remote=\"${expected_remote%.git}\"",
          "test \"$actual_remote\" = \"$expected_remote\""
        ]
        |> Enum.join("\n")
    end
  end

  @doc false
  @spec remote_expected_repo_script_for_test() :: String.t()
  def remote_expected_repo_script_for_test, do: remote_expected_repo_script([])

  @doc false
  @spec sanitize_hook_output_for_test(iodata(), non_neg_integer()) :: String.t()
  def sanitize_hook_output_for_test(output, max_bytes), do: sanitize_hook_output_for_log(output, max_bytes)

  defp expected_source_repo_url(opts) do
    case Keyword.get(opts, :execution_context) do
      %ProjectExecutionContext{repository: repository} ->
        RepositorySource.url(repository)

      _legacy ->
        ambient_source_repo_url()
    end
  end

  defp ambient_source_repo_url do
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

  defp remote_comparable_repo_url(url) when is_binary(url) do
    url
    |> strip_url_userinfo()
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
  end

  defp normalized_repo_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> normalize_windows_local_repo_path()
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
  end

  defp normalize_windows_local_repo_path(path) do
    if match?({:win32, _}, :os.type()), do: do_normalize_windows_local_repo_path(path), else: path
  end

  defp do_normalize_windows_local_repo_path(<<drive, ?:, separator, _rest::binary>> = path)
       when drive in ?A..?Z and separator in [?/, ?\\],
       do:
         String.replace(
           <<drive + 32, ?:, separator, binary_part(path, 3, byte_size(path) - 3)::binary>>,
           "\\",
           "/"
         )

  defp do_normalize_windows_local_repo_path(<<drive, ?:, separator, _rest::binary>> = path)
       when drive in ?a..?z and separator in [?/, ?\\],
       do: String.replace(path, "\\", "/")

  defp do_normalize_windows_local_repo_path("\\\\" <> _rest = path),
    do: String.replace(path, "\\", "/")

  defp do_normalize_windows_local_repo_path("//" <> _rest = path),
    do: String.replace(path, "\\", "/")

  defp do_normalize_windows_local_repo_path(url), do: url

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

  defp sanitize_process_output(output, opts, max_bytes \\ 2_048) do
    redacted_output =
      opts
      |> sensitive_environment_values()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.reduce(IO.iodata_to_binary(output), fn
        value, sanitized when is_binary(value) -> String.replace(sanitized, value, "[redacted]")
        _value, sanitized -> sanitized
      end)

    sanitize_hook_output_for_log(redacted_output, max_bytes)
  end

  defp sensitive_environment_values(opts) do
    Keyword.get_lazy(opts, :sensitive_env_values, fn ->
      opts
      |> process_environment()
      |> Enum.map(fn {_key, value} -> value end)
    end)
  end

  defp validate_remote_credential_environment(worker_host, opts)
       when is_binary(worker_host) and is_list(opts) do
    if Enum.any?(process_environment(opts), fn
         {_key, value} when is_binary(value) -> value != ""
         _entry -> false
       end) do
      {:error, :remote_credential_environment_unsupported}
    else
      :ok
    end
  end

  defp validate_remote_credential_environment(_worker_host, _opts), do: :ok

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

  @spec validate_execution_workspace(
          Path.t(),
          worker_host(),
          ProjectExecutionContext.t() | nil
        ) :: :ok | {:error, term()}
  def validate_execution_workspace(workspace, worker_host, execution_context)
      when is_binary(workspace) do
    validate_execution_workspace(workspace, worker_host, execution_context, nil)
  end

  @spec validate_execution_workspace(
          Path.t(),
          worker_host(),
          ProjectExecutionContext.t() | nil,
          map() | nil
        ) :: :ok | {:error, term()}
  def validate_execution_workspace(_workspace, _worker_host, nil, nil), do: :ok

  def validate_execution_workspace(
        workspace,
        worker_host,
        execution_context,
        workspace_attestation
      )
      when is_binary(workspace) do
    with :ok <- validate_execution_context(execution_context) do
      with :ok <-
             validate_workspace_path(
               workspace,
               worker_host,
               execution_context,
               workspace_attestation
             ) do
        validate_workspace_attestation(workspace, worker_host, workspace_attestation)
      end
    end
  end

  defp validate_workspace_attestation(_workspace, _worker_host, nil), do: :ok

  defp validate_workspace_attestation(
         workspace,
         nil,
         %{
           kind: :local_absent,
           path: expected_path,
           namespace_path: namespace_path,
           namespace_attestation: namespace_attestation
         } = expected
       )
       when is_binary(expected_path) and is_binary(namespace_path) do
    current =
      with true <- local_paths_equal?(Path.expand(workspace), expected_path),
           {:error, :enoent} <- File.lstat(workspace),
           :ok <- validate_namespace_attestation(namespace_path, namespace_attestation) do
        expected
      else
        failure -> %{kind: :local_absent, path: Path.expand(workspace), error: failure}
      end

    if current == expected do
      :ok
    else
      {:error, {:workspace_issue_identity_changed, current, expected}}
    end
  end

  defp validate_workspace_attestation(
         workspace,
         nil,
         %{kind: :local, path: expected_path, identity: expected_identity} = expected
       )
       when is_binary(expected_path) and is_map(expected_identity) do
    current =
      with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
           {:ok, identity} <- local_file_identity(canonical_workspace) do
        %{kind: :local, path: canonical_workspace, identity: identity}
      else
        {:error, reason} -> %{kind: :local, path: Path.expand(workspace), error: reason}
      end

    if current == expected do
      :ok
    else
      {:error, {:workspace_issue_identity_changed, current, expected}}
    end
  end

  defp validate_workspace_attestation(
         workspace,
         worker_host,
         %{
           kind: :remote_absent,
           lexical_path: lexical_path,
           workspace_namespace: namespace
         } = expected
       )
       when is_binary(worker_host) and is_binary(lexical_path) and is_binary(namespace) do
    if workspace == lexical_path do
      :ok
    else
      current = %{kind: :remote_absent, path: workspace, error: :unattested_workspace_path}
      {:error, {:workspace_issue_identity_changed, current, expected}}
    end
  end

  defp validate_workspace_attestation(
         workspace,
         worker_host,
         %{
           kind: :remote,
           lexical_path: lexical_path,
           physical_path: physical_path,
           identity: identity
         } = expected
       )
       when is_binary(worker_host) and is_binary(lexical_path) and is_binary(physical_path) and
              is_binary(identity) and identity != "" do
    if workspace == lexical_path or workspace == physical_path do
      :ok
    else
      current = %{kind: :remote, path: workspace, error: :unattested_workspace_path}
      {:error, {:workspace_issue_identity_changed, current, expected}}
    end
  end

  defp validate_workspace_attestation(
         _workspace,
         worker_host,
         %{kind: :remote, identity: identity}
       )
       when is_binary(worker_host) and is_binary(identity) and identity != "",
       do: :ok

  defp validate_workspace_attestation(workspace, _worker_host, expected) do
    {:error, {:workspace_issue_identity_changed, %{path: workspace, error: :invalid_workspace_attestation}, expected}}
  end

  defp validate_namespace_attestation(namespace_path, :absent) do
    case File.lstat(namespace_path) do
      {:error, :enoent} -> :ok
      other -> {:error, {:workspace_namespace_identity_changed, other, :absent}}
    end
  end

  defp validate_namespace_attestation(
         namespace_path,
         %{kind: :local} = namespace_attestation
       ) do
    validate_workspace_attestation(namespace_path, nil, namespace_attestation)
  end

  defp validate_namespace_attestation(_namespace_path, _namespace_attestation),
    do: {:error, :invalid_workspace_namespace_attestation}

  defp validate_workspace_path(workspace, worker_host),
    do: validate_workspace_path(workspace, worker_host, nil, nil)

  defp validate_workspace_path(workspace, worker_host, execution_context),
    do: validate_workspace_path(workspace, worker_host, execution_context, nil)

  defp validate_workspace_path(workspace, nil, execution_context, _workspace_attestation)
       when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root),
         :ok <-
           validate_context_namespace_path(
             expanded_workspace,
             canonical_workspace,
             canonical_root,
             execution_context
           ) do
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

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_workspace_path(workspace, worker_host, execution_context, workspace_attestation)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      production_workspace_root?(Config.settings!().workspace.root) and
          not is_nil(execution_context) ->
        {:error, {:workspace_production_root, Config.settings!().workspace.root}}

      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      not remote_context_workspace_path?(workspace, execution_context, workspace_attestation) ->
        {:error, {:workspace_issue_identity_mismatch, workspace, expected_remote_workspace(execution_context)}}

      true ->
        :ok
    end
  end

  defp validate_context_namespace_path(_expanded_workspace, _workspace, _root, nil), do: :ok

  defp validate_context_namespace_path(
         expanded_workspace,
         canonical_workspace,
         canonical_root,
         %ProjectExecutionContext{
           workspace_namespace: namespace,
           issue_identifier: issue_identifier
         }
       ) do
    with {:ok, canonical_namespace} <-
           Config.settings!().workspace.root
           |> Path.join(namespace)
           |> PathSafety.canonicalize() do
      expected_namespace = Path.join(canonical_root, namespace)
      expected_workspace = Path.join(expected_namespace, safe_identifier(issue_identifier))

      with :ok <- validate_namespace_root(canonical_namespace, canonical_root, expected_namespace) do
        validate_issue_workspace(
          expanded_workspace,
          canonical_workspace,
          canonical_namespace,
          expected_workspace
        )
      end
    end
  end

  defp validate_namespace_root(canonical_namespace, canonical_root, expected_namespace) do
    cond do
      production_workspace_root?(Config.settings!().workspace.root) ->
        {:error, {:workspace_production_root, Config.settings!().workspace.root}}

      canonical_namespace == canonical_root ->
        {:error, {:workspace_namespace_equals_root, canonical_namespace, canonical_root}}

      not String.starts_with?(canonical_namespace <> "/", canonical_root <> "/") ->
        {:error, {:workspace_namespace_outside_root, canonical_namespace, canonical_root}}

      canonical_namespace != expected_namespace ->
        {:error, {:workspace_namespace_identity_mismatch, canonical_namespace, expected_namespace}}

      true ->
        :ok
    end
  end

  defp validate_issue_workspace(expanded, canonical, namespace, expected) do
    cond do
      canonical == namespace ->
        {:error, {:workspace_equals_namespace, canonical, namespace}}

      Path.expand(expanded) != expected ->
        {:error, {:workspace_issue_identity_mismatch, Path.expand(expanded), expected}}

      issue_leaf_link?(expected) or canonical != expected ->
        {:error, {:workspace_issue_identity_mismatch, canonical, expected}}

      String.starts_with?(canonical <> "/", namespace <> "/") ->
        :ok

      true ->
        {:error, {:workspace_outside_namespace, canonical, namespace}}
    end
  end

  defp issue_leaf_link?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _other -> false
    end
  end

  defp remote_context_workspace_path?(_workspace, nil, _workspace_attestation), do: true

  defp remote_context_workspace_path?(
         workspace,
         %ProjectExecutionContext{} = execution_context,
         workspace_attestation
       ) do
    expected_workspace = expected_remote_workspace(execution_context)

    workspace == expected_workspace or
      attested_remote_workspace_path?(workspace, expected_workspace, workspace_attestation)
  end

  defp attested_remote_workspace_path?(
         workspace,
         expected_workspace,
         %{
           kind: :remote,
           lexical_path: expected_workspace,
           physical_path: physical_workspace,
           identity: identity
         }
       )
       when is_binary(physical_workspace) and is_binary(identity) and identity != "" do
    workspace == physical_workspace
  end

  defp attested_remote_workspace_path?(_workspace, _expected_workspace, _workspace_attestation),
    do: false

  defp expected_remote_workspace(%ProjectExecutionContext{
         workspace_namespace: namespace,
         issue_identifier: identifier
       }) do
    Path.join([Config.settings!().workspace.root, namespace, safe_identifier(identifier)])
  end

  defp production_workspace_root?(root) when is_binary(root) do
    root
    |> Path.expand()
    |> String.downcase()
    |> String.split(~r{[\\/]}, trim: true)
    |> Enum.any?(&String.contains?(&1, "production"))
  end

  defp production_workspace_root?(_root), do: true

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
      Enum.find_value(lines, &parse_remote_workspace_line/1)

    case payload do
      {created?, workspace, attestation} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?, attestation}

      {:unsafe, detail} ->
        {:error, {:workspace_prepare_failed, :unsafe_path, detail}}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp parse_remote_workspace_line(line) do
    case String.split(line, "\t", parts: 4) do
      [@remote_workspace_marker, created, path, identity]
      when created in ["0", "1"] and path != "" and identity != "" ->
        {created == "1", path, %{kind: :remote, identity: identity}}

      [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
        {created == "1", path, nil}

      [@remote_workspace_marker, detail] when detail in ["unsafe-namespace", "unsafe-workspace"] ->
        {:unsafe, detail}

      _ ->
        nil
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

  defp validate_execution_context(nil), do: :ok

  defp validate_execution_context(context) when is_struct(context, ProjectExecutionContext) do
    cond do
      context.environment != "local_non_production" ->
        {:error, :workspace_context_missing}

      not Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, context.workspace_namespace) ->
        {:error, :workspace_context_missing}

      true ->
        :ok
    end
  end

  defp validate_issue_execution_context(%{execution_context: :mismatch}),
    do: {:error, :workspace_context_identity_mismatch}

  defp validate_issue_execution_context(_issue_context), do: :ok

  defp validate_cleanup_execution_context(_identifier, nil), do: :ok

  defp validate_cleanup_execution_context(
         identifier,
         %ProjectExecutionContext{issue_identifier: identifier}
       ),
       do: :ok

  defp validate_cleanup_execution_context(_identifier, %ProjectExecutionContext{}),
    do: {:error, :workspace_context_identity_mismatch}

  defp readiness_issue_context(%ReadinessState{} = state, issue_or_identifier) do
    issue_or_identifier
    |> issue_context()
    |> Map.merge(
      Map.take(state, [
        :profile_key,
        :linear_project_id,
        :repository,
        :canonical_branch,
        :workspace_namespace,
        :credential_ref
      ])
    )
  end

  defp issue_context(issue_or_identifier, %ProjectExecutionContext{} = execution_context) do
    case issue_context(issue_or_identifier) do
      %{issue_identifier: issue_identifier} = original_context
      when issue_identifier == execution_context.issue_identifier ->
        %{
          issue_id: execution_context.issue_id,
          issue_identifier: execution_context.issue_identifier,
          issue_branch: original_context.issue_branch,
          profile_key: execution_context.profile_key,
          linear_project_id: execution_context.linear_project_id,
          repository: execution_context.repository,
          canonical_branch: execution_context.canonical_branch,
          workspace_namespace: execution_context.workspace_namespace,
          credential_ref: execution_context.credential_ref,
          execution_context: execution_context
        }

      _mismatch ->
        %{
          issue_id: nil,
          issue_identifier: "",
          issue_branch: nil,
          profile_key: nil,
          linear_project_id: nil,
          repository: nil,
          canonical_branch: nil,
          workspace_namespace: nil,
          credential_ref: nil,
          execution_context: :mismatch
        }
    end
  end

  defp issue_context(issue_or_identifier, nil), do: issue_context(issue_or_identifier)

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_branch: Map.get(issue, :branch_name),
      profile_key: nil,
      linear_project_id: nil,
      repository: nil,
      canonical_branch: nil,
      workspace_namespace: nil,
      credential_ref: nil,
      execution_context: nil
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_branch: nil,
      profile_key: nil,
      linear_project_id: nil,
      repository: nil,
      canonical_branch: nil,
      workspace_namespace: nil,
      credential_ref: nil,
      execution_context: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_branch: nil,
      profile_key: nil,
      linear_project_id: nil,
      repository: nil,
      canonical_branch: nil,
      workspace_namespace: nil,
      credential_ref: nil,
      execution_context: nil
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
