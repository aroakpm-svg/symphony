defmodule SymphonyElixir.ReviewSettlementReceipt do
  @moduledoc "Persists the terminal ReviewSettlement proof in EffectLedger."

  alias SymphonyElixir.{FindingDisposition, ReviewIdentity}

  @spec reconcile_pending(term(), module(), map(), [map()]) :: :ok | {:error, term()}
  def reconcile_pending(connection, ledger, claim, operations) when is_list(operations) do
    operations
    |> Enum.filter(&(&1[:effect_type] == :review_settlement_receipt and &1[:status] in [:pending, :unknown]))
    |> Enum.reduce_while(:ok, fn operation, :ok ->
      case reconcile_operation(connection, ledger, claim, operation) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def reconcile_pending(_connection, _ledger, _claim, _operations),
    do: {:error, :invalid_pending_settlement_operations}

  defp reconcile_operation(connection, ledger, claim, operation) do
    with {:ok, receipt} <- ReviewIdentity.reconcile_receipt(%{original_receipt: operation[:native_resource]}),
         context <- pending_context(operation, claim),
         {:ok, stored} <- execute_receipt(ledger, connection, context, receipt),
         true <- same_receipt?(stored, receipt) do
      :ok
    else
      false -> {:error, :settlement_receipt_mismatch}
      {:error, :terminal_receipt_evidence_unavailable} -> {:error, :terminal_receipt_evidence_unavailable}
      _invalid -> {:error, :invalid_pending_settlement_receipt}
    end
  end

  defp pending_context(operation, claim) do
    Map.merge(claim, %{
      operation_id: bare_operation_id(operation[:operation_id], claim[:issue_id]),
      request_fingerprint: operation[:request_fingerprint]
    })
  end

  defp execute_receipt(ledger, connection, context, resource) do
    ledger.execute(
      connection,
      :review_settlement_receipt,
      context,
      fn -> {:ok, resource} end,
      fn -> {:found, resource} end
    )
  end

  @spec record(term(), module(), map(), map(), map(), [map()]) :: {:ok, map()} | {:error, term()}
  def record(connection, ledger, claim, decision, evidence, operations) do
    with {:ok, receipt} <- receipt_from_evidence(evidence),
         :ok <- bound_to_sibling_effects?(decision, operations),
         {:ok, fingerprint} <- receipt_fingerprint(decision, evidence),
         context <- Map.merge(claim, %{operation_id: operation_id(fingerprint), request_fingerprint: fingerprint}),
         {:ok, stored} <-
           ledger.execute(
             connection,
             :review_settlement_receipt,
             context,
             fn -> {:ok, receipt} end,
             fn -> {:found, receipt} end
           ),
         true <- same_receipt?(stored, receipt) do
      {:ok, stored}
    else
      false -> {:error, :settlement_receipt_mismatch}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_settlement_receipt}
    end
  end

  defp receipt_from_evidence(%{receipt: receipt}) when is_map(receipt) do
    ReviewIdentity.reconcile_receipt(%{original_receipt: receipt})
  end

  defp receipt_from_evidence(evidence) when is_map(evidence) do
    ReviewIdentity.build_settlement_receipt(evidence)
  end

  defp receipt_from_evidence(_evidence), do: {:error, :invalid_settlement_receipt}

  defp same_receipt?(stored, expected) do
    with {:ok, left} <- ReviewIdentity.reconcile_receipt(%{original_receipt: stored}),
         {:ok, right} <- ReviewIdentity.reconcile_receipt(%{original_receipt: expected}) do
      left.digest == right.digest
    else
      _invalid -> false
    end
  end

  defp bound_to_sibling_effects?(decision, operations) when is_list(operations) do
    if Enum.any?(operations, &matching_sibling_effect?(&1, decision)) do
      :ok
    else
      {:error, :settlement_fingerprint_unavailable}
    end
  end

  defp bound_to_sibling_effects?(_decision, _operations), do: {:error, :settlement_fingerprint_unavailable}

  defp matching_sibling_effect?(operation, decision) do
    case FindingDisposition.decode_request_fingerprint(operation[:request_fingerprint]) do
      {:ok, intent} ->
        sibling_finding_digest(intent) == decision.finding_key_digest and
          intent[:disposition] == decision.disposition

      _invalid ->
        false
    end
  end

  defp sibling_finding_digest(intent), do: get_in(intent, [:finding_key, :digest])

  defp receipt_fingerprint(decision, evidence) do
    evaluated_head_sha =
      get_in(evidence, [:receipt, :evaluation_key, :evaluated_head_sha]) ||
        get_in(evidence, [:evaluation_key, :evaluated_head_sha])

    if is_binary(decision[:finding_key_digest]) and decision[:finding_key_digest] != "" and
         decision[:disposition] in [:fix_in_current_pr, :follow_up_required, :rejected] and
         is_binary(evaluated_head_sha) do
      identity = {decision.finding_key_digest, decision.disposition, evaluated_head_sha}
      payload = :erlang.term_to_binary({:symphony_settlement_receipt_identity_v1, identity}, [:deterministic])

      hash = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
      {:ok, "symphony_settlement_receipt_v1:" <> hash}
    else
      {:error, :settlement_fingerprint_unavailable}
    end
  end

  defp operation_id(fingerprint),
    do: "review-settlement-receipt-" <> Base.encode16(:crypto.hash(:sha256, fingerprint), case: :lower)

  defp bare_operation_id(operation_id, issue_id)
       when is_binary(operation_id) and is_binary(issue_id) do
    String.replace_prefix(operation_id, issue_id <> ":", "")
  end

  defp bare_operation_id(operation_id, _issue_id), do: operation_id
end
