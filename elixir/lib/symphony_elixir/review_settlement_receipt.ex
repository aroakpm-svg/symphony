defmodule SymphonyElixir.ReviewSettlementReceipt do
  @moduledoc "Persists the terminal ReviewSettlement proof in EffectLedger."

  alias SymphonyElixir.{EffectLedger, FindingDisposition}

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
