defmodule SymphonyElixir.Design2HardeningFixtures do
  @issue_id "issue-design2-hardening"
  @node_id "22222222-2222-4222-8222-222222222222"
  @node_instance_id "33333333-3333-4333-8333-333333333333"
  @full_sha String.duplicate("a", 40)

  @spec issue_id() :: String.t()
  def issue_id, do: @issue_id

  @spec claim_context(pos_integer()) :: map()
  def claim_context(generation) when generation in [1, 2] do
    %{
      issue_id: @issue_id,
      claim_id: claim_id(generation),
      generation: generation,
      node_id: @node_id,
      node_instance_id: @node_instance_id
    }
  end

  @spec effect_row(String.t(), pos_integer(), String.t()) :: [term()]
  def effect_row(operation_id, generation, status) when generation in [1, 2] do
    context = claim_context(generation)

    [
      operation_id,
      "github_comment",
      "symphony_request_fingerprint_v1:fixture",
      status,
      nil,
      context.issue_id,
      context.claim_id,
      context.generation
    ]
  end

  @spec generation_transition() :: [map()]
  def generation_transition do
    [
      %{from: 1, event: :release, to: :released},
      %{from: :released, event: :reclaim, to: 2, claim: :new_generation},
      %{from: 2, event: :expire, to: :expired},
      %{from: :expired, event: :reclaim, to: 3, claim: :new_generation}
    ]
  end

  @spec finding_facts(map()) :: map()
  def finding_facts(overrides \\ %{}) when is_map(overrides) do
    Map.merge(
      %{
        repository: "aroakpm-svg/symphony",
        pull_request_number: 25,
        source_head_sha: @full_sha,
        review_thread_id: "thread-design2-hardening",
        selected_review_comment_id: "comment-design2-hardening",
        body: "state-transition hardening",
        introduced_by_pr?: true,
        invariant_violation?: false,
        still_applies?: true,
        in_scope?: false,
        root_cause_bounded?: true,
        requires_new_decision?: false
      },
      overrides
    )
  end

  @spec fingerprint_intent(map()) :: map()
  def fingerprint_intent(overrides \\ %{}) when is_map(overrides) do
    Map.merge(
      %{
        disposition: :fix_in_current_pr,
        finding_key: nil,
        finding_lineage_key: nil,
        evaluated_head_sha: @full_sha,
        policy_version: "design2-v1",
        target: %{repository: "aroakpm-svg/symphony", pull_request_number: 25},
        payload: %{patch: "bounded"},
        resulting_tree_or_commit: %{tree: "tree-design2-hardening"},
        expected_transition: %{head_sha: @full_sha}
      },
      overrides
    )
  end

  @spec ownership_decision_table() :: [map()]
  def ownership_decision_table do
    [
      %{
        case: :introduced_by_pr_only,
        introduced_by_pr?: true,
        invariant_violation?: false,
        in_scope?: false,
        safety: :all_explicitly_safe,
        expected: :fix_in_current_pr
      },
      %{
        case: :invariant_violation_only,
        introduced_by_pr?: false,
        invariant_violation?: true,
        in_scope?: false,
        safety: :all_explicitly_safe,
        expected: :fix_in_current_pr
      },
      %{
        case: :no_responsibility_proof,
        introduced_by_pr?: false,
        invariant_violation?: false,
        in_scope?: false,
        safety: :all_explicitly_safe,
        expected: :follow_up_or_blocked
      },
      %{
        case: :missing_evidence,
        introduced_by_pr?: :unknown,
        invariant_violation?: false,
        in_scope?: false,
        safety: :not_verified,
        expected: :blocked_unverified
      },
      %{
        case: :malformed_evidence,
        introduced_by_pr?: :malformed,
        invariant_violation?: true,
        in_scope?: false,
        safety: :not_verified,
        expected: :blocked_unverified
      },
      %{
        case: :conflicting_evidence,
        introduced_by_pr?: true,
        invariant_violation?: false,
        in_scope?: false,
        safety: :conflicting,
        expected: :blocked_unverified
      }
    ]
  end

  defp claim_id(1), do: "11111111-1111-4111-8111-111111111111"
  defp claim_id(2), do: "44444444-4444-4444-8444-444444444444"
end
