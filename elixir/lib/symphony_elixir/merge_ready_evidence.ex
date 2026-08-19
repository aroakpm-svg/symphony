defmodule SymphonyElixir.MergeReadyEvidence do
  @moduledoc "Collects fresh GitHub and Linear truth for merge-ready derivation."

  @sha_pattern ~r/^[0-9a-f]{40}$/

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MergeReadyCandidate

  @landing_keys [
    :repository,
    :pull_request_number,
    :linear_issue_id,
    :linear_issue_identifier,
    :linear_revision,
    :base_sha,
    :evaluated_head_sha,
    :tested_head_sha,
    :handoff_receipt,
    :compatibility_receipts,
    :canonical_finding_digests,
    :settled_findings,
    :pending_effects,
    :unknown_effects,
    :blocked_findings,
    :stale_evidence,
    :conflicts,
    :safety_stops,
    :acceptance,
    :evidence_refs
  ]

  @spec read(Issue.t(), map(), map(), keyword()) ::
          {:ok, MergeReadyCandidate.final_evidence(), MergeReadyCandidate.native_snapshot()}
          | {:error, atom()}
  def read(%Issue{} = issue, landing_evidence, settings, deps)
      when is_map(landing_evidence) and is_map(settings) and is_list(deps) do
    with :ok <- validate_issue(issue),
         :ok <- validate_landing_evidence(landing_evidence, deps),
         {:ok, github} <- read_github(issue, settings, deps),
         {:ok, current_issue} <- read_linear(issue, settings, deps),
         :ok <- validate_linear_identity(landing_evidence, current_issue),
         :ok <- validate_native_identity(landing_evidence, github),
         {:ok, snapshot} <- normalize_snapshot(current_issue, github),
         {:ok, evidence} <- normalize_evidence(current_issue, landing_evidence, snapshot, deps) do
      {:ok, evidence, snapshot}
    end
  end

  def read(_issue, _landing_evidence, _settings, _deps),
    do: {:error, :landing_evidence_incompatible}

  @spec completed_landing_evidence(map()) :: {:ok, map()} | {:error, :landing_evidence_unavailable}
  def completed_landing_evidence(%{landing_evidence: evidence}) when is_map(evidence),
    do: {:ok, evidence}

  def completed_landing_evidence(%{terminal_result: {:finding_complete, evidence}})
      when is_map(evidence),
      do: {:ok, evidence}

  def completed_landing_evidence(_entry), do: {:error, :landing_evidence_unavailable}

  defp validate_issue(issue) do
    if non_empty_binary?(issue.id) and non_empty_binary?(issue.identifier) and
         non_empty_binary?(issue.branch_name) and match?(%DateTime{}, issue.updated_at) do
      :ok
    else
      {:error, :linear_mapping_unverified}
    end
  end

  defp validate_landing_evidence(evidence, deps) do
    required_receipts = Keyword.get(deps, :required_compatibility_receipts, [])

    valid? =
      Enum.all?(@landing_keys, &Map.has_key?(evidence, &1)) and
        is_list(required_receipts) and required_receipts != [] and
        is_map(evidence[:compatibility_receipts]) and
        Enum.all?(required_receipts, &Map.has_key?(evidence[:compatibility_receipts], &1))

    if valid?, do: :ok, else: {:error, :landing_evidence_incompatible}
  end

  defp read_github(issue, settings, deps) do
    review_client = Keyword.fetch!(deps, :review_client)

    case review_client.snapshot(settings.repository, issue.branch_name) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      _unavailable -> {:error, :github_readback_unavailable}
    end
  rescue
    _error -> {:error, :github_readback_unavailable}
  end

  defp read_linear(issue, settings, deps) do
    tracker = Keyword.fetch!(deps, :tracker)
    states = [settings.review_state, settings.in_progress_state] |> Enum.uniq()

    case tracker.fetch_routed_issues_by_states(states) do
      {:ok, issues} when is_list(issues) -> unique_current_issue(issues, issue)
      _unavailable -> {:error, :linear_readback_unavailable}
    end
  rescue
    _error -> {:error, :linear_readback_unavailable}
  end

  defp unique_current_issue(issues, expected) do
    matches = Enum.filter(issues, &match_issue?(&1, expected))

    case matches do
      [%Issue{} = issue] -> {:ok, issue}
      _missing_or_ambiguous -> {:error, :linear_mapping_unverified}
    end
  end

  defp match_issue?(%Issue{} = current, expected) do
    current.id == expected.id and current.identifier == expected.identifier and
      current.branch_name == expected.branch_name and current.updated_at == expected.updated_at and
      current.assigned_to_worker == true
  end

  defp match_issue?(_current, _expected), do: false

  defp validate_native_identity(evidence, github) do
    if valid_native_identity_types?(evidence, github) do
      if evidence[:repository] == github[:repository] and
           evidence[:pull_request_number] == github[:pull_request_number] and
           evidence[:base_sha] == github[:base_ref_oid] and
           evidence[:evaluated_head_sha] == github[:current_head_sha],
         do: :ok,
         else: {:error, :landing_evidence_identity_stale}
    else
      {:error, :landing_evidence_incompatible}
    end
  end

  defp validate_linear_identity(evidence, issue) do
    revision = DateTime.to_iso8601(issue.updated_at)

    if non_empty_binary?(evidence[:linear_issue_id]) and
         non_empty_binary?(evidence[:linear_issue_identifier]) and
         non_empty_binary?(evidence[:linear_revision]) do
      if evidence[:linear_issue_id] == issue.id and
           evidence[:linear_issue_identifier] == issue.identifier and
           evidence[:linear_revision] == revision,
         do: :ok,
         else: {:error, :landing_evidence_identity_stale}
    else
      {:error, :landing_evidence_incompatible}
    end
  end

  defp valid_native_identity_types?(evidence, github) do
    non_empty_binary?(evidence[:repository]) and
      is_integer(evidence[:pull_request_number]) and evidence[:pull_request_number] > 0 and
      valid_sha?(evidence[:base_sha]) and valid_sha?(evidence[:evaluated_head_sha]) and
      non_empty_binary?(github[:repository]) and is_integer(github[:pull_request_number]) and
      valid_sha?(github[:base_ref_oid]) and valid_sha?(github[:current_head_sha])
  end

  defp normalize_snapshot(issue, github) do
    with {:ok, checks} <- normalize_checks(github[:required_checks]),
         {:ok, threads} <- normalize_threads(github[:threads]),
         true <- valid_github_state?(github) do
      {:ok,
       %{
         repository: github.repository,
         pull_request_number: github.pull_request_number,
         linear_issue_id: issue.id,
         linear_issue_identifier: issue.identifier,
         linear_revision: DateTime.to_iso8601(issue.updated_at),
         state: github.pull_request_state,
         draft?: github.draft?,
         mergeable?: github.mergeable?,
         conflict?: github.conflict?,
         base_sha: github.base_ref_oid,
         current_head_sha: github.current_head_sha,
         required_checks: checks,
         exact_head_review: %{
           status: review_status(github),
           head_sha: github.reviewed_head_sha
         },
         trusted_actionable_threads: threads
       }}
    else
      _invalid -> {:error, :github_readback_incompatible}
    end
  end

  defp normalize_evidence(issue, landing, snapshot, deps) do
    now = Keyword.fetch!(deps, :now)
    derived_at = now.()

    if match?(%DateTime{}, derived_at) do
      evidence =
        landing
        |> Map.take(@landing_keys)
        |> Map.merge(%{
          linear_issue_id: issue.id,
          linear_issue_identifier: issue.identifier,
          linear_revision: DateTime.to_iso8601(issue.updated_at),
          review_policy: %{
            status: if(snapshot.exact_head_review.status == :accepted, do: :satisfied, else: :unsatisfied),
            reviewed_head_sha: snapshot.exact_head_review.head_sha
          },
          derived_at: derived_at
        })

      {:ok, evidence}
    else
      {:error, :landing_evidence_incompatible}
    end
  rescue
    _error -> {:error, :landing_evidence_incompatible}
  end

  defp normalize_checks(checks) when is_list(checks) and checks != [] do
    normalized =
      Enum.map(checks, fn
        %{name: name, state: state} when is_binary(name) ->
          %{
            name: name,
            status: if(state == :pending, do: :pending, else: :completed),
            conclusion: if(state == :success, do: :success, else: state)
          }

        _invalid ->
          :invalid
      end)

    if :invalid in normalized, do: {:error, :invalid_checks}, else: {:ok, normalized}
  end

  defp normalize_checks(_checks), do: {:error, :invalid_checks}

  defp normalize_threads(threads) when is_list(threads) do
    if Enum.all?(threads, &is_map/1) do
      {:ok,
       threads
       |> Enum.reject(&(&1[:resolved] == true))
       |> Enum.map(&thread_identity/1)}
    else
      {:error, :invalid_threads}
    end
  end

  defp normalize_threads(_threads), do: {:error, :invalid_threads}

  defp thread_identity(thread), do: thread[:url] || thread[:body] || "unidentified-actionable-thread"

  defp valid_github_state?(github) do
    github[:pull_request_state] in [:open, :closed] and is_boolean(github[:draft?]) and
      is_boolean(github[:mergeable?]) and is_boolean(github[:conflict?]) and
      (is_binary(github[:reviewed_head_sha]) or is_nil(github[:reviewed_head_sha])) and
      is_binary(github[:current_head_sha])
  end

  defp review_status(github) do
    if github[:review_result] == :no_major_issues and
         github[:reviewed_head_sha] == github[:current_head_sha],
       do: :accepted,
       else: :missing
  end

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha?(value), do: is_binary(value) and Regex.match?(@sha_pattern, value)
end
