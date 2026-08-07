defmodule SymphonyElixir.FindingTriage do
  @moduledoc """
  Fail-closed triage policy for actionable review findings.

  A finding is not eligible for agent edits merely because it has a P1-P4 priority or points at
  the current head. The review adapter must provide an explicit, typed triage decision with the
  evidence that supports it. This policy is local to Symphony and does not consume any external
  disposition or receipt contract.
  """

  @states [:fix_in_current_pr, :follow_up_required, :blocked_unverified]
  @fix_evidence [:introduced_by_pr, :violates_invariant, :violates_acceptance_criterion]

  @type state :: :fix_in_current_pr | :follow_up_required | :blocked_unverified
  @type entry :: %{finding: map(), state: state(), evidence: atom() | nil, reason: atom() | String.t()}
  @type grouped :: %{fix_in_current_pr: [entry()], follow_up_required: [entry()], blocked_unverified: [entry()]}

  @spec states() :: [state()]
  def states, do: @states

  @spec classify([map()], map()) :: grouped()
  def classify(findings, snapshot) when is_list(findings) and is_map(snapshot) do
    entries = Enum.map(findings, &classify_finding(&1, snapshot))

    Map.new(@states, fn state ->
      {state, Enum.filter(entries, &(&1.state == state))}
    end)
  end

  @spec classify_finding(map(), map()) :: entry()
  def classify_finding(finding, snapshot) when is_map(finding) and is_map(snapshot) do
    case explicit_triage(finding, snapshot) do
      %{state: state} = triage when state in @states -> validate_triage(finding, triage)
      _ -> blocked(finding, :missing_triage_evidence)
    end
  end

  def classify_finding(finding, _snapshot), do: blocked(finding, :invalid_finding)

  @spec fingerprint(map()) :: {integer() | nil, String.t() | nil, String.t() | nil}
  def fingerprint(finding) when is_map(finding) do
    {finding[:priority], finding[:path], finding[:body]}
  end

  defp explicit_triage(finding, snapshot) do
    finding[:triage] || triage_from_snapshot(snapshot[:finding_triage], finding)
  end

  defp triage_from_snapshot(triage_by_finding, finding) when is_map(triage_by_finding) do
    Map.get(triage_by_finding, fingerprint(finding))
  end

  defp triage_from_snapshot(triage_entries, finding) when is_list(triage_entries) do
    target_fingerprint = fingerprint(finding)

    Enum.find_value(triage_entries, fn
      %{fingerprint: ^target_fingerprint} = triage -> triage
      _ -> nil
    end)
  end

  defp triage_from_snapshot(_triage, _finding), do: nil

  defp validate_triage(finding, %{state: :fix_in_current_pr, evidence: evidence})
       when evidence in @fix_evidence do
    %{finding: finding, state: :fix_in_current_pr, evidence: evidence, reason: :verified_scope}
  end

  defp validate_triage(finding, %{state: :follow_up_required, evidence: :root_cause_out_of_scope, reason: reason})
       when is_binary(reason) do
    if String.trim(reason) == "" do
      blocked(finding, :invalid_follow_up_reason)
    else
      %{finding: finding, state: :follow_up_required, evidence: :root_cause_out_of_scope, reason: reason}
    end
  end

  defp validate_triage(finding, %{state: :blocked_unverified, reason: reason})
       when is_atom(reason) or is_binary(reason) do
    %{finding: finding, state: :blocked_unverified, evidence: nil, reason: reason}
  end

  defp validate_triage(finding, _triage), do: blocked(finding, :invalid_triage_evidence)

  defp blocked(finding, reason), do: %{finding: finding, state: :blocked_unverified, evidence: nil, reason: reason}
end
