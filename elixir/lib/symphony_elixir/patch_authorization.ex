defmodule SymphonyElixir.PatchAuthorization do
  @moduledoc """
  Pure Design 3 boundary for authorizing one bounded managed mutation.

  Authorization is evidence only. A grant cannot publish, mutate GitHub or Linear,
  resolve review conversations, merge, deploy, or carry credentials.
  """

  alias SymphonyElixir.FindingDisposition

  @type result :: {:ok, map()} | {:reconcile, map()} | {:blocked, term()}
  @terminal_effect_states [:succeeded, :failed_no_effect]
  @reconcilable_effect_states [:pending, :unknown]

  @spec authorize(map(), map(), map(), [map()], map()) :: result()
  def authorize(disposition, receipt, claim, effects, runtime)
      when is_map(disposition) and is_map(receipt) and is_map(claim) and is_list(effects) and
             is_map(runtime) do
    with :ok <- validate_disposition(disposition),
         {:ok, identity} <- validate_identity(disposition, receipt),
         :ok <- validate_receipt(receipt),
         :ok <- validate_pre_mutation_evidence(receipt),
         :ok <- validate_exact_head(receipt, runtime),
         :ok <- validate_claim(claim, runtime),
         :ok <- validate_circuit_breaker(runtime),
         :ok <- validate_recurrence(receipt),
         :ok <- validate_causal_progress(receipt, runtime),
         :ok <- validate_effects(effects, claim) do
      {:ok, build_grant(identity, receipt, claim, runtime)}
    else
      {:reconcile, evidence} -> {:reconcile, evidence}
      {:error, reason} -> {:blocked, reason}
    end
  end

  def authorize(_disposition, _receipt, _claim, _effects, _runtime),
    do: {:blocked, :invalid_authorization_input}

  defp validate_disposition(%{disposition: :fix_in_current_pr}), do: :ok
  defp validate_disposition(%{disposition: :follow_up_required}), do: {:error, :follow_up_required}
  defp validate_disposition(%{disposition: :blocked_unverified}), do: {:error, :blocked_unverified}
  defp validate_disposition(_disposition), do: {:error, :invalid_disposition}

  defp validate_identity(disposition, receipt) do
    with {:ok, {finding_key, lineage_key}} <-
           FindingDisposition.validate_canonical_keys(
             disposition[:finding_key],
             disposition[:finding_lineage_key]
           ),
         true <- receipt[:finding_key] == finding_key,
         true <- receipt[:finding_lineage_key] == lineage_key,
         {:ok, fingerprint} <- digest(receipt[:causal_attempt_fingerprint]) do
      {:ok,
       %{
         finding_key: finding_key,
         finding_lineage_key: lineage_key,
         causal_attempt_fingerprint: fingerprint
       }}
    else
      false -> {:error, :receipt_identity_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_receipt(receipt) do
    required_strings = [
      :invariant,
      :causal_hypothesis,
      :earliest_incorrect_boundary,
      :boundary_group,
      :causal_progress_reference,
      :receipt_provenance,
      :mutation_intent_reference
    ]

    cond do
      receipt[:verified?] != true ->
        {:error, :receipt_unverified}

      receipt[:valid?] != true ->
        {:error, :receipt_invalid}

      receipt[:readback_capable?] != true ->
        {:error, :receipt_readback_unavailable}

      not Enum.all?(required_strings, &non_empty_string?(receipt[&1])) ->
        {:error, :receipt_malformed}

      not (is_integer(receipt[:recurrence_count]) and receipt[:recurrence_count] > 0) ->
        {:error, :receipt_malformed}

      true ->
        :ok
    end
  end

  defp validate_pre_mutation_evidence(%{pre_mutation_regression: evidence}) when is_map(evidence) do
    cond do
      evidence[:phase] != :pre_mutation -> {:error, :invalid_regression_phase}
      evidence[:status] == :pass -> {:error, :green_pre_mutation_regression}
      evidence[:status] not in [:fail, :reproduced] -> {:error, :pre_mutation_regression_unverified}
      not non_empty_string?(evidence[:command_or_source]) -> {:error, :pre_mutation_regression_unverified}
      not non_empty_string?(evidence[:observed_output]) -> {:error, :pre_mutation_regression_unverified}
      not valid_sha?(evidence[:head_sha]) -> {:error, :pre_mutation_regression_unverified}
      true -> :ok
    end
  end

  defp validate_pre_mutation_evidence(_receipt), do: {:error, :missing_pre_mutation_regression}

  defp validate_exact_head(receipt, runtime) do
    evaluated_head = receipt[:evaluated_head_sha]
    authorized_head = receipt[:authorized_head_sha]
    current_head = runtime[:current_head_sha]
    regression_head = get_in(receipt, [:pre_mutation_regression, :head_sha])

    if valid_sha?(evaluated_head) and evaluated_head == authorized_head and
         authorized_head == current_head and current_head == regression_head do
      :ok
    else
      {:error, :stale_or_conflicting_head}
    end
  end

  defp validate_claim(claim, runtime) do
    cond do
      claim[:active?] != true -> {:error, :stale_claim}
      not non_empty_string?(claim[:claim_id]) -> {:error, :invalid_claim}
      not positive_integer?(claim[:generation]) -> {:error, :invalid_generation}
      claim[:claim_id] != runtime[:active_claim_id] -> {:error, :stale_claim}
      claim[:generation] != runtime[:active_generation] -> {:error, :stale_generation}
      true -> :ok
    end
  end

  defp validate_circuit_breaker(%{circuit_breaker: :clear}), do: :ok
  defp validate_circuit_breaker(_runtime), do: {:error, :safety_stopped}

  defp validate_recurrence(%{recurrence_count: count, escalation_decision: decision})
       when count > 2 and decision in [:architecture_escalation, :policy_clarification, :follow_up],
       do: {:error, decision}

  defp validate_recurrence(%{recurrence_count: count}) when count > 2,
    do: {:error, :architecture_escalation_required}

  defp validate_recurrence(_receipt), do: :ok

  defp validate_causal_progress(receipt, runtime) do
    prior_attempts = runtime[:prior_attempts] || []
    lineage_digest = receipt.finding_lineage_key.digest
    fingerprint = receipt.causal_attempt_fingerprint
    evidence_digest = receipt[:causal_evidence_digest]

    with :ok <- validate_prior_attempts(prior_attempts),
         {:ok, evidence_digest} <- digest(evidence_digest) do
      repeated? =
        Enum.any?(prior_attempts, fn attempt ->
          attempt[:finding_lineage_digest] == lineage_digest and
            attempt[:causal_attempt_fingerprint] == fingerprint and
            attempt[:causal_evidence_digest] == evidence_digest
        end)

      if repeated?, do: {:error, :non_progress_blocked}, else: :ok
    end
  end

  defp validate_prior_attempts(attempts) when is_list(attempts) do
    if Enum.all?(attempts, &valid_prior_attempt?/1),
      do: :ok,
      else: {:error, :malformed_causal_history}
  end

  defp validate_prior_attempts(_attempts), do: {:error, :malformed_causal_history}

  defp valid_prior_attempt?(attempt) when is_map(attempt) do
    match?({:ok, _digest}, digest(attempt[:finding_lineage_digest])) and
      match?({:ok, _digest}, digest(attempt[:causal_attempt_fingerprint])) and
      match?({:ok, _digest}, digest(attempt[:causal_evidence_digest])) and
      positive_integer?(attempt[:generation])
  end

  defp valid_prior_attempt?(_attempt), do: false

  defp validate_effects(effects, claim) do
    Enum.reduce_while(effects, :ok, fn effect, :ok ->
      case validate_effect(effect, claim) do
        :ok -> {:cont, :ok}
        {:reconcile, _evidence} = result -> {:halt, result}
        {:error, _reason} = result -> {:halt, result}
      end
    end)
  end

  defp validate_effect(effect, claim) when is_map(effect) do
    status = effect[:status]
    generation = effect[:generation]

    cond do
      not non_empty_string?(effect[:operation_id]) ->
        {:error, :malformed_effect_readback}

      not positive_integer?(generation) ->
        {:error, :malformed_effect_readback}

      generation > claim.generation ->
        {:error, :conflicting_effect_generation}

      status in @reconcilable_effect_states ->
        {:reconcile,
         %{
           reason: :managed_effect_requires_reconciliation,
           operation_id: effect[:operation_id],
           status: status,
           generation: generation
         }}

      status in @terminal_effect_states ->
        :ok

      true ->
        {:error, :malformed_effect_readback}
    end
  end

  defp validate_effect(_effect, _claim), do: {:error, :malformed_effect_readback}

  defp build_grant(identity, receipt, claim, runtime) do
    Map.merge(identity, %{
      authorization: :bounded_managed_mutation,
      evaluated_head_sha: receipt.evaluated_head_sha,
      authorized_head_sha: receipt.authorized_head_sha,
      causal_progress_reference: receipt.causal_progress_reference,
      causal_evidence_digest: receipt.causal_evidence_digest,
      boundary_group: receipt.boundary_group,
      recurrence_count: receipt.recurrence_count,
      claim_id: claim.claim_id,
      generation: claim.generation,
      mutation_intent_reference: receipt[:mutation_intent_reference],
      current_head_sha: runtime.current_head_sha
    })
  end

  defp digest(value) when is_binary(value) and byte_size(value) == 64 do
    if String.match?(value, ~r/\A[0-9a-f]{64}\z/), do: {:ok, value}, else: {:error, :invalid_digest}
  end

  defp digest(_value), do: {:error, :invalid_digest}

  defp valid_sha?(value) when is_binary(value), do: String.match?(value, ~r/\A[0-9a-f]{40}\z/)
  defp valid_sha?(_value), do: false

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
