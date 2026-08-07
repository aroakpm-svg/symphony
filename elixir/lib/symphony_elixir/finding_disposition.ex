defmodule SymphonyElixir.FindingDisposition do
  @moduledoc """
  Pure, fail-closed policy for deciding whether an actionable finding may be reworked.

  This module consumes already-normalized workflow facts. It deliberately does not parse GitHub
  comments, authenticate issuers, infer ownership, or perform external writes. Until a separately
  reviewed adapter exists, callers must treat the result as a policy contract and keep the manual
  handoff text for a maintainer to post if needed.
  """

  @full_sha ~r/\A[0-9a-f]{40}\z/
  @dispositions [:fix_in_current_pr, :follow_up_required, :blocked_unverified]
  @causes [:introduced_by_pr, :root_cause_out_of_scope, :insufficient_evidence]
  @scopes [:accepted, :out_of_scope, :unknown]

  @enforce_keys [:finding_id, :head_sha, :disposition, :cause, :scope, :maintainer_approved]
  defstruct [:finding_id, :head_sha, :disposition, :cause, :scope, :maintainer_approved]

  @type disposition :: :fix_in_current_pr | :follow_up_required | :blocked_unverified
  @type cause :: :introduced_by_pr | :root_cause_out_of_scope | :insufficient_evidence
  @type scope :: :accepted | :out_of_scope | :unknown

  @type assertion :: %__MODULE__{
          finding_id: String.t(),
          head_sha: String.t(),
          disposition: disposition(),
          cause: cause(),
          scope: scope(),
          maintainer_approved: boolean()
        }

  @type result :: %{
          decision: disposition() | :no_actionable_findings,
          finding_ids: [String.t()],
          reason: atom() | nil,
          handoff: String.t() | nil
        }

  @doc "Builds one typed assertion from normalized workflow data; no prose is interpreted."
  @spec new_assertion(map()) :: {:ok, assertion()} | {:error, atom()}
  def new_assertion(attrs) when is_map(attrs) do
    with :ok <- exact_keys?(attrs),
         :ok <- valid_finding_id(attrs[:finding_id]),
         :ok <- valid_head_sha(attrs[:head_sha]),
         :ok <- valid_disposition(attrs[:disposition]),
         :ok <- valid_cause(attrs[:cause]),
         :ok <- valid_scope(attrs[:scope]),
         :ok <- valid_boolean(attrs[:maintainer_approved]) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new_assertion(_attrs), do: {:error, :malformed_assertion}

  @doc "Evaluates one batch of actionable finding IDs against the exact current head."
  @spec evaluate([String.t()], [assertion()], String.t()) :: result()
  def evaluate(finding_ids, assertions, current_head_sha) do
    cond do
      finding_ids == [] -> result(:no_actionable_findings, [], nil)
      not is_list(finding_ids) -> blocked([], :malformed_finding_ids)
      not valid_head_sha?(current_head_sha) -> blocked([], :invalid_current_head)
      not valid_finding_ids?(finding_ids) -> blocked([], :malformed_finding_ids)
      not is_list(assertions) -> blocked(finding_ids, :malformed_assertion)
      true -> evaluate_batch(finding_ids, assertions, current_head_sha)
    end
  end

  @doc "Returns the fixed text a maintainer may copy into the task or PR as a follow-up handoff."
  @spec handoff_text(String.t() | [String.t()]) :: String.t()
  def handoff_text(finding_id) when is_binary(finding_id), do: handoff_text([finding_id])

  def handoff_text(finding_ids) when is_list(finding_ids) do
    "Finding Triage: follow_up_required\n" <>
      "Finding IDs: #{Enum.join(finding_ids, ", ")}\n" <>
      "Human action: decide whether to open a follow-up issue or PR; no agent patch was applied."
  end

  defp evaluate_batch(finding_ids, assertions, current_head_sha) do
    cond do
      Enum.uniq(finding_ids) != finding_ids ->
        blocked(finding_ids, :duplicate_finding_id)

      Enum.any?(assertions, &(not match?(%__MODULE__{}, &1))) ->
        blocked(finding_ids, :malformed_assertion)

      Enum.any?(assertions, &(not valid_assertion?(&1))) ->
        blocked(finding_ids, :malformed_assertion)

      Enum.any?(assertions, &(&1.finding_id not in finding_ids)) ->
        blocked(finding_ids, :unknown_finding)

      duplicate_assertion?(assertions) ->
        blocked(finding_ids, :ambiguous_assertion)

      Enum.any?(assertions, &(&1.head_sha != current_head_sha)) ->
        blocked(finding_ids, :stale_head)

      Enum.any?(finding_ids, &(not assertion_for?(&1, assertions))) ->
        blocked(finding_ids, :missing_assertion)

      true ->
        decisions = Enum.map(finding_ids, &assertion_decision(&1, assertions))
        batch_result(finding_ids, decisions)
    end
  end

  defp assertion_decision(finding_id, assertions) do
    assertion = Enum.find(assertions, &(&1.finding_id == finding_id))

    case assertion.disposition do
      :fix_in_current_pr ->
        if assertion.cause == :introduced_by_pr and assertion.scope == :accepted and
             assertion.maintainer_approved do
          :fix_in_current_pr
        else
          :blocked_unverified
        end

      :follow_up_required ->
        if assertion.cause == :root_cause_out_of_scope and assertion.scope == :out_of_scope do
          :follow_up_required
        else
          :blocked_unverified
        end

      :blocked_unverified ->
        :blocked_unverified
    end
  end

  defp batch_result(finding_ids, decisions) do
    follow_up_ids =
      finding_ids
      |> Enum.zip(decisions)
      |> Enum.flat_map(fn
        {finding_id, :follow_up_required} -> [finding_id]
        _ -> []
      end)

    cond do
      :blocked_unverified in decisions ->
        blocked(finding_ids, :blocked_assertion, handoff_for(follow_up_ids))

      :follow_up_required in decisions ->
        result(:follow_up_required, finding_ids, nil, handoff_text(follow_up_ids))

      true ->
        result(:fix_in_current_pr, finding_ids, nil)
    end
  end

  defp assertion_for?(finding_id, assertions), do: Enum.any?(assertions, &(&1.finding_id == finding_id))

  defp duplicate_assertion?(assertions) do
    finding_ids = Enum.map(assertions, & &1.finding_id)
    Enum.uniq(finding_ids) != finding_ids
  end

  defp valid_assertion?(%__MODULE__{} = assertion) do
    valid_finding_id?(assertion.finding_id) and
      valid_head_sha?(assertion.head_sha) and
      valid_disposition?(assertion.disposition) and
      valid_cause?(assertion.cause) and
      valid_scope?(assertion.scope) and
      is_boolean(assertion.maintainer_approved)
  end

  defp exact_keys?(attrs) do
    if Map.keys(attrs) |> Enum.sort() == [:cause, :disposition, :finding_id, :head_sha, :maintainer_approved, :scope],
      do: :ok,
      else: {:error, :malformed_assertion}
  end

  defp valid_finding_ids?(finding_ids) do
    Enum.all?(finding_ids, &valid_finding_id?/1)
  end

  defp valid_finding_id?(value), do: is_binary(value) and value != "" and String.trim(value) == value
  defp valid_head_sha?(value), do: is_binary(value) and Regex.match?(@full_sha, value)
  defp valid_disposition?(value), do: value in @dispositions
  defp valid_cause?(value), do: value in @causes
  defp valid_scope?(value), do: value in @scopes
  defp valid_boolean(value), do: if(is_boolean(value), do: :ok, else: {:error, :invalid_maintainer_approval})

  defp valid_finding_id(value), do: if(valid_finding_id?(value), do: :ok, else: {:error, :invalid_finding_id})
  defp valid_head_sha(value), do: if(valid_head_sha?(value), do: :ok, else: {:error, :invalid_head_sha})
  defp valid_disposition(value), do: if(valid_disposition?(value), do: :ok, else: {:error, :invalid_disposition})
  defp valid_cause(value), do: if(valid_cause?(value), do: :ok, else: {:error, :invalid_cause})
  defp valid_scope(value), do: if(valid_scope?(value), do: :ok, else: {:error, :invalid_scope})

  defp result(decision, finding_ids, reason, handoff \\ nil),
    do: %{decision: decision, finding_ids: finding_ids, reason: reason, handoff: handoff}

  defp handoff_for([]), do: nil
  defp handoff_for(finding_ids), do: handoff_text(finding_ids)

  defp blocked(finding_ids, reason, handoff \\ nil),
    do: result(:blocked_unverified, finding_ids, reason, handoff)
end
