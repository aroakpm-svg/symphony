defmodule SymphonyElixir.ReviewControlPlane do
  @moduledoc """
  Coordinates latest-head review convergence for explicitly trusted targets.

  `ReviewConvergence` remains the only policy evaluator. This module owns the
  target identity boundary, per-target state, review-request deduplication, and
  status publication. It deliberately does not perform Linear transitions,
  patch authorization, settlement, merge, or landing.
  """

  alias SymphonyElixir.{ReviewConvergence, ReviewTarget}

  @type state_entry :: %{
          target_identity: map(),
          last_head_sha: String.t() | nil,
          last_status: atom(),
          last_decision: atom() | nil,
          requested_review_keys: MapSet.t(String.t()),
          history: [map()]
        }

  @type state :: %{optional(String.t()) => state_entry()}

  @type outcome :: %{
          target: map(),
          status: :success | :pending | :failure | :error | :blocked,
          decision: atom() | nil,
          reason: atom() | nil,
          head_sha: String.t() | nil
        }

  @spec run([ReviewTarget.t()], state(), module(), pos_integer()) ::
          {:ok, state(), [outcome()]} | {:error, term()}
  def run(targets, state, review_client, max_fix_rounds)
      when is_map(state) and is_atom(review_client) and is_integer(max_fix_rounds) and max_fix_rounds > 0 do
    with {:ok, targets} <- ReviewTarget.validate_all(targets) do
      {updated_state, outcomes} =
        Enum.reduce(targets, {state, []}, fn target, state_and_outcomes ->
          reduce_target(target, state_and_outcomes, review_client, max_fix_rounds)
        end)

      {:ok, updated_state, Enum.reverse(outcomes)}
    end
  end

  defp reduce_target(target, {current_state, current_outcomes}, review_client, max_fix_rounds) do
    target_key = ReviewTarget.key(target)
    entry = Map.get(current_state, target_key, initial_entry(target))

    case evaluate_target(target, entry, review_client, max_fix_rounds) do
      {:ok, updated_entry, outcome} ->
        {Map.put(current_state, target_key, updated_entry), [outcome | current_outcomes]}

      {:error, reason, updated_entry, outcome} ->
        {
          Map.put(current_state, target_key, blocked_entry(updated_entry, target, reason)),
          [outcome | current_outcomes]
        }
    end
  end

  defp evaluate_target(target, entry, review_client, max_fix_rounds) do
    with :ok <- validate_entry_identity(target, entry),
         {:ok, snapshot} <- review_client.snapshot_target(target),
         :ok <- ReviewTarget.assert_snapshot(target, snapshot),
         decision <- ReviewConvergence.evaluate(snapshot, 0, max_fix_rounds),
         {:ok, status} <- apply_decision(target, snapshot, decision, entry, review_client) do
      updated_entry =
        entry
        |> Map.put(:last_head_sha, snapshot.current_head_sha)
        |> Map.put(:last_status, status)
        |> Map.put(:last_decision, decision_name(decision))
        |> maybe_record_review_request(target, decision, status)
        |> append_history(target, snapshot, decision, status)

      {:ok, updated_entry,
       %{
         target: ReviewTarget.identity(target),
         status: status,
         decision: decision_name(decision),
         reason: decision_reason(decision),
         head_sha: snapshot.current_head_sha
       }}
    else
      {:error, reason} ->
        error_reason =
          case revoke_stale_status(review_client, target, entry, reason) do
            :ok -> reason
            {:error, status_reason} -> {:status_publication_failed, reason, status_reason}
          end

        {:error, error_reason, entry,
         %{
           target: ReviewTarget.identity(target),
           status: blocked_status(reason),
           decision: nil,
           reason: normalize_reason(error_reason),
           head_sha: Map.get(entry, :last_head_sha)
         }}
    end
  end

  defp revoke_stale_status(_review_client, _target, _entry, :target_state_identity_mismatch), do: :ok

  defp revoke_stale_status(
         _review_client,
         _target,
         _entry,
         {:target_identity_mismatch, _field, _expected, _actual}
       ),
       do: :ok

  defp revoke_stale_status(review_client, target, entry, _reason) do
    last_status = Map.get(entry, :last_status)

    head_sha =
      case Map.get(entry, :last_head_sha) do
        head_sha when is_binary(head_sha) and head_sha != "" -> head_sha
        _ when last_status == :success -> target.head_sha
        _ -> nil
      end

    if is_binary(head_sha) do
      review_client.publish_status(
        target.repository,
        head_sha,
        :error,
        "Review evidence unavailable; previous status revoked",
        nil
      )
    else
      :ok
    end
  end

  defp apply_decision(target, snapshot, {:converged, _evidence}, _entry, review_client) do
    publish(review_client, target, snapshot, :success, "Latest head technically converged; human merge required")
  end

  defp apply_decision(target, snapshot, {:request_review, _evidence}, entry, review_client) do
    request_key = ReviewTarget.dedup_key(target, :review_request, :codex)

    with :ok <- ensure_review_requested(review_client, target, entry, request_key) do
      publish(review_client, target, snapshot, :pending, "Waiting for a formal latest-head review")
    end
  end

  defp apply_decision(target, snapshot, {:rework, _evidence}, _entry, review_client) do
    publish(review_client, target, snapshot, :failure, "Unresolved actionable P1-P4 review findings")
  end

  defp apply_decision(target, snapshot, {:wait, evidence}, _entry, review_client) do
    publish(
      review_client,
      target,
      snapshot,
      :pending,
      "Waiting for required evidence or human judgment (#{inspect(evidence[:reason] || :unknown)})"
    )
  end

  defp apply_decision(target, snapshot, {:escalate, _evidence}, _entry, review_client) do
    publish(review_client, target, snapshot, :failure, "Review did not converge; human decision required")
  end

  defp ensure_review_requested(review_client, target, entry, request_key) do
    if request_key in entry.requested_review_keys do
      :ok
    else
      case review_client.review_request_exists_for_target?(target, request_key) do
        {:ok, true} -> :ok
        {:ok, false} -> review_client.request_review_for_target(target, request_key)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp publish(review_client, target, snapshot, status, description) do
    review_client.publish_status(target.repository, snapshot.current_head_sha, status, description, nil)
    |> case do
      :ok -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initial_entry(target) do
    %{
      target_identity: ReviewTarget.identity(target),
      last_head_sha: nil,
      last_status: :not_evaluated,
      last_decision: nil,
      requested_review_keys: MapSet.new(),
      history: []
    }
  end

  defp validate_entry_identity(target, %{
         target_identity: identity,
         last_head_sha: last_head_sha,
         last_status: last_status,
         last_decision: last_decision,
         requested_review_keys: requested_review_keys,
         history: history
       })
       when (is_binary(last_head_sha) or is_nil(last_head_sha)) and
              is_atom(last_status) and
              (is_atom(last_decision) or is_nil(last_decision)) and
              is_struct(requested_review_keys, MapSet) and
              is_list(history) do
    if identity == ReviewTarget.identity(target), do: :ok, else: {:error, :target_state_identity_mismatch}
  end

  defp validate_entry_identity(_target, _entry), do: {:error, :target_state_invalid}

  defp blocked_entry(entry, target, reason) do
    entry
    |> Map.put(:target_identity, ReviewTarget.identity(target))
    |> Map.put(:last_status, :blocked)
    |> Map.put(:last_decision, nil)
    |> Map.put(:last_error, reason)
  end

  defp append_history(entry, target, snapshot, decision, status) do
    history_entry = %{
      target_identity: ReviewTarget.identity(target),
      head_sha: snapshot.current_head_sha,
      decision: decision_name(decision),
      status: status
    }

    Map.update!(entry, :history, &[history_entry | &1])
  end

  defp maybe_record_review_request(entry, target, {:request_review, _evidence}, :pending) do
    request_key = ReviewTarget.dedup_key(target, :review_request, :codex)
    Map.update!(entry, :requested_review_keys, &MapSet.put(&1, request_key))
  end

  defp maybe_record_review_request(entry, _target, _decision, _status), do: entry

  defp decision_name({decision, _evidence}), do: decision
  defp decision_reason({_decision, evidence}), do: evidence[:reason]

  defp blocked_status({:target_identity_mismatch, _field, _expected, _actual}), do: :blocked
  defp blocked_status(_reason), do: :error

  defp normalize_reason({:target_identity_mismatch, _field, _expected, _actual}), do: :target_identity_mismatch
  defp normalize_reason(:target_state_identity_mismatch), do: :target_state_identity_mismatch
  defp normalize_reason(_reason), do: :external_evidence_unavailable
end
