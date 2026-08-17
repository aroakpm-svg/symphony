defmodule SymphonyElixir.ReviewSettlementReceipt do
  @moduledoc "Persists the terminal ReviewSettlement proof in EffectLedger."

  alias SymphonyElixir.{EffectLedger, FindingDisposition}

  @spec reconcile_pending(term(), module(), map(), [map()]) :: :ok | {:error, term()}
  def reconcile_pending(connection, ledger \\ EffectLedger, claim, operations) when is_list(operations) do
    operations
    |> Enum.filter(&(&1[:effect_type] == :review_settlement_receipt and &1[:status] in [:pending, :unknown]))
    |> Enum.reduce_while(:ok, fn operation, :ok ->
      with {:ok, intent} <- FindingDisposition.decode_request_fingerprint(operation[:request_fingerprint]),
           finding_key when is_map(finding_key) <- intent[:finding_key],
           disposition when disposition in [:fix_in_current_pr, :follow_up_required, :rejected] <-
             intent[:disposition],
           resource <- resource(%{recovered_from_pending_receipt?: true}, finding_key, disposition),
           context <-
             Map.merge(claim, %{
               operation_id: bare_operation_id(operation[:operation_id], claim[:issue_id]),
               request_fingerprint: operation[:request_fingerprint]
             }),
           {:ok, stored} <-
             ledger.execute(
               connection,
               :review_settlement_receipt,
               context,
               fn -> {:ok, resource} end,
               fn -> {:found, resource} end
             ),
           true <- stored == resource do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :settlement_receipt_mismatch}}
        _invalid -> {:halt, {:error, :invalid_pending_settlement_receipt}}
      end
    end)
  end

  def reconcile_pending(_connection, _ledger, _claim, _operations),
    do: {:error, :invalid_pending_settlement_operations}

  @spec record(term(), module(), map(), map(), map(), [map()]) :: {:ok, map()} | {:error, term()}
  def record(connection, ledger \\ EffectLedger, claim, decision, evidence, operations) do
    with finding_key when is_map(finding_key) <- decision[:finding_key],
         disposition when disposition in [:fix_in_current_pr, :follow_up_required, :rejected] <-
           decision[:disposition],
         {:ok, fingerprint} <- fingerprint(decision, operations),
         resource <- resource(evidence, finding_key, disposition),
         context <- Map.merge(claim, %{operation_id: operation_id(fingerprint), request_fingerprint: fingerprint}),
         {:ok, stored} <-
           ledger.execute(
             connection,
             :review_settlement_receipt,
             context,
             fn -> {:ok, resource} end,
             fn -> {:found, resource} end
           ),
         true <- stored == resource do
      {:ok, stored}
    else
      false -> {:error, :settlement_receipt_mismatch}
      _invalid -> {:error, :invalid_settlement_receipt}
    end
  end

  defp fingerprint(decision, operations) when is_list(operations) do
    operations
    |> Enum.map(& &1[:request_fingerprint])
    |> Enum.uniq()
    |> Enum.find_value({:error, :settlement_fingerprint_unavailable}, fn fingerprint ->
      case FindingDisposition.decode_request_fingerprint(fingerprint) do
        {:ok, %{finding_key: %{digest: digest}, disposition: disposition}}
        when digest == decision.finding_key_digest and disposition == decision.disposition ->
          {:ok, fingerprint}

        _ -> nil
      end
    end)
  end

  defp fingerprint(_decision, _operations), do: {:error, :settlement_fingerprint_unavailable}

  defp operation_id(fingerprint),
    do: "review-settlement-receipt-" <> Base.encode16(:crypto.hash(:sha256, fingerprint), case: :lower)

  defp bare_operation_id(operation_id, issue_id)
       when is_binary(operation_id) and is_binary(issue_id) do
    String.replace_prefix(operation_id, issue_id <> ":", "")
  end

  defp resource(evidence, key, disposition) do
    %{
      "verified" => true,
      "disposition" => Atom.to_string(disposition),
      "finding_key_digest" => key.digest,
      "review_thread_id" => key.review_thread_id,
      "selected_review_comment_id" => key.selected_review_comment_id,
      "body_sha256" => key.body_sha256,
      "repository" => key.repository,
      "pull_request_number" => key.pull_request_number,
      "exact_head_sha" => key.source_head_sha,
      "evidence_sha256" =>
        evidence
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    }
  end
end
