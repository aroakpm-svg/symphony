defmodule SymphonyElixir.MergeReadyCandidate do
  @moduledoc "Derives a fail-closed, exact-head proof for human-controlled landing."

  @schema_version 1
  @sha_pattern ~r/^[0-9a-f]{40}$/
  @compatibility_receipts [:aro_143, :aro_170, :aro_171, :aro_167, :aro_135]

  @type final_evidence :: map()
  @type native_snapshot :: map()
  @type blocker_receipt :: %{code: atom(), identity: map()}
  @type candidate :: %{
          candidate_schema_version: 1,
          repository: String.t(),
          pull_request_number: pos_integer(),
          linear_issue_id: String.t(),
          linear_issue_identifier: String.t(),
          linear_revision: String.t(),
          base_sha: String.t(),
          head_sha: String.t(),
          derived_at: DateTime.t(),
          required_checks: [String.t()],
          settled_finding_digests: [String.t()],
          handoff_contract_version: pos_integer(),
          compatibility_contract_versions: %{atom() => pos_integer()},
          evidence_refs: [String.t()],
          candidate_digest: String.t()
        }

  @spec derive(final_evidence(), native_snapshot(), keyword()) ::
          {:ok, candidate()} | {:blocked, [blocker_receipt()]}
  def derive(evidence, snapshot, opts)
      when is_map(evidence) and is_map(snapshot) and is_list(opts) do
    blockers = blockers(evidence, snapshot, Keyword.get(opts, :landing_mode, :human))

    case blockers do
      [] -> {:ok, build_candidate(evidence, snapshot)}
      reasons -> {:blocked, Enum.map(reasons, &blocker(&1, evidence, snapshot))}
    end
  end

  def derive(_evidence, _snapshot, _opts),
    do: {:blocked, [%{code: :evidence_incompatible, identity: %{}}]}

  @spec matches_live_snapshot?(candidate(), native_snapshot()) :: boolean()
  def matches_live_snapshot?(candidate, snapshot) when is_map(candidate) and is_map(snapshot) do
    candidate_identity_matches?(candidate, snapshot) and
      live_snapshot_ready?(candidate, snapshot)
  end

  def matches_live_snapshot?(_candidate, _snapshot), do: false

  defp blockers(evidence, snapshot, mode) do
    [
      contract_blockers(evidence, snapshot, mode),
      identity_blockers(evidence, snapshot),
      pull_request_blockers(snapshot),
      compatibility_blockers(evidence),
      check_blockers(snapshot),
      review_blockers(evidence, snapshot),
      settlement_blockers(evidence),
      acceptance_blockers(evidence, snapshot)
    ]
    |> List.flatten()
    |> Enum.uniq()
  end

  defp contract_blockers(evidence, snapshot, mode) do
    required_evidence = [
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
      :review_policy,
      :evidence_refs,
      :derived_at
    ]

    required_snapshot = [
      :repository,
      :pull_request_number,
      :linear_issue_id,
      :linear_issue_identifier,
      :linear_revision,
      :state,
      :draft?,
      :mergeable?,
      :conflict?,
      :base_sha,
      :current_head_sha,
      :required_checks,
      :exact_head_review,
      :trusted_actionable_threads
    ]

    []
    |> maybe_add(mode != :human, :unsupported_landing_mode)
    |> maybe_add(not required_keys?(evidence, required_evidence), :evidence_incompatible)
    |> maybe_add(not required_keys?(snapshot, required_snapshot), :evidence_incompatible)
    |> maybe_add(not valid_core_types?(evidence, snapshot), :evidence_incompatible)
  end

  defp identity_blockers(evidence, snapshot) do
    []
    |> maybe_add(identity_changed?(evidence, snapshot), :identity_changed)
    |> maybe_add(head_changed?(evidence, snapshot), :head_changed)
  end

  defp pull_request_blockers(snapshot) do
    []
    |> maybe_add(snapshot[:state] != :open, :pull_request_not_open)
    |> maybe_add(snapshot[:draft?] != false, :pull_request_draft)
    |> maybe_add(snapshot[:mergeable?] != true or snapshot[:conflict?] != false, :merge_conflict)
  end

  defp compatibility_blockers(evidence) do
    receipts = evidence[:compatibility_receipts]
    handoff = evidence[:handoff_receipt]

    []
    |> maybe_add(
      not (verified_receipt?(handoff) and receipt_identity_matches?(handoff, evidence)),
      :handoff_receipt_unverified
    )
    |> maybe_add(not compatibility_receipts_verified?(receipts, evidence), :compatibility_receipt_unverified)
  end

  defp check_blockers(snapshot) do
    checks = snapshot[:required_checks]

    []
    |> maybe_add(not valid_checks?(checks), :required_check_unsettled)
  end

  defp review_blockers(evidence, snapshot) do
    review = snapshot[:exact_head_review]
    policy = evidence[:review_policy]
    threads = snapshot[:trusted_actionable_threads]

    stale? =
      not is_map(review) or review[:status] != :accepted or
        review[:head_sha] != snapshot[:current_head_sha] or
        not is_map(policy) or policy[:status] != :satisfied or
        policy[:reviewed_head_sha] != snapshot[:current_head_sha]

    []
    |> maybe_add(stale?, :review_stale)
    |> maybe_add(not is_list(threads) or threads != [], :actionable_review_remaining)
  end

  defp settlement_blockers(evidence) do
    settled = evidence[:settled_findings]
    inventory = evidence[:canonical_finding_digests]

    []
    |> maybe_add(not complete_settlements?(inventory, settled), :finding_unsettled)
    |> maybe_add(non_empty?(evidence[:pending_effects]), :effect_pending)
    |> maybe_add(non_empty?(evidence[:unknown_effects]), :effect_unknown)
    |> maybe_add(non_empty?(evidence[:blocked_findings]), :finding_blocked)
    |> maybe_add(non_empty?(evidence[:stale_evidence]), :evidence_stale)
    |> maybe_add(non_empty?(evidence[:conflicts]), :evidence_conflict)
    |> maybe_add(non_empty?(evidence[:safety_stops]), :safety_stop_present)
  end

  defp acceptance_blockers(evidence, snapshot) do
    acceptance = evidence[:acceptance]

    []
    |> maybe_add(not valid_acceptance?(acceptance, evidence), :acceptance_incomplete)
    |> maybe_add(evidence[:linear_revision] != snapshot[:linear_revision], :linear_mapping_unverified)
  end

  defp build_candidate(evidence, snapshot) do
    candidate = %{
      candidate_schema_version: @schema_version,
      repository: evidence.repository,
      pull_request_number: evidence.pull_request_number,
      linear_issue_id: evidence.linear_issue_id,
      linear_issue_identifier: evidence.linear_issue_identifier,
      linear_revision: evidence.linear_revision,
      base_sha: evidence.base_sha,
      head_sha: evidence.evaluated_head_sha,
      derived_at: evidence.derived_at,
      required_checks: snapshot.required_checks |> Enum.map(& &1.name) |> Enum.sort(),
      settled_finding_digests: evidence.settled_findings |> Enum.map(& &1.finding_key_digest) |> Enum.sort(),
      handoff_contract_version: evidence.handoff_receipt.contract_version,
      compatibility_contract_versions: compatibility_contract_versions(evidence.compatibility_receipts),
      evidence_refs: Enum.sort(evidence.evidence_refs)
    }

    Map.put(candidate, :candidate_digest, candidate_digest(candidate))
  end

  defp candidate_digest(candidate) do
    [
      "merge-ready-candidate-v1",
      candidate.repository,
      Integer.to_string(candidate.pull_request_number),
      candidate.linear_issue_id,
      candidate.linear_issue_identifier,
      candidate.linear_revision,
      candidate.base_sha,
      candidate.head_sha,
      encode_sequence(candidate.required_checks),
      encode_sequence(candidate.settled_finding_digests),
      Integer.to_string(candidate.handoff_contract_version),
      encode_contract_versions(candidate.compatibility_contract_versions),
      encode_sequence(candidate.evidence_refs)
    ]
    |> Enum.map_join(&encode_component/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp encode_component(value), do: "#{byte_size(value)}:#{value}"

  defp encode_sequence(values), do: Enum.map_join(values, "", &encode_component/1)

  defp encode_contract_versions(versions) do
    @compatibility_receipts
    |> Enum.sort()
    |> Enum.map(fn owner -> encode_sequence([Atom.to_string(owner), Integer.to_string(versions[owner])]) end)
    |> encode_sequence()
  end

  defp compatibility_contract_versions(receipts) do
    Map.new(@compatibility_receipts, &{&1, receipts[&1].contract_version})
  end

  defp live_snapshot_ready?(candidate, snapshot) do
    live_pull_request_ready?(snapshot) and
      live_checks_match?(candidate, snapshot) and
      live_review_matches?(candidate, snapshot)
  end

  defp candidate_identity_matches?(candidate, snapshot) do
    candidate.candidate_schema_version == @schema_version and
      candidate.repository == snapshot[:repository] and
      candidate.pull_request_number == snapshot[:pull_request_number] and
      candidate.linear_issue_id == snapshot[:linear_issue_id] and
      candidate.linear_issue_identifier == snapshot[:linear_issue_identifier] and
      candidate.linear_revision == snapshot[:linear_revision] and
      candidate.base_sha == snapshot[:base_sha] and
      candidate.head_sha == snapshot[:current_head_sha]
  end

  defp live_pull_request_ready?(snapshot) do
    snapshot[:state] == :open and snapshot[:draft?] == false and
      snapshot[:mergeable?] == true and snapshot[:conflict?] == false
  end

  defp live_checks_match?(candidate, snapshot) do
    valid_checks?(snapshot[:required_checks]) and
      Enum.sort(Enum.map(snapshot[:required_checks], & &1.name)) == candidate.required_checks
  end

  defp live_review_matches?(candidate, snapshot) do
    review = snapshot[:exact_head_review]

    is_map(review) and review[:status] == :accepted and
      review[:head_sha] == candidate.head_sha and snapshot[:trusted_actionable_threads] == []
  end

  defp required_keys?(map, keys), do: Enum.all?(keys, &Map.has_key?(map, &1))

  defp valid_core_types?(evidence, snapshot) do
    valid_evidence_identity_types?(evidence) and
      valid_evidence_sha_types?(evidence, snapshot) and
      valid_evidence_metadata_types?(evidence)
  end

  defp valid_evidence_identity_types?(evidence) do
    non_empty_binary?(evidence[:repository]) and
      non_empty_binary?(evidence[:linear_issue_id]) and
      non_empty_binary?(evidence[:linear_issue_identifier]) and
      non_empty_binary?(evidence[:linear_revision]) and
      is_integer(evidence[:pull_request_number]) and evidence[:pull_request_number] > 0
  end

  defp valid_evidence_sha_types?(evidence, snapshot) do
    valid_sha?(evidence[:base_sha]) and valid_sha?(evidence[:evaluated_head_sha]) and
      valid_sha?(evidence[:tested_head_sha]) and valid_sha?(snapshot[:base_sha]) and
      valid_sha?(snapshot[:current_head_sha])
  end

  defp valid_evidence_metadata_types?(evidence) do
    match?(%DateTime{}, evidence[:derived_at]) and
      is_list(evidence[:evidence_refs]) and Enum.all?(evidence[:evidence_refs], &non_empty_binary?/1)
  end

  defp identity_changed?(evidence, snapshot) do
    evidence[:repository] != snapshot[:repository] or
      evidence[:pull_request_number] != snapshot[:pull_request_number] or
      evidence[:linear_issue_id] != snapshot[:linear_issue_id] or
      evidence[:linear_issue_identifier] != snapshot[:linear_issue_identifier] or
      evidence[:base_sha] != snapshot[:base_sha]
  end

  defp head_changed?(evidence, snapshot) do
    evidence[:evaluated_head_sha] != evidence[:tested_head_sha] or
      evidence[:evaluated_head_sha] != snapshot[:current_head_sha]
  end

  defp verified_receipt?(receipt) do
    is_map(receipt) and receipt[:status] == :verified and
      is_integer(receipt[:contract_version]) and receipt[:contract_version] > 0
  end

  defp compatibility_receipts_verified?(receipts, evidence) when is_map(receipts) do
    Enum.all?(@compatibility_receipts, fn owner ->
      case receipts[owner] do
        %{owner: ^owner} = receipt ->
          verified_receipt?(receipt) and receipt_identity_matches?(receipt, evidence)

        _other ->
          false
      end
    end)
  end

  defp compatibility_receipts_verified?(_receipts, _evidence), do: false

  defp receipt_identity_matches?(receipt, evidence) do
    receipt[:repository] == evidence[:repository] and
      receipt[:pull_request_number] == evidence[:pull_request_number] and
      receipt[:linear_issue_id] == evidence[:linear_issue_id] and
      receipt[:linear_issue_identifier] == evidence[:linear_issue_identifier] and
      receipt[:base_sha] == evidence[:base_sha] and
      receipt[:head_sha] == evidence[:evaluated_head_sha]
  end

  defp valid_checks?(checks) when is_list(checks) and checks != [] do
    names = Enum.map(checks, &map_value(&1, :name))

    Enum.all?(checks, fn check ->
      is_map(check) and non_empty_binary?(check[:name]) and
        check[:status] == :completed and check[:conclusion] == :success
    end) and Enum.uniq(names) == names
  end

  defp valid_checks?(_checks), do: false

  defp valid_settlements?(settlements) when is_list(settlements) do
    digests = Enum.map(settlements, &map_value(&1, :finding_key_digest))

    Enum.all?(settlements, fn settlement ->
      is_map(settlement) and settlement[:status] == :settled and
        valid_digest?(settlement[:finding_key_digest])
    end) and Enum.uniq(digests) == digests
  end

  defp valid_settlements?(_settlements), do: false

  defp complete_settlements?(inventory, settlements) do
    valid_finding_inventory?(inventory) and valid_settlements?(settlements) and
      Enum.sort(inventory) ==
        (settlements |> Enum.map(& &1.finding_key_digest) |> Enum.sort())
  end

  defp valid_finding_inventory?(inventory) when is_list(inventory) do
    Enum.all?(inventory, &valid_digest?/1) and Enum.uniq(inventory) == inventory
  end

  defp valid_finding_inventory?(_inventory), do: false

  defp valid_acceptance?(acceptance, evidence) do
    is_map(acceptance) and acceptance[:status] == :complete and
      is_list(acceptance[:evidence_refs]) and acceptance[:evidence_refs] != [] and
      Enum.all?(acceptance[:evidence_refs], &non_empty_binary?/1) and
      receipt_identity_matches?(acceptance, evidence)
  end

  defp non_empty?(value), do: not is_list(value) or value != []
  defp valid_sha?(value), do: is_binary(value) and Regex.match?(@sha_pattern, value)
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)
  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
  defp map_value(value, key) when is_map(value), do: value[key]
  defp map_value(_value, _key), do: nil

  defp maybe_add(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add(reasons, false, _reason), do: reasons

  defp blocker(code, evidence, snapshot) do
    %{
      code: code,
      identity: %{
        repository: evidence[:repository] || snapshot[:repository],
        pull_request_number: evidence[:pull_request_number] || snapshot[:pull_request_number],
        head_sha: evidence[:evaluated_head_sha] || snapshot[:current_head_sha]
      }
    }
  end
end
