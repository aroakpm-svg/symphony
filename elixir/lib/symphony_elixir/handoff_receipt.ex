defmodule SymphonyElixir.HandoffReceipt do
  @moduledoc """
  Persists and validates the small, structured ARO-166 handoff receipt.

  A receipt is only a hint about the last durable safe point. `resume/2` requires
  callers to provide freshly observed Git, GitHub, Linear, claim, and ledger
  state before a pending step can be selected.
  """

  @schema_version 1
  @steps ~w(preflight branch implementation tests commit push pull_request review)a
  @phases ~w(preflight implementation verification delivery review complete)a

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
          branch: String.t(),
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
          required(:commit_sha) => String.t() | nil,
          required(:pr_number) => pos_integer() | nil,
          required(:pr_ready?) => boolean(),
          required(:linear_revision_current?) => boolean(),
          required(:active_claim?) => boolean(),
          required(:effect_operations) => %{optional(String.t()) => :succeeded | :failed_no_effect}
        }

  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @spec step_ids() :: [atom()]
  def step_ids, do: @steps

  @spec phases() :: [atom()]
  def phases, do: @phases

  @doc false
  @spec decode_row_for_test(list()) :: {:ok, receipt()} | {:error, :receipt_incompatible}
  def decode_row_for_test(row), do: decode_row(row)

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

      true ->
        :ok
    end
  end

  defp validate_evidence(attrs) do
    cond do
      not valid_tests?(Map.get(attrs, :test_results, [])) ->
        {:error, :invalid_test_results}

      not unique_nonempty_strings?(Map.get(attrs, :effect_operation_ids, [])) ->
        {:error, :invalid_effect_operation_ids}

      true ->
        :ok
    end
  end

  defp validate_decoded(%{receipt_schema_version: @schema_version} = receipt),
    do: validate_attrs(receipt)

  defp validate_decoded(_receipt), do: {:error, :receipt_incompatible}

  defp verify_truth(receipt, truth) do
    checks = [
      {:issue_id, receipt.issue_id},
      {:canonical_owner, receipt.canonical_owner},
      {:canonical_repository, receipt.canonical_repository},
      {:branch, receipt.branch},
      {:commit_sha, receipt.commit_sha},
      {:pr_number, receipt.pr_number}
    ]

    cond do
      Enum.any?(checks, fn {key, expected} -> Map.get(truth, key) != expected end) ->
        {:error, :git_or_repository_state_changed}

      Map.get(truth, :linear_revision_current?) != true ->
        {:error, :linear_revision_changed}

      Map.get(truth, :active_claim?) != true ->
        {:error, :claim_inactive}

      Map.get(truth, :pr_ready?) != true ->
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
      MapSet.new(Map.keys(operations)) == MapSet.new(receipt.effect_operation_ids) and
      Enum.all?(operations, fn {_operation_id, status} ->
        status in [:succeeded, :failed_no_effect]
      end)
  end

  defp valid_unique_subset?(values, allowlist) when is_list(values) do
    Enum.all?(values, &(&1 in allowlist)) and length(values) == MapSet.size(MapSet.new(values))
  end

  defp valid_unique_subset?(_values, _allowlist), do: false

  defp valid_tests?(tests) when is_list(tests) do
    Enum.all?(tests, fn
      %{name: name, status: status} = result when is_binary(name) and byte_size(name) > 0 ->
        map_size(result) == 2 and status in [:passed, :failed, :skipped]

      _other ->
        false
    end)
  end

  defp valid_tests?(_tests), do: false

  defp unique_nonempty_strings?(values) when is_list(values) do
    Enum.all?(values, &(is_binary(&1) and byte_size(String.trim(&1)) > 0)) and
      length(values) == MapSet.size(MapSet.new(values))
  end

  defp unique_nonempty_strings?(_values), do: false

  defp nonempty_string?(value), do: is_binary(value) and byte_size(String.trim(value)) > 0
  defp valid_commit_sha?(nil), do: true
  defp valid_commit_sha?(sha) when is_binary(sha), do: Regex.match?(~r/^[0-9a-f]{40}$/, sha)
  defp valid_commit_sha?(_sha), do: false
  defp valid_pr_number?(nil), do: true
  defp valid_pr_number?(number), do: is_integer(number) and number > 0

  defp append_params(claim, attrs) do
    claim_params(claim) ++
      [
        @schema_version,
        Map.fetch!(attrs, :canonical_owner),
        Map.fetch!(attrs, :canonical_repository),
        Map.fetch!(attrs, :branch),
        Map.get(attrs, :commit_sha),
        Map.get(attrs, :pr_number),
        Atom.to_string(Map.fetch!(attrs, :current_phase)),
        Enum.map(Map.get(attrs, :completed_step_ids, []), &Atom.to_string/1),
        Enum.map(Map.get(attrs, :pending_step_ids, []), &Atom.to_string/1),
        Jason.encode!(Map.get(attrs, :test_results, [])),
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
      $6, $7, $8, $9, $10, $11, $12::text[], $13::text[], $14::jsonb, $15::text[]
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

  defp receipt_columns do
    """
    receipt_schema_version, issue_id, canonical_owner, canonical_repository,
    claim_id, generation, checkpoint_sequence, recorded_at, branch, commit_sha,
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
         branch,
         commit_sha,
         pr_number,
         phase,
         completed,
         pending,
         tests,
         effects
       ]) do
    with {:ok, decoded_tests} <- decode_test_results(tests) do
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
         branch: branch,
         commit_sha: commit_sha,
         pr_number: pr_number,
         current_phase: String.to_existing_atom(phase),
         completed_step_ids: Enum.map(completed, &String.to_existing_atom/1),
         pending_step_ids: Enum.map(pending, &String.to_existing_atom/1),
         test_results: decoded_tests,
         effect_operation_ids: effects
       }}
    end
  end

  defp decode_row(_row), do: {:error, :receipt_incompatible}

  defp decode_test_results(tests) when is_list(tests) do
    Enum.reduce_while(tests, {:ok, []}, fn
      %{"name" => name, "status" => status}, {:ok, decoded}
      when is_binary(name) and name != "" and status in ["passed", "failed", "skipped"] ->
        {:cont, {:ok, [%{name: name, status: String.to_existing_atom(status)} | decoded]}}

      _result, _decoded ->
        {:halt, {:error, :receipt_incompatible}}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_test_results(_tests), do: {:error, :receipt_incompatible}
end
