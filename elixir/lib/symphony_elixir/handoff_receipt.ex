defmodule SymphonyElixir.HandoffReceipt do
  @moduledoc """
  Persists and validates the small, structured ARO-166 handoff receipt.

  A receipt is only a hint about the last durable safe point. `resume/2` requires
  callers to provide freshly observed Git, GitHub, Linear, claim, and ledger
  state before a pending step can be selected.
  """

  alias SymphonyElixir.Workspace

  @schema_version 1
  @steps ~w(preflight branch implementation tests commit push pull_request review)a
  @phases ~w(preflight implementation verification delivery review complete)a
  @receipt_keys ~w(
    receipt_schema_version issue_id canonical_owner canonical_repository claim_id generation
    checkpoint_sequence recorded_at linear_updated_at branch worktree_fingerprint remote_branch_sha
    commit_sha pr_number current_phase completed_step_ids
    pending_step_ids test_results effect_operation_ids
  )a

  @type test_result :: %{name: String.t(), status: :passed | :failed | :skipped}
  @type receipt :: %{
          receipt_schema_version: 1,
          issue_id: String.t(),
          canonical_owner: String.t(),
          canonical_repository: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          checkpoint_sequence: pos_integer(),
          recorded_at: DateTime.t(),
          linear_updated_at: DateTime.t(),
          branch: String.t(),
          worktree_fingerprint: String.t(),
          remote_branch_sha: String.t() | nil,
          commit_sha: String.t() | nil,
          pr_number: pos_integer() | nil,
          current_phase: atom(),
          completed_step_ids: [atom()],
          pending_step_ids: [atom()],
          test_results: [test_result()],
          effect_operation_ids: [String.t()]
        }

  @type truth :: %{
          required(:issue_id) => String.t(),
          required(:canonical_owner) => String.t(),
          required(:canonical_repository) => String.t(),
          required(:branch) => String.t(),
          required(:worktree_fingerprint) => String.t(),
          required(:remote_branch_sha) => String.t() | nil,
          required(:commit_sha) => String.t() | nil,
          required(:pr_number) => pos_integer() | nil,
          required(:pr_ready?) => boolean(),
          required(:linear_updated_at) => DateTime.t(),
          required(:active_claim?) => boolean(),
          required(:effect_operations) => %{optional(String.t()) => :succeeded}
        }

  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @spec step_ids() :: [atom()]
  def step_ids, do: @steps

  @spec phases() :: [atom()]
  def phases, do: @phases

  @spec workspace_evidence(Path.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok,
           %{
             worktree_fingerprint: String.t(),
             remote_branch_sha: String.t() | nil,
             head_sha: String.t(),
             clean?: boolean()
           }}
          | {:error, term()}
  def workspace_evidence(workspace, branch, canonical_repository, worker_host)
      when is_binary(workspace) and is_binary(branch) and is_binary(canonical_repository) do
    with {:ok, checked_out_branch} <- checked_out_branch(workspace, branch, worker_host),
         {:ok, status} <- Workspace.run_git_command(workspace, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], worker_host),
         {:ok, diff} <- Workspace.run_git_command(workspace, ["diff", "--binary", "HEAD"], worker_host),
         {:ok, cached} <- Workspace.run_git_command(workspace, ["diff", "--binary", "--cached", "HEAD"], worker_host),
         {:ok, head_sha} <- Workspace.run_git_command(workspace, ["rev-parse", "HEAD"], worker_host),
         {:ok, untracked_hashes} <- hash_untracked_files(workspace, status, worker_host),
         {:ok, origin_repository} <- canonical_origin_repository(workspace, canonical_repository, worker_host),
         {:ok, remote_sha} <- remote_branch_sha(workspace, branch, worker_host) do
      fingerprint =
        :sha256
        |> :crypto.hash([
          checked_out_branch,
          status,
          diff,
          cached,
          untracked_hashes,
          origin_repository
        ])
        |> Base.encode16(case: :lower)

      {:ok,
       %{
         worktree_fingerprint: fingerprint,
         remote_branch_sha: remote_sha,
         head_sha: head_sha |> String.trim() |> String.downcase(),
         clean?: status == ""
       }}
    end
  end

  defp checked_out_branch(workspace, expected_branch, worker_host) do
    case Workspace.run_git_command(
           workspace,
           ["symbolic-ref", "--quiet", "--short", "HEAD"],
           worker_host
         ) do
      {:ok, branch} -> validate_checked_out_branch(String.trim(branch), expected_branch)
      {:error, _reason} -> {:error, :handoff_branch_mismatch}
    end
  end

  defp validate_checked_out_branch(branch, branch) when branch != "", do: {:ok, branch}
  defp validate_checked_out_branch(_actual, _expected), do: {:error, :handoff_branch_mismatch}

  defp canonical_origin_repository(workspace, expected_repository, worker_host) do
    with {:ok, url} <- Workspace.run_git_command(workspace, ["config", "--get", "remote.origin.url"], worker_host),
         {:ok, actual_repository} <- github_repository_from_remote(url),
         true <- String.downcase(actual_repository) == String.downcase(expected_repository) do
      {:ok, String.downcase(actual_repository)}
    else
      false -> {:error, :handoff_origin_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp github_repository_from_remote(url) do
    remote = String.trim(url)

    case Regex.run(~r{^git@github\.com:([^/\s]+/[^/\s]+?)(?:\.git)?/?$}i, remote, capture: :all_but_first) do
      [repository] -> {:ok, repository}
      _other -> github_repository_from_uri(remote)
    end
  end

  defp github_repository_from_uri(remote) do
    uri = URI.parse(remote)

    cond do
      uri.scheme not in ["http", "https", "ssh"] ->
        {:error, :handoff_origin_invalid}

      not is_binary(uri.host) or String.downcase(uri.host) != "github.com" ->
        {:error, :handoff_origin_invalid}

      uri.scheme == "ssh" and uri.userinfo != "git" ->
        {:error, :handoff_origin_invalid}

      true ->
        repository_from_uri_path(uri.path)
    end
  end

  defp repository_from_uri_path(path) when is_binary(path) do
    case Regex.run(~r{^/([^/\s]+/[^/\s]+?)(?:\.git)?/?$}, path, capture: :all_but_first) do
      [repository] -> {:ok, repository}
      _other -> {:error, :handoff_origin_invalid}
    end
  end

  defp repository_from_uri_path(_path), do: {:error, :handoff_origin_invalid}

  @doc false
  @spec decode_row_for_test(list()) :: {:ok, receipt()} | {:error, :receipt_incompatible}
  def decode_row_for_test(row), do: decode_row(row)

  @doc false
  @spec github_repository_from_remote_for_test(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def github_repository_from_remote_for_test(url), do: github_repository_from_remote(url)

  @doc false
  @spec validate_checked_out_branch_for_test(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :handoff_branch_mismatch}
  def validate_checked_out_branch_for_test(actual, expected),
    do: validate_checked_out_branch(actual, expected)

  @doc false
  @spec append_sql_for_test() :: String.t()
  def append_sql_for_test, do: append_sql()

  @doc false
  @spec append_params_for_test(map(), map()) :: list()
  def append_params_for_test(claim, attrs), do: append_params(claim, attrs)

  @spec append(Postgrex.conn(), map(), map()) :: {:ok, receipt()} | {:error, term()}
  def append(connection, claim, attrs) when is_map(claim) and is_map(attrs) do
    with :ok <- validate_attrs(attrs),
         params <- append_params(claim, attrs),
         {:ok, %Postgrex.Result{rows: [row]}} <-
           Postgrex.query(connection, append_sql(), params) do
      decode_row(row)
    else
      {:ok, result} -> {:error, {:unexpected_receipt_result, result.num_rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec latest(Postgrex.conn(), map()) :: {:ok, receipt() | nil} | {:error, term()}
  def latest(connection, claim) when is_map(claim) do
    params = claim_params(claim)

    case Postgrex.query(connection, latest_sql(), params) do
      {:ok, %Postgrex.Result{rows: []}} -> {:ok, nil}
      {:ok, %Postgrex.Result{rows: [row]}} -> decode_row(row)
      {:ok, result} -> {:error, {:unexpected_receipt_result, result.num_rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec effect_statuses(Postgrex.conn(), map(), [String.t()]) ::
          {:ok, %{optional(String.t()) => :succeeded | :failed_no_effect | :unknown}}
          | {:error, term()}
  def effect_statuses(connection, claim, operation_ids)
      when is_map(claim) and is_list(operation_ids) do
    params = claim_params(claim) ++ [operation_ids]

    case Postgrex.query(connection, effect_statuses_sql(), params) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        {:ok, Map.new(rows, fn [operation_id, status] -> {operation_id, decode_effect_status(status)} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def effect_statuses(_connection, _claim, _operation_ids),
    do: {:error, :invalid_effect_operation_ids}

  @doc "Returns the next pending step only when every external truth matches."
  @spec resume(receipt() | nil, truth()) :: {:ok, atom() | :complete} | {:safe_recheck, term()}
  def resume(nil, _truth), do: {:safe_recheck, :receipt_missing}

  def resume(receipt, truth) when is_map(receipt) and is_map(truth) do
    with :ok <- validate_decoded(receipt),
         :ok <- verify_truth(receipt, truth) do
      case receipt.pending_step_ids do
        [next | _] -> {:ok, next}
        [] -> {:ok, :complete}
      end
    else
      {:error, reason} -> {:safe_recheck, reason}
    end
  end

  def resume(_receipt, _truth), do: {:safe_recheck, :receipt_incompatible}

  defp validate_attrs(attrs) do
    with :ok <- validate_identity(attrs),
         :ok <- validate_progress(attrs),
         :ok <- validate_artifacts(attrs),
         do: validate_evidence(attrs)
  end

  defp validate_identity(attrs) do
    cond do
      not nonempty_string?(Map.get(attrs, :canonical_owner)) ->
        {:error, :invalid_canonical_owner}

      not nonempty_string?(Map.get(attrs, :canonical_repository)) ->
        {:error, :invalid_canonical_repository}

      not nonempty_string?(Map.get(attrs, :branch)) ->
        {:error, :invalid_branch}

      not valid_commit_sha?(Map.get(attrs, :commit_sha)) ->
        {:error, :invalid_commit_sha}

      not valid_pr_number?(Map.get(attrs, :pr_number)) ->
        {:error, :invalid_pr_number}

      not valid_fingerprint?(Map.get(attrs, :worktree_fingerprint)) ->
        {:error, :invalid_worktree_fingerprint}

      not valid_commit_sha?(Map.get(attrs, :remote_branch_sha)) ->
        {:error, :invalid_remote_branch_sha}

      true ->
        :ok
    end
  end

  defp validate_progress(attrs) do
    completed = Map.get(attrs, :completed_step_ids, [])
    pending = Map.get(attrs, :pending_step_ids, [])

    cond do
      Map.get(attrs, :current_phase) not in @phases ->
        {:error, :invalid_phase}

      not valid_unique_subset?(completed, @steps) ->
        {:error, :invalid_completed_steps}

      not valid_unique_subset?(pending, @steps) ->
        {:error, :invalid_pending_steps}

      not MapSet.disjoint?(MapSet.new(completed), MapSet.new(pending)) ->
        {:error, :overlapping_steps}

      not all_steps_accounted_for?(completed, pending) ->
        {:error, :incomplete_step_accounting}

      completed ++ pending != @steps ->
        {:error, :noncanonical_step_order}

      not consistent_completion?(Map.get(attrs, :current_phase), completed, pending) ->
        {:error, :inconsistent_progress}

      true ->
        :ok
    end
  end

  defp validate_artifacts(attrs) do
    completed = Map.get(attrs, :completed_step_ids, [])

    cond do
      :commit in completed != is_binary(Map.get(attrs, :commit_sha)) ->
        {:error, :inconsistent_commit_artifact}

      :pull_request in completed != is_integer(Map.get(attrs, :pr_number)) ->
        {:error, :inconsistent_pull_request_artifact}

      :push in completed and Map.get(attrs, :remote_branch_sha) != Map.get(attrs, :commit_sha) ->
        {:error, :inconsistent_push_artifact}

      true ->
        :ok
    end
  end

  defp validate_evidence(attrs) do
    cond do
      not valid_tests?(Map.get(attrs, :test_results, [])) ->
        {:error, :invalid_test_results}

      tests_completed_without_evidence?(attrs) ->
        {:error, :missing_test_evidence}

      failed_tests_marked_complete?(attrs) ->
        {:error, :failed_tests_marked_complete}

      not valid_effect_operation_ids?(Map.get(attrs, :effect_operation_ids, [])) ->
        {:error, :invalid_effect_operation_ids}

      true ->
        :ok
    end
  end

  defp validate_decoded(%{receipt_schema_version: @schema_version} = receipt) do
    if Enum.all?(@receipt_keys, &Map.has_key?(receipt, &1)) and valid_receipt_metadata?(receipt) do
      validate_attrs(receipt)
    else
      {:error, :receipt_incompatible}
    end
  end

  defp validate_decoded(_receipt), do: {:error, :receipt_incompatible}

  defp valid_receipt_metadata?(receipt) do
    nonempty_string?(receipt.issue_id) and valid_uuid?(receipt.claim_id) and
      is_integer(receipt.generation) and receipt.generation > 0 and
      is_integer(receipt.checkpoint_sequence) and receipt.checkpoint_sequence > 0 and
      match?(%DateTime{}, receipt.recorded_at) and
      match?(%DateTime{}, receipt.linear_updated_at)
  end

  defp verify_truth(receipt, truth) do
    checks = [
      {:issue_id, receipt.issue_id},
      {:canonical_owner, receipt.canonical_owner},
      {:canonical_repository, receipt.canonical_repository},
      {:branch, receipt.branch},
      {:worktree_fingerprint, receipt.worktree_fingerprint},
      {:remote_branch_sha, receipt.remote_branch_sha},
      {:commit_sha, receipt.commit_sha},
      {:pr_number, receipt.pr_number}
    ]

    cond do
      Enum.any?(checks, fn {key, expected} -> Map.get(truth, key) != expected end) ->
        {:error, :git_or_repository_state_changed}

      not same_datetime?(Map.get(truth, :linear_updated_at), receipt.linear_updated_at) ->
        {:error, :linear_revision_changed}

      Map.get(truth, :active_claim?) != true ->
        {:error, :claim_inactive}

      receipt.pr_number != nil and Map.get(truth, :pr_ready?) != true ->
        {:error, :pr_not_ready}

      not effect_ledger_matches?(receipt, truth) ->
        {:error, :effect_ledger_changed}

      true ->
        :ok
    end
  end

  defp effect_ledger_matches?(receipt, truth) do
    operations = Map.get(truth, :effect_operations, %{})

    is_map(operations) and
      MapSet.equal?(MapSet.new(Map.keys(operations)), MapSet.new(receipt.effect_operation_ids)) and
      Enum.all?(operations, fn {_operation_id, status} -> status == :succeeded end)
  end

  defp valid_unique_subset?(values, allowlist) when is_list(values) do
    Enum.all?(values, &(&1 in allowlist)) and length(values) == MapSet.size(MapSet.new(values))
  end

  defp valid_unique_subset?(_values, _allowlist), do: false

  defp all_steps_accounted_for?(completed, pending) do
    completed
    |> MapSet.new()
    |> MapSet.union(MapSet.new(pending))
    |> MapSet.equal?(MapSet.new(@steps))
  end

  defp consistent_completion?(:complete, completed, []),
    do: MapSet.equal?(MapSet.new(completed), MapSet.new(@steps))

  defp consistent_completion?(:complete, _completed, _pending), do: false
  defp consistent_completion?(_phase, _completed, []), do: false
  defp consistent_completion?(_phase, _completed, _pending), do: true

  defp valid_tests?(tests) when is_list(tests) do
    Enum.all?(tests, fn
      %{name: name, status: status} = result when is_binary(name) ->
        map_size(result) == 2 and status in [:passed, :failed, :skipped] and
          nonempty_string?(name)

      _other ->
        false
    end)
  end

  defp valid_tests?(_tests), do: false

  defp tests_completed_without_evidence?(attrs) do
    :tests in Map.get(attrs, :completed_step_ids, []) and
      Map.get(attrs, :test_results, []) == []
  end

  defp failed_tests_marked_complete?(attrs) do
    :tests in Map.get(attrs, :completed_step_ids, []) and
      Enum.any?(Map.get(attrs, :test_results, []), &(&1.status == :failed))
  end

  defp valid_effect_operation_ids?(values) when is_list(values) do
    pattern = ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}:[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/

    Enum.all?(values, &(is_binary(&1) and Regex.match?(pattern, &1))) and
      length(values) == MapSet.size(MapSet.new(values))
  end

  defp valid_effect_operation_ids?(_values), do: false

  defp nonempty_string?(value), do: is_binary(value) and byte_size(String.trim(value)) > 0
  defp valid_commit_sha?(nil), do: true
  defp valid_commit_sha?(sha) when is_binary(sha), do: Regex.match?(~r/^[0-9a-f]{40}$/, sha)
  defp valid_commit_sha?(_sha), do: false
  defp valid_pr_number?(nil), do: true
  defp valid_pr_number?(number), do: is_integer(number) and number > 0
  defp valid_fingerprint?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f]{64}$/, value)
  defp valid_fingerprint?(_value), do: false
  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp append_params(claim, attrs) do
    claim_params(claim) ++
      [
        @schema_version,
        Map.fetch!(attrs, :canonical_owner),
        Map.fetch!(attrs, :canonical_repository),
        Map.fetch!(attrs, :branch),
        Map.fetch!(attrs, :worktree_fingerprint),
        Map.get(attrs, :remote_branch_sha),
        Map.get(attrs, :commit_sha),
        Map.get(attrs, :pr_number),
        Atom.to_string(Map.fetch!(attrs, :current_phase)),
        Enum.map(Map.get(attrs, :completed_step_ids, []), &Atom.to_string/1),
        Enum.map(Map.get(attrs, :pending_step_ids, []), &Atom.to_string/1),
        Enum.map(Map.get(attrs, :test_results, []), fn result ->
          %{"name" => result.name, "status" => Atom.to_string(result.status)}
        end),
        Map.get(attrs, :effect_operation_ids, [])
      ]
  end

  defp claim_params(claim) do
    [
      Map.fetch!(claim, :issue_id),
      Map.fetch!(claim, :claim_id),
      Map.fetch!(claim, :generation),
      Map.fetch!(claim, :node_id),
      Map.fetch!(claim, :node_instance_id)
    ]
  end

  defp append_sql do
    """
    select #{receipt_columns()} from symphony_staging.append_handoff_receipt(
      $1, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid,
      $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::text[], $16::text[], $17::jsonb, $18::text[]
    )
    """
  end

  defp latest_sql do
    """
    select #{receipt_columns()} from symphony_staging.latest_handoff_receipt(
      $1, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid
    )
    """
  end

  defp effect_statuses_sql do
    """
    select operation_id, status from symphony_staging.handoff_effect_statuses(
      $1, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid, $6::text[]
    )
    """
  end

  defp decode_effect_status("succeeded"), do: :succeeded
  defp decode_effect_status("failed-no-effect"), do: :failed_no_effect
  defp decode_effect_status(_status), do: :unknown

  defp receipt_columns do
    """
    receipt_schema_version, issue_id, canonical_owner, canonical_repository,
    claim_id::text as claim_id, generation, checkpoint_sequence, recorded_at, linear_updated_at,
    branch, worktree_fingerprint, remote_branch_sha, commit_sha,
    pr_number, current_phase, completed_step_ids, pending_step_ids, test_results,
    effect_operation_ids
    """
    |> String.replace("\n", " ")
    |> String.trim()
  end

  defp decode_row([version | _rest]) when version != @schema_version,
    do: {:error, :receipt_incompatible}

  defp decode_row([
         @schema_version = version,
         issue_id,
         owner,
         repository,
         claim_id,
         generation,
         sequence,
         recorded_at,
         linear_updated_at,
         branch,
         worktree_fingerprint,
         remote_branch_sha,
         commit_sha,
         pr_number,
         phase,
         completed,
         pending,
         tests,
         effects
       ]) do
    with {:ok, decoded_phase} <- decode_allowed_atom(phase, @phases),
         {:ok, decoded_completed} <- decode_allowed_atoms(completed, @steps),
         {:ok, decoded_pending} <- decode_allowed_atoms(pending, @steps),
         {:ok, decoded_tests} <- decode_test_results(tests) do
      {:ok,
       %{
         receipt_schema_version: version,
         issue_id: issue_id,
         canonical_owner: owner,
         canonical_repository: repository,
         claim_id: claim_id,
         generation: generation,
         checkpoint_sequence: sequence,
         recorded_at: recorded_at,
         linear_updated_at: linear_updated_at,
         branch: branch,
         worktree_fingerprint: worktree_fingerprint,
         remote_branch_sha: remote_branch_sha,
         commit_sha: commit_sha,
         pr_number: pr_number,
         current_phase: decoded_phase,
         completed_step_ids: decoded_completed,
         pending_step_ids: decoded_pending,
         test_results: decoded_tests,
         effect_operation_ids: effects
       }}
    end
  end

  defp decode_row(_row), do: {:error, :receipt_incompatible}

  defp decode_allowed_atoms(values, allowlist) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case decode_allowed_atom(value, allowlist) do
        {:ok, atom} -> {:cont, {:ok, [atom | decoded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_allowed_atoms(_values, _allowlist), do: {:error, :receipt_incompatible}

  defp decode_allowed_atom(value, allowlist) when is_binary(value) do
    case Enum.find(allowlist, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :receipt_incompatible}
      atom -> {:ok, atom}
    end
  end

  defp decode_allowed_atom(_value, _allowlist), do: {:error, :receipt_incompatible}

  defp decode_test_results(tests) when is_list(tests) do
    Enum.reduce_while(tests, {:ok, []}, fn
      %{"name" => name, "status" => status} = result, {:ok, decoded} ->
        if map_size(result) == 2 and nonempty_string?(name) and
             status in ["passed", "failed", "skipped"] do
          {:cont, {:ok, [%{name: name, status: String.to_existing_atom(status)} | decoded]}}
        else
          {:halt, {:error, :receipt_incompatible}}
        end

      _result, _decoded ->
        {:halt, {:error, :receipt_incompatible}}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_test_results(_tests), do: {:error, :receipt_incompatible}

  defp hash_untracked_files(workspace, status, worker_host) do
    status
    |> String.split(<<0>>, trim: true)
    |> Enum.filter(&String.starts_with?(&1, "?? "))
    |> Enum.map(&String.slice(&1, 3..-1//1))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, hashes} ->
      args = ["diff", "--no-index", "--binary", "--no-prefix", "--", "/dev/null", path]

      case Workspace.run_git_command_with_status(workspace, args, worker_host) do
        {:ok, 1, evidence} ->
          {:cont, {:ok, [[path, evidence] | hashes]}}

        {:ok, 0, evidence} ->
          {:cont, {:ok, [[path, evidence] | hashes]}}

        {:ok, status, _evidence} ->
          {:halt, {:error, {:untracked_hash_failed, path, status}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hashes} -> {:ok, hashes |> Enum.reverse() |> :erlang.term_to_binary()}
      error -> error
    end
  end

  defp remote_branch_sha(workspace, branch, worker_host) do
    ref = "refs/heads/#{branch}"

    case Workspace.run_git_command(workspace, ["ls-remote", "--heads", "origin", ref], worker_host) do
      {:ok, output} ->
        case String.split(String.trim(output), ~r/\s+/, trim: true) do
          [] -> {:ok, nil}
          [sha, ^ref] when byte_size(sha) == 40 -> {:ok, String.downcase(sha)}
          _other -> {:error, :invalid_remote_branch_evidence}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
