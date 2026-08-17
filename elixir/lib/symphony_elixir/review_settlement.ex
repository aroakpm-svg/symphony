defmodule SymphonyElixir.ReviewSettlement do
  @moduledoc """
  Design 4 readback gate for review and follow-up settlement.

  The caller supplies canonical Design 2 identities and durable EffectLedger
  operations. This module never reclassifies a finding, invents an operation
  identity, or performs an untracked mutation.
  """

  alias SymphonyElixir.FindingDisposition

  @type result :: {:settled, map()} | {:blocked, term()}

  @spec settle(map(), map()) :: result()
  def settle(decision, context) when is_map(decision) and is_map(context) do
    with {:ok, finding_key, lineage_key} <- canonical_identity(decision),
         :ok <- active_claim(context),
         :ok <- exact_head(context, finding_key),
         :ok <- no_unsafe_effects(context),
         result <- settle_disposition(decision, context, finding_key, lineage_key) do
      result
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  def settle(_decision, _context), do: {:blocked, :invalid_settlement_input}

  defp canonical_identity(decision) do
    with finding_key when is_map(finding_key) <- decision[:finding_key],
         lineage_key when is_map(lineage_key) <- decision[:finding_lineage_key],
         {:ok, {finding_key, lineage_key}} <-
           FindingDisposition.validate_canonical_keys(finding_key, lineage_key),
         true <- decision[:finding_key_digest] == finding_key.digest do
      {:ok, finding_key, lineage_key}
    else
      _invalid -> {:error, :invalid_settlement_identity}
    end
  end

  defp active_claim(%{claim: %{active?: true, claim_id: claim_id, generation: generation}})
       when is_binary(claim_id) and claim_id != "" and is_integer(generation) and generation > 0,
       do: :ok

  defp active_claim(_context), do: {:error, :settlement_claim_unverified}

  defp exact_head(context, finding_key) do
    if context[:current_head_sha] == finding_key.source_head_sha,
      do: :ok,
      else: {:error, :settlement_head_drift}
  end

  defp no_unsafe_effects(context) do
    operations = context[:operations]

    cond do
      not is_list(operations) -> {:error, :settlement_operations_unavailable}
      Enum.any?(operations, &(&1[:status] in [:pending, :unknown])) -> {:error, :settlement_reconciliation_required}
      conflicting_operations?(operations) -> {:error, :settlement_operation_conflict}
      true -> :ok
    end
  end

  defp conflicting_operations?(operations) do
    operations
    |> Enum.group_by(& &1[:operation_id])
    |> Enum.any?(fn {_id, entries} ->
      entries
      |> Enum.map(&{&1[:effect_type], &1[:request_fingerprint]})
      |> Enum.uniq()
      |> length() > 1
    end)
  end

  defp settle_disposition(%{disposition: :blocked_unverified}, _context, _finding_key, _lineage_key),
    do: {:blocked, :blocked_unverified}

  defp settle_disposition(%{disposition: :follow_up_required}, context, finding_key, lineage_key) do
    with :ok <-
           succeeded_effect(
             context,
             :linear_issue_create,
             :follow_up_issue,
             finding_key,
             lineage_key,
             :follow_up_required
           ),
         :ok <- follow_up_readback(context, lineage_key),
         :ok <- succeeded_effect(context, :github_comment, :reply, finding_key, lineage_key, :follow_up_required),
         :ok <- reply_readback(context, finding_key),
         :ok <- no_new_actionable_evidence(context),
         :ok <-
           succeeded_effect(
             context,
             :github_review_thread_resolve,
             :resolve,
             finding_key,
             lineage_key,
             :follow_up_required
           ),
         :ok <- resolved_readback(context, finding_key) do
      {:settled, evidence(:follow_up_settled, context, finding_key, lineage_key)}
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp settle_disposition(%{disposition: :fix_in_current_pr}, context, finding_key, lineage_key) do
    with :ok <- fix_evidence(context, finding_key),
         :ok <- succeeded_effect(context, :github_comment, :reply, finding_key, lineage_key, :fix_in_current_pr),
         :ok <- reply_readback(context, finding_key),
         :ok <- no_new_actionable_evidence(context),
         :ok <-
           succeeded_effect(
             context,
             :github_review_thread_resolve,
             :resolve,
             finding_key,
             lineage_key,
             :fix_in_current_pr
           ),
         :ok <- resolved_readback(context, finding_key) do
      {:settled, evidence(:fix_settled, context, finding_key, lineage_key)}
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp settle_disposition(%{disposition: :rejected} = decision, context, finding_key, lineage_key) do
    with :ok <- rejected_evidence(decision, context),
         :ok <- succeeded_effect(context, :github_comment, :reply, finding_key, lineage_key, :rejected),
         :ok <- reply_readback(context, finding_key),
         :ok <- no_new_actionable_evidence(context),
         :ok <-
           succeeded_effect(
             context,
             :github_review_thread_resolve,
             :resolve,
             finding_key,
             lineage_key,
             :rejected
           ),
         :ok <- resolved_readback(context, finding_key) do
      {:settled, evidence(:rejected_settled, context, finding_key, lineage_key)}
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp settle_disposition(_decision, _context, _finding_key, _lineage_key),
    do: {:blocked, :unsupported_settlement_disposition}

  defp succeeded_effect(context, effect_type, role, finding_key, lineage_key, disposition) do
    expected_id = get_in(context, [:operation_ids, role])

    case expected_operation_id(effect_type, context, finding_key, lineage_key, disposition) do
      {:ok, ^expected_id} ->
        with {:ok, ledger_id} <- ledger_operation_id(context, expected_id) do
          validate_succeeded_effect(
            context,
            effect_type,
            role,
            ledger_id,
            disposition,
            finding_key,
            lineage_key
          )
        end

      _invalid ->
        {:error, {:settlement_operation_identity_mismatch, role}}
    end
  end

  defp ledger_operation_id(context, operation_id) do
    case get_in(context, [:claim, :issue_id]) do
      issue_id when is_binary(issue_id) and issue_id != "" -> {:ok, issue_id <> ":" <> operation_id}
      _missing -> {:error, :settlement_issue_identity_unverified}
    end
  end

  defp validate_succeeded_effect(context, effect_type, role, expected_id, disposition, finding_key, lineage_key) do
    matches =
      Enum.filter(context.operations, fn operation ->
        operation[:operation_id] == expected_id and operation[:effect_type] == effect_type
      end)

    case matches do
      [%{status: :succeeded, request_fingerprint: fingerprint, native_resource: native}]
      when is_binary(fingerprint) and fingerprint != "" and is_map(native) ->
        with :ok <- validate_fingerprint(fingerprint, disposition, finding_key, lineage_key),
             do: validate_native_resource(role, native, context)

      [] ->
        {:error, {:settlement_effect_missing, role}}

      [%{status: :failed_no_effect}] ->
        {:error, {:settlement_effect_failed, role}}

      _entries ->
        {:error, {:settlement_effect_invalid, role}}
    end
  end

  defp validate_native_resource(:follow_up_issue, native, context) do
    readback = get_in(context, [:native_readback, :follow_up]) || %{}

    if same_resource_id?(resource_value(native, :id), resource_value(readback, :id)),
      do: :ok,
      else: {:error, {:settlement_native_resource_mismatch, :follow_up_issue}}
  end

  defp validate_native_resource(:reply, native, context) do
    readback = get_in(context, [:native_readback, :reply]) || %{}
    native_id = resource_value(native, :comment_id) || resource_value(native, :id)

    if same_resource_id?(native_id, resource_value(readback, :id)),
      do: :ok,
      else: {:error, {:settlement_native_resource_mismatch, :reply}}
  end

  defp validate_native_resource(:resolve, native, context) do
    readback = get_in(context, [:native_readback, :thread]) || %{}

    native_id =
      resource_value(native, :review_thread_id) || resource_value(native, :thread_id) ||
        resource_value(native, :id)

    if same_resource_id?(native_id, resource_value(readback, :review_thread_id)),
      do: :ok,
      else: {:error, {:settlement_native_resource_mismatch, :resolve}}
  end

  defp same_resource_id?(left, right),
    do: is_binary(left) and left != "" and left == right

  defp resource_value(resource, key) when is_map(resource),
    do: Map.get(resource, key) || Map.get(resource, Atom.to_string(key))

  defp expected_operation_id(:linear_issue_create, context, finding_key, lineage_key, _disposition) do
    FindingDisposition.operation_id(:linear_issue_create, %{
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      finding_lineage_key: lineage_key,
      destination: get_in(context, [:native_readback, :follow_up, :destination]),
      effect_type: :linear_issue_create
    })
  end

  defp expected_operation_id(:github_comment, _context, finding_key, _lineage_key, disposition) do
    FindingDisposition.operation_id(:github_comment, %{
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      review_thread_id: finding_key.review_thread_id,
      finding_key: finding_key,
      message_kind: message_kind(disposition),
      effect_type: :github_comment
    })
  end

  defp expected_operation_id(:github_review_thread_resolve, _context, finding_key, lineage_key, _disposition) do
    FindingDisposition.operation_id(:github_review_thread_resolve, %{
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      review_thread_id: finding_key.review_thread_id,
      finding_lineage_key: lineage_key,
      effect_type: :github_review_thread_resolve
    })
  end

  defp validate_fingerprint(fingerprint, disposition, finding_key, lineage_key) do
    case FindingDisposition.decode_request_fingerprint(fingerprint) do
      {:ok, intent} ->
        if intent[:disposition] == disposition and intent[:finding_key] == finding_key and
             intent[:finding_lineage_key] == lineage_key and
             intent[:evaluated_head_sha] == finding_key.source_head_sha,
           do: :ok,
           else: {:error, :settlement_fingerprint_identity_mismatch}

      _invalid ->
        {:error, :invalid_settlement_fingerprint}
    end
  end

  defp message_kind(:fix_in_current_pr), do: :fix
  defp message_kind(:follow_up_required), do: :follow_up
  defp message_kind(:rejected), do: :rejected

  defp follow_up_readback(context, lineage_key) do
    case get_in(context, [:native_readback, :follow_up]) do
      %{id: id, url: url, destination: "Backlog", finding_lineage_key_digest: digest, state: state}
      when is_binary(id) and id != "" and is_binary(url) and url != "" and
             state in ["Backlog", :backlog] and digest == lineage_key.digest ->
        :ok

      _readback ->
        {:error, :follow_up_readback_unverified}
    end
  end

  defp reply_readback(context, finding_key) do
    expected_body = context[:reply_body]

    case get_in(context, [:native_readback, :reply]) do
      %{id: id, body: ^expected_body, finding_key_digest: digest, head_sha: head_sha}
      when is_binary(id) and id != "" and digest == finding_key.digest and
             head_sha == finding_key.source_head_sha ->
        :ok

      _readback ->
        {:error, :reply_readback_unverified}
    end
  end

  defp resolved_readback(context, finding_key) do
    case get_in(context, [:native_readback, :thread]) do
      %{
        repository: repository,
        pull_request_number: number,
        review_thread_id: thread_id,
        resolved?: true,
        head_sha: head_sha
      } ->
        if repository == finding_key.repository and number == finding_key.pull_request_number and
             thread_id == finding_key.review_thread_id and head_sha == finding_key.source_head_sha,
           do: :ok,
           else: {:error, :resolve_readback_identity_mismatch}

      _readback ->
        {:error, :resolve_readback_unverified}
    end
  end

  defp no_new_actionable_evidence(context) do
    readback = context[:native_readback] || %{}

    cond do
      readback[:reopened?] == true -> {:error, :review_thread_reopened}
      readback[:newer_trusted_actionable?] == true -> {:error, :newer_trusted_actionable_finding}
      true -> :ok
    end
  end

  defp fix_evidence(context, finding_key) do
    case context[:path_evidence] do
      %{managed_publish_confirmed?: true, regression_status: :pass, accepted_review_head_sha: head_sha}
      when head_sha == finding_key.source_head_sha ->
        :ok

      _evidence ->
        {:error, :fix_settlement_evidence_unverified}
    end
  end

  defp rejected_evidence(decision, context) do
    case FindingDisposition.classify(decision[:facts] || %{}, %{
           verified?: true,
           valid?: true,
           current_head_sha: context[:current_head_sha]
         }) do
      {:ok, %{disposition: :rejected, finding_key_digest: digest}}
      when digest == decision.finding_key_digest ->
        :ok

      _invalid ->
        {:error, :rejection_proof_unverified}
    end
  end

  defp evidence(status, context, finding_key, lineage_key) do
    %{
      status: status,
      disposition: status_to_disposition(status),
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      review_thread_id: finding_key.review_thread_id,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      exact_head_sha: finding_key.source_head_sha,
      claim: context.claim,
      operation_ids: context.operation_ids,
      native_readback: context.native_readback,
      merge_authorized?: false
    }
  end

  defp status_to_disposition(:fix_settled), do: :fix_in_current_pr
  defp status_to_disposition(:follow_up_settled), do: :follow_up_required
  defp status_to_disposition(:rejected_settled), do: :rejected
end
