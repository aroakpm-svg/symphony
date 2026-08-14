defmodule SymphonyElixir.FindingDispositionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FindingDisposition

  test "FindingKey changes when only the provider body bytes change" do
    {:ok, first} = FindingDisposition.build_finding_key(finding_input(%{body: "P1 issue"}))
    {:ok, second} = FindingDisposition.build_finding_key(finding_input(%{body: "P1 issue\n"}))

    refute first.digest == second.digest
    assert first.body_sha256 == sha256("P1 issue")
  end

  test "body identity does not trim or normalize line endings" do
    {:ok, crlf} = FindingDisposition.build_finding_key(finding_input(%{body: "P1\r\nissue"}))
    {:ok, lf} = FindingDisposition.build_finding_key(finding_input(%{body: "P1\nissue"}))

    refute crlf.digest == lf.digest
  end

  test "source head drift requires evaluated-head revalidation" do
    assert {:error, :source_head_requires_revalidation} =
             FindingDisposition.head_guard(
               %{source_head_sha: full_sha("a"), evaluated_head_sha: full_sha("b"), revalidated?: false},
               full_sha("b")
             )

    assert :ok =
             FindingDisposition.head_guard(
               %{source_head_sha: full_sha("a"), evaluated_head_sha: full_sha("b"), revalidated?: true},
               full_sha("b")
             )
  end

  test "mutation-time head drift invalidates the old plan" do
    assert {:error, :current_head_drift} =
             FindingDisposition.head_guard(
               %{source_head_sha: full_sha("a"), evaluated_head_sha: full_sha("a")},
               full_sha("b")
             )
  end

  test "FindingLineageKey contains only stable review identity" do
    assert {:ok, lineage} = FindingDisposition.build_lineage_key(finding_input(%{}))

    assert lineage.repository == "openai/symphony"
    assert lineage.pull_request_number == 21
    assert lineage.review_thread_id == "thread-1"
    assert String.length(lineage.digest) == 64
  end

  test "identity constructors reject malformed fields and non-maps" do
    assert {:error, {:missing_or_invalid_field, :repository}} =
             FindingDisposition.build_finding_key(finding_input(%{repository: ""}))

    assert {:error, {:missing_or_invalid_field, :pull_request_number}} =
             FindingDisposition.build_finding_key(finding_input(%{pull_request_number: 0}))

    assert {:error, :invalid_head_sha} =
             FindingDisposition.build_finding_key(finding_input(%{source_head_sha: String.duplicate("A", 40)}))

    assert {:error, {:missing_or_invalid_field, :body}} =
             FindingDisposition.build_finding_key(finding_input(%{body: nil}))

    assert {:error, {:missing_or_invalid_field, :source_head_sha}} =
             FindingDisposition.build_finding_key(finding_input(%{source_head_sha: nil}))

    assert {:error, :invalid_finding_key_input} = FindingDisposition.build_finding_key([])
    assert {:error, :invalid_finding_lineage_input} = FindingDisposition.build_lineage_key([])
  end

  test "selection uses provider connection order and excludes managed comments" do
    thread = %{
      id: "review-thread-1",
      resolved?: false,
      comments: [
        trusted_comment("review-1", "P2 old", 0),
        managed_comment("agent-1", "fixed", 1),
        trusted_comment("review-2", "P1 current", 2)
      ]
    }

    assert {:ok, %{id: "review-2"}} = FindingDisposition.select_review_comment(thread, %{})
  end

  test "resolved thread with fresh trusted evidence is selected" do
    thread = %{
      id: "review-thread-1",
      resolved?: true,
      comments: [trusted_comment("review-new", "P1 follow-up", 4)]
    }

    settled = %{"review-thread-1" => %{comment_id: "review-old", body_sha256: sha256("P1 old")}}

    assert {:ok, %{id: "review-new"}} =
             FindingDisposition.select_review_comment(thread, %{settled: settled})
  end

  test "resolved thread without trustworthy settlement history blocks" do
    thread = %{id: "review-thread-1", resolved?: true, comments: [trusted_comment("review-old", "P1 old", 0)]}

    assert {:error, :resolved_thread_settlement_unverified} =
             FindingDisposition.select_review_comment(thread, %{settled: %{}})
  end

  test "resolved settled evidence and empty candidates produce no fresh evidence" do
    comment = trusted_comment("review-old", "P1 old", 0)
    thread = %{id: "review-thread-1", resolved?: true, comments: [comment]}
    settled = %{"review-thread-1" => %{comment_id: "review-old", body_sha256: sha256("P1 old")}}

    assert :no_fresh_evidence = FindingDisposition.select_review_comment(thread, %{settled: settled})

    assert :no_fresh_evidence =
             FindingDisposition.select_review_comment(
               %{id: "review-thread-2", resolved?: false, comments: [managed_comment("agent", "done", 0)]},
               %{}
             )

    assert {:ok, %{id: "review-new"}} =
             FindingDisposition.select_review_comment(
               %{id: "review-thread-3", resolved?: true, comments: [trusted_comment("review-new", "P1 new", 0)]},
               %{settled: %{"review-thread-3" => nil}}
             )
  end

  test "resolved threads with no trusted candidates produce no fresh evidence" do
    thread = %{
      id: "review-thread-untrusted",
      resolved?: true,
      comments: [managed_comment("managed", "agent handled this", 0)]
    }

    assert :no_fresh_evidence = FindingDisposition.select_review_comment(thread, %{settled: %{}})
  end

  test "selection rejects malformed thread and connection order" do
    assert {:error, :invalid_review_thread} = FindingDisposition.select_review_comment(%{}, :bad)

    assert {:error, :invalid_review_comments} = FindingDisposition.select_review_comment(%{comments: :bad}, %{})

    assert {:error, :invalid_connection_order} =
             FindingDisposition.select_review_comment(
               %{resolved?: false, comments: [Map.put(trusted_comment("id", "body", 0), :connection_index, -1)]},
               %{}
             )

    assert {:error, {:missing_or_invalid_field, :body}} =
             FindingDisposition.select_review_comment(
               %{resolved?: false, comments: [Map.delete(trusted_comment("id", "body", 0), :body)]},
               %{}
             )

    assert {:error, :invalid_review_comment} =
             FindingDisposition.select_review_comment(%{resolved?: false, comments: [:bad]}, %{})
  end

  test "four canonical findings are classified independently" do
    fix_facts = %{
      introduced_by_pr?: true,
      still_applies?: true,
      in_scope?: true,
      root_cause_bounded?: true,
      requires_new_decision?: false
    }

    follow_up_facts = %{
      introduced_by_pr?: false,
      invariant_violation?: false,
      safe_follow_up?: true,
      in_scope?: false,
      follow_up_destination: "Backlog",
      requires_new_decision?: false,
      still_applies?: true,
      root_cause_bounded?: true
    }

    rejected_facts = rejected_finding_facts("rejected")

    assert {:ok, plan} =
             FindingDisposition.classify_all(
               [
                 finding_facts("fix", fix_facts),
                 finding_facts("follow", follow_up_facts),
                 rejected_facts,
                 finding_facts("blocked", %{introduced_by_pr?: :unknown, still_applies?: :unknown})
               ],
               preflight_facts()
             )

    assert Enum.frequencies(Enum.map(plan.decisions, & &1.disposition)) == %{
             blocked_unverified: 1,
             fix_in_current_pr: 1,
             follow_up_required: 1,
             rejected: 1
           }

    assert plan.merge_ready_blocked?
    assert [%{disposition: :rejected}] = plan.rejected_decisions
  end

  test "reject receipt maps to rejected only with complete exact-head native evidence" do
    facts = rejected_finding_facts("strict-reject")

    assert {:ok, %{disposition: :rejected}} = FindingDisposition.classify(facts, preflight_facts())

    receipt = facts.root_cause_receipt

    invalid_receipts = [
      Map.delete(receipt, :rejection_basis),
      %{receipt | evidence_references: []},
      %{receipt | evidence_conflict?: true},
      %{receipt | current_head_sha: full_sha("2")},
      %{receipt | finding_key: Map.put(receipt.finding_key, :digest, String.duplicate("f", 64))},
      %{receipt | native_readback: %{receipt.native_readback | verified?: false}},
      %{receipt | native_readback: %{receipt.native_readback | current_head_sha: full_sha("2")}},
      %{receipt | review_action: :resolved},
      %{receipt | validation_receipt_status: "UNVERIFIED"},
      %{receipt | hypothesis_rejected?: true}
    ]

    for invalid <- invalid_receipts do
      assert {:ok, %{disposition: :blocked_unverified}} =
               FindingDisposition.classify(%{facts | root_cause_receipt: invalid}, preflight_facts())
    end
  end

  test "real out-of-scope findings remain follow-up and causal hypothesis rejection is not review rejection" do
    follow_up =
      finding_facts("real-follow-up", %{
        introduced_by_pr?: false,
        invariant_violation?: false,
        safe_follow_up?: true,
        in_scope?: false,
        follow_up_destination: "ARO-999",
        requires_new_decision?: false,
        still_applies?: true,
        root_cause_bounded?: true
      })

    assert {:ok, %{disposition: :follow_up_required}} =
             FindingDisposition.classify(follow_up, preflight_facts())

    hypothesis_only =
      finding_facts("hypothesis-only", %{
        introduced_by_pr?: false,
        invariant_violation?: false,
        hypothesis_rejected?: true
      })

    assert {:ok, %{disposition: :blocked_unverified}} =
             FindingDisposition.classify(hypothesis_only, preflight_facts())
  end

  test "unsafe or missing local facts are blocked and global preflight fails closed" do
    assert {:ok, %{disposition: :blocked_unverified}} = FindingDisposition.classify(%{}, preflight_facts())
    assert {:error, :invalid_finding_facts} = FindingDisposition.classify([], preflight_facts())

    assert {:error, {:global_blocker, :claim_unavailable}} =
             FindingDisposition.classify_all([], %{global_blocker: :claim_unavailable})

    assert {:error, {:global_blocker, :preflight_unverified}} =
             FindingDisposition.classify_all([], %{verified?: false})

    assert {:error, {:global_blocker, :preflight_unverified}} =
             FindingDisposition.classify_all([], %{valid?: false})

    assert {:error, {:global_blocker, :preflight_invalid}} =
             FindingDisposition.classify_all([], %{verified?: true, valid?: false})

    assert {:error, {:global_blocker, :invalid_preflight}} = FindingDisposition.classify_all([], :bad)
  end

  test "responsibility proof uses OR and does not use scope as an ownership gate" do
    introduced_only =
      finding_facts("introduced-only", %{
        introduced_by_pr?: true,
        invariant_violation?: false,
        in_scope?: false,
        still_applies?: true,
        root_cause_bounded?: true,
        requires_new_decision?: false
      })

    invariant_only =
      finding_facts("invariant-only", %{
        introduced_by_pr?: false,
        invariant_violation?: true,
        in_scope?: false,
        still_applies?: true,
        root_cause_bounded?: true,
        requires_new_decision?: false
      })

    assert {:ok, %{disposition: :fix_in_current_pr}} =
             FindingDisposition.classify(introduced_only, preflight_facts())

    assert {:ok, %{disposition: :fix_in_current_pr}} =
             FindingDisposition.classify(invariant_only, preflight_facts())
  end

  test "actionable dispositions require canonical finding identity" do
    facts =
      finding_facts("identity-missing", %{
        introduced_by_pr?: true,
        still_applies?: true,
        root_cause_bounded?: true,
        requires_new_decision?: false
      })
      |> Map.drop([
        :repository,
        :pull_request_number,
        :source_head_sha,
        :review_thread_id,
        :selected_review_comment_id,
        :body
      ])

    assert {:ok, %{decisions: [%{disposition: :blocked_unverified, finding_key: nil, finding_lineage_key: nil}]}} =
             FindingDisposition.classify_all([facts], preflight_facts())
  end

  test "follow-up routing blocks missing or malformed ownership evidence" do
    base =
      finding_facts("follow-up-evidence", %{
        safe_follow_up?: true,
        in_scope?: false,
        follow_up_destination: "Backlog",
        requires_new_decision?: false
      })

    for facts <- [
          Map.delete(base, :introduced_by_pr?),
          Map.put(base, :introduced_by_pr?, :malformed)
        ] do
      assert {:ok, %{disposition: :blocked_unverified}} =
               FindingDisposition.classify(facts, preflight_facts())
    end
  end

  test "follow-up routing requires current applicability and a bounded root cause" do
    base =
      finding_facts("follow-up-safety", %{
        introduced_by_pr?: false,
        invariant_violation?: false,
        safe_follow_up?: true,
        in_scope?: false,
        follow_up_destination: "Backlog",
        requires_new_decision?: false,
        still_applies?: true,
        root_cause_bounded?: true
      })

    for facts <- [
          Map.delete(base, :still_applies?),
          Map.put(base, :still_applies?, false),
          Map.put(base, :still_applies?, :unknown),
          Map.delete(base, :root_cause_bounded?),
          Map.put(base, :root_cause_bounded?, false),
          Map.put(base, :root_cause_bounded?, "true")
        ] do
      assert {:ok, %{disposition: :blocked_unverified}} =
               FindingDisposition.classify(facts, preflight_facts())
    end
  end

  test "incomplete, malformed, or conflicting responsibility evidence blocks" do
    incomplete =
      finding_facts("incomplete", %{
        introduced_by_pr?: true,
        in_scope?: true,
        still_applies?: true,
        root_cause_bounded?: true,
        requires_new_decision?: false
      })
      |> Map.delete(:invariant_violation?)

    malformed =
      finding_facts("malformed", %{
        introduced_by_pr?: true,
        invariant_violation?: "true",
        in_scope?: true,
        still_applies?: true,
        root_cause_bounded?: true,
        requires_new_decision?: false
      })

    conflicting =
      finding_facts("conflicting", %{
        introduced_by_pr?: true,
        invariant_violation?: false,
        evidence_conflict?: true,
        in_scope?: true,
        still_applies?: true,
        root_cause_bounded?: true,
        requires_new_decision?: false
      })

    malformed_conflict =
      finding_facts("malformed-conflict", %{
        introduced_by_pr?: true,
        invariant_violation?: false,
        evidence_conflict?: "true",
        in_scope?: true,
        still_applies?: true,
        root_cause_bounded?: true,
        requires_new_decision?: false
      })

    for facts <- [incomplete, malformed, conflicting, malformed_conflict] do
      assert {:ok, %{disposition: :blocked_unverified}} = FindingDisposition.classify(facts, preflight_facts())
    end
  end

  test "empty plans retain every fixed execution step as no-op data" do
    assert {:ok, plan} = FindingDisposition.classify_all([], preflight_facts())

    assert FindingDisposition.execution_steps(plan) == [
             :reconcile,
             {:retain_rejected_for_settlement, []},
             {:settle_follow_up, []},
             :refetch,
             :recompute_remaining,
             {:build_patch, []},
             :validate_complete_batch,
             {:publish_one_head_transition, []},
             :readback_and_request_exact_head_review,
             {:settle_fix_and_blocked, []}
           ]
  end

  test "head guard rejects missing and invalid head evidence" do
    assert {:error, {:missing_field, :evaluated_head_sha}} = FindingDisposition.head_guard(%{}, full_sha("a"))

    assert {:error, :invalid_head_sha} =
             FindingDisposition.head_guard(%{evaluated_head_sha: "not-a-sha"}, full_sha("a"))

    assert {:error, :invalid_source_head_sha} =
             FindingDisposition.head_guard(%{source_head_sha: 1, evaluated_head_sha: full_sha("a")}, full_sha("a"))

    assert {:error, {:invalid_sha, :evaluated_head_sha}} =
             FindingDisposition.head_guard(%{evaluated_head_sha: 1}, full_sha("a"))

    assert {:error, :invalid_head_guard_input} = FindingDisposition.head_guard(%{}, 1)
  end

  test "operation IDs are effect-specific and exclude payload details" do
    input = %{
      repository: "openai/symphony",
      pull_request_number: 21,
      evaluated_head_sha: full_sha("a"),
      finding_set_digest: String.duplicate("b", 64),
      authorization_identity: "slot-1",
      payload: "not part of logical identity"
    }

    assert {:ok, first} = FindingDisposition.operation_id(:github_pr_update, input)
    assert {:ok, second} = FindingDisposition.operation_id(:github_pr_update, %{input | payload: "changed"})
    assert first == second

    assert {:ok, linear_id} =
             FindingDisposition.operation_id(:linear_issue_create, %{
               repository: "openai/symphony",
               pull_request_number: 21,
               finding_lineage_key: String.duplicate("c", 64),
               destination: "Backlog",
               effect_type: :linear_issue_create
             })

    assert {:ok, comment_id} =
             FindingDisposition.operation_id(:github_comment, %{
               repository: "openai/symphony",
               pull_request_number: 21,
               review_thread_id: "thread-1",
               finding_key: String.duplicate("d", 64),
               message_kind: :follow_up,
               effect_type: :github_comment
             })

    assert {:ok, resolve_id} =
             FindingDisposition.operation_id(:github_review_thread_resolve, %{
               repository: "openai/symphony",
               pull_request_number: 21,
               review_thread_id: "thread-1",
               finding_lineage_key: String.duplicate("c", 64),
               effect_type: :github_review_thread_resolve
             })

    assert length(Enum.uniq([first, linear_id, comment_id, resolve_id])) == 4
    assert {:error, {:unsupported_effect_type, :bad}} = FindingDisposition.operation_id(:bad, %{})

    assert {:error, {:missing_field, :authorization_identity}} =
             FindingDisposition.operation_id(:github_pr_update, Map.delete(input, :authorization_identity))

    assert {:error, {:invalid_effect_type_or_input, :github_pr_update}} =
             FindingDisposition.operation_id(:github_pr_update, [])

    missing_finding = %{
      repository: "owner/repo",
      pull_request_number: 1,
      review_thread_id: "t",
      message_kind: :m,
      effect_type: :github_comment
    }

    assert {:error, {:missing_field, :finding_key_or_lineage_key}} =
             FindingDisposition.operation_id(:github_comment, missing_finding)

    missing_message = %{
      repository: "owner/repo",
      pull_request_number: 1,
      review_thread_id: "t",
      finding_key: String.duplicate("e", 64),
      effect_type: :github_comment
    }

    assert {:error, {:missing_field, :message_kind}} =
             FindingDisposition.operation_id(:github_comment, missing_message)

    missing_effect = %{
      repository: "owner/repo",
      pull_request_number: 1,
      review_thread_id: "t",
      finding_lineage_key: String.duplicate("f", 64)
    }

    assert {:error, {:missing_field, :effect_type}} =
             FindingDisposition.operation_id(:github_review_thread_resolve, missing_effect)

    missing_lineage = %{
      repository: "owner/repo",
      pull_request_number: 1,
      review_thread_id: "t",
      effect_type: :github_review_thread_resolve
    }

    assert {:error, {:missing_field, :finding_lineage_key}} =
             FindingDisposition.operation_id(:github_review_thread_resolve, missing_lineage)
  end

  test "operation IDs reject malformed logical identity values before hashing" do
    update_input = %{
      repository: "owner/repo",
      pull_request_number: 21,
      evaluated_head_sha: full_sha("a"),
      finding_set_digest: String.duplicate("b", 64),
      authorization_identity: "slot-1"
    }

    invalid_updates = [
      %{update_input | repository: nil},
      %{update_input | pull_request_number: 0},
      %{update_input | evaluated_head_sha: "not-a-sha"},
      %{update_input | finding_set_digest: "not-a-digest"},
      %{update_input | authorization_identity: nil}
    ]

    for input <- invalid_updates do
      assert {:error, {:invalid_logical_identity, _field}} =
               FindingDisposition.operation_id(:github_pr_update, input)
    end

    assert {:error, {:invalid_logical_identity, :finding_lineage_key}} =
             FindingDisposition.operation_id(:linear_issue_create, %{
               repository: "owner/repo",
               pull_request_number: 21,
               finding_lineage_key: nil,
               destination: "Backlog",
               effect_type: :linear_issue_create
             })

    assert {:error, {:invalid_logical_identity, :finding_key}} =
             FindingDisposition.operation_id(:github_comment, %{
               repository: "owner/repo",
               pull_request_number: 21,
               review_thread_id: "thread-1",
               finding_key: "not-a-digest",
               message_kind: :follow_up,
               effect_type: :github_comment
             })

    assert {:error, {:invalid_logical_identity, :message_kind}} =
             FindingDisposition.operation_id(:github_comment, %{
               repository: "owner/repo",
               pull_request_number: 21,
               review_thread_id: "thread-1",
               finding_key: String.duplicate("d", 64),
               message_kind: nil,
               effect_type: :github_comment
             })

    for message_kind <- [true, false, :unsupported, "", "unsupported"] do
      assert {:error, {:invalid_logical_identity, :message_kind}} =
               FindingDisposition.operation_id(:github_comment, %{
                 repository: "owner/repo",
                 pull_request_number: 21,
                 review_thread_id: "thread-1",
                 finding_key: String.duplicate("d", 64),
                 message_kind: message_kind,
                 effect_type: :github_comment
               })
    end

    comment_input = %{
      repository: "owner/repo",
      pull_request_number: 21,
      review_thread_id: "thread-1",
      finding_key: String.duplicate("d", 64),
      message_kind: :follow_up,
      effect_type: :github_comment
    }

    assert {:ok, atom_operation_id} =
             FindingDisposition.operation_id(:github_comment, %{
               comment_input
               | message_kind: :follow_up
             })

    assert {:ok, string_operation_id} =
             FindingDisposition.operation_id(:github_comment, %{
               comment_input
               | message_kind: "follow_up"
             })

    assert atom_operation_id == string_operation_id
  end

  test "operation IDs accept canonical finding and lineage key maps" do
    facts = finding_input(%{})
    assert {:ok, finding_key} = FindingDisposition.build_finding_key(facts)
    assert {:ok, finding_lineage_key} = FindingDisposition.build_lineage_key(facts)

    assert {:ok, _comment_id} =
             FindingDisposition.operation_id(:github_comment, %{
               repository: facts.repository,
               pull_request_number: facts.pull_request_number,
               review_thread_id: "thread-1",
               finding_key: finding_key,
               message_kind: :follow_up,
               effect_type: :github_comment
             })

    assert {:ok, _linear_id} =
             FindingDisposition.operation_id(:linear_issue_create, %{
               repository: facts.repository,
               pull_request_number: facts.pull_request_number,
               finding_lineage_key: finding_lineage_key,
               destination: "Backlog",
               effect_type: :linear_issue_create
             })

    assert {:error, {:logical_identity_scope_mismatch, :finding_key}} =
             FindingDisposition.operation_id(:github_comment, %{
               repository: "other/repo",
               pull_request_number: 22,
               review_thread_id: "other-thread",
               finding_key: finding_key,
               message_kind: :follow_up,
               effect_type: :github_comment
             })

    assert {:error, {:logical_identity_scope_mismatch, :finding_lineage_key}} =
             FindingDisposition.operation_id(:linear_issue_create, %{
               repository: "other/repo",
               pull_request_number: 22,
               finding_lineage_key: finding_lineage_key,
               destination: "Backlog",
               effect_type: :linear_issue_create
             })
  end

  test "operation IDs fail closed when embedded effect types do not match the operation" do
    cases = [
      {:linear_issue_create,
       %{
         repository: "owner/repo",
         pull_request_number: 21,
         finding_lineage_key: String.duplicate("c", 64),
         destination: "Backlog",
         effect_type: :linear_issue_create
       }},
      {:github_comment,
       %{
         repository: "owner/repo",
         pull_request_number: 21,
         review_thread_id: "thread-1",
         finding_key: String.duplicate("d", 64),
         message_kind: :follow_up,
         effect_type: :github_comment
       }},
      {:github_review_thread_resolve,
       %{
         repository: "owner/repo",
         pull_request_number: 21,
         review_thread_id: "thread-1",
         finding_lineage_key: String.duplicate("c", 64),
         effect_type: :github_review_thread_resolve
       }}
    ]

    for {operation_type, input} <- cases do
      assert {:ok, operation_id} = FindingDisposition.operation_id(operation_type, input)
      assert {:ok, ^operation_id} = FindingDisposition.operation_id(operation_type, input)

      assert {:error, {:missing_field, :effect_type}} =
               FindingDisposition.operation_id(operation_type, Map.delete(input, :effect_type))

      assert {:error, {:effect_type_mismatch, ^operation_type, :github_pr_update}} =
               FindingDisposition.operation_id(operation_type, %{input | effect_type: :github_pr_update})

      for invalid <- [nil, true, false, "#{operation_type}", :unsupported] do
        assert {:error, {:invalid_logical_identity, :effect_type}} =
                 FindingDisposition.operation_id(operation_type, %{input | effect_type: invalid})
      end
    end
  end

  test "request fingerprints round-trip the complete immutable intent" do
    intent = fingerprint_intent()
    assert {:ok, fingerprint} = FindingDisposition.request_fingerprint(intent)
    assert {:ok, ^intent} = FindingDisposition.decode_request_fingerprint(fingerprint)

    assert {:error, {:missing_field, :payload}} =
             FindingDisposition.request_fingerprint(Map.delete(intent, :payload))

    assert {:error, {:unknown_request_fingerprint_version, "v2"}} =
             FindingDisposition.decode_request_fingerprint("v2:abc")

    assert {:error, :invalid_request_fingerprint} = FindingDisposition.decode_request_fingerprint("bad")

    assert {:error, :invalid_request_fingerprint} =
             FindingDisposition.decode_request_fingerprint("symphony_request_fingerprint_v1:not-base64")

    assert {:error, {:unknown_disposition, :bad}} =
             FindingDisposition.request_fingerprint(%{intent | disposition: :bad})

    assert {:error, :invalid_request_fingerprint_input} = FindingDisposition.request_fingerprint([])
    assert {:error, :invalid_request_fingerprint} = FindingDisposition.decode_request_fingerprint(1)

    unknown_term = Base.url_encode64(:erlang.term_to_binary({:v2, %{}}, [:deterministic]), padding: false)
    invalid_term = Base.url_encode64(:erlang.term_to_binary(:bad, [:deterministic]), padding: false)

    assert {:error, {:unknown_request_fingerprint_version, :v2}} =
             FindingDisposition.decode_request_fingerprint("symphony_request_fingerprint_v1:" <> unknown_term)

    assert {:error, :invalid_request_fingerprint} =
             FindingDisposition.decode_request_fingerprint("symphony_request_fingerprint_v1:" <> invalid_term)

    bad_fingerprint = fingerprint_with_intent(%{fingerprint_intent() | disposition: :bad})

    assert {:error, {:unknown_disposition, :bad}} =
             FindingDisposition.decode_request_fingerprint(bad_fingerprint)

    intent = fingerprint_intent()

    for invalid_intent <- [
          %{intent | finding_key: :malformed},
          %{intent | finding_lineage_key: :malformed},
          %{intent | target: :malformed},
          %{intent | finding_key: Map.put(intent.finding_key, :digest, 123)},
          %{intent | finding_lineage_key: Map.put(intent.finding_lineage_key, :digest, 123)}
        ] do
      assert {:error, _reason} = FindingDisposition.decode_request_fingerprint(fingerprint_with_intent(invalid_intent))
    end

    for invalid_intent <- [
          %{intent | finding_key: nil},
          %{intent | finding_lineage_key: nil},
          %{intent | finding_key: Map.put(intent.finding_key, :digest, String.duplicate("f", 64))},
          %{intent | finding_lineage_key: Map.put(intent.finding_lineage_key, :digest, String.duplicate("f", 64))}
        ] do
      assert {:error, _reason} = FindingDisposition.request_fingerprint(invalid_intent)
    end

    {:ok, other_lineage} =
      FindingDisposition.build_lineage_key(finding_input(%{review_thread_id: "other-thread"}))

    mismatched_fingerprint =
      fingerprint_with_intent(%{intent | finding_lineage_key: other_lineage})

    assert {:error, :finding_lineage_scope_mismatch} =
             FindingDisposition.decode_request_fingerprint(mismatched_fingerprint)
  end

  test "lock reconciliation detects disposition and effect identity conflicts" do
    assert {:ok, %{locks: %{}}} = FindingDisposition.reconcile_locks([])

    entry = %{finding_key: "finding-1", disposition: :fix_in_current_pr}
    assert {:ok, %{locks: %{"finding-1" => ^entry}}} = FindingDisposition.reconcile_locks([entry, entry])

    assert {:error, {:global_blocker, :conflicting_disposition_lock}} =
             FindingDisposition.reconcile_locks([
               entry,
               %{finding_key: "finding-1", disposition: :blocked_unverified}
             ])

    assert {:error, {:global_blocker, :conflicting_effect_lock}} =
             FindingDisposition.reconcile_locks([
               Map.merge(entry, %{intent: %{operation_id: "one"}, marker: %{operation_id: "two"}})
             ])

    assert {:error, {:global_blocker, :missing_finding_lock_identity}} =
             FindingDisposition.reconcile_locks([%{disposition: :fix_in_current_pr}])

    assert {:error, {:global_blocker, {:unknown_disposition, :bad}}} =
             FindingDisposition.reconcile_locks([%{finding_key: "finding-1", disposition: :bad}])

    assert {:error, {:global_blocker, :invalid_lock_entries}} = FindingDisposition.reconcile_locks(:bad)

    assert {:error, {:global_blocker, :invalid_lock_entry}} = FindingDisposition.reconcile_locks([:bad])

    assert {:error, {:global_blocker, :missing_finding_lock_identity}} =
             FindingDisposition.reconcile_locks([%{finding_key: %{digest: ""}, disposition: :fix_in_current_pr}])

    assert {:ok, %{locks: %{"finding-2" => _}}} =
             FindingDisposition.reconcile_locks([
               %{finding_key: "finding-2", disposition: :fix_in_current_pr, intent: :not_a_map}
             ])
  end

  test "identity can consume an already validated key or string-keyed input" do
    {:ok, key} = FindingDisposition.build_finding_key(finding_input(%{}))
    assert {:ok, %{finding_key: ^key}} = FindingDisposition.classify(%{finding_key: key}, preflight_facts())

    {:ok, lineage_key} = FindingDisposition.build_lineage_key(finding_input(%{}))

    assert {:ok, %{finding_key: ^key, finding_lineage_key: ^lineage_key}} =
             FindingDisposition.classify(
               %{finding_key: key, finding_lineage_key: lineage_key},
               preflight_facts()
             )

    string_input = %{
      "repository" => "openai/symphony",
      "pull_request_number" => 21,
      "source_head_sha" => full_sha("1"),
      "review_thread_id" => "thread-1",
      "selected_review_comment_id" => "comment-1",
      "body" => "P1 issue"
    }

    assert {:ok, %{repository: "openai/symphony"}} = FindingDisposition.build_finding_key(string_input)

    assert {:ok, %{disposition: :blocked_unverified, finding_key: nil}} =
             FindingDisposition.classify(%{finding_key: %{digest: 1}}, preflight_facts())

    assert {:ok, %{disposition: :blocked_unverified, finding_lineage_key: nil, finding_key: nil}} =
             FindingDisposition.classify(%{finding_key: %{digest: "precomputed"}}, preflight_facts())
  end

  test "head guard accepts source revalidation and rejects non-map plans" do
    assert :ok =
             FindingDisposition.head_guard(
               %{source_head_sha: full_sha("a"), evaluated_head_sha: full_sha("b"), revalidated?: true},
               full_sha("b")
             )

    assert {:error, :invalid_head_guard_input} = FindingDisposition.head_guard([], full_sha("a"))
    assert [] == FindingDisposition.execution_steps(:bad)
  end

  test "head guard rejects missing or malformed source head evidence" do
    for plan <- [
          %{evaluated_head_sha: full_sha("a"), revalidated?: true},
          %{source_head_sha: "not-a-sha", evaluated_head_sha: full_sha("a"), revalidated?: true}
        ] do
      assert {:error, :invalid_source_head_sha} = FindingDisposition.head_guard(plan, full_sha("a"))
    end
  end

  defp finding_input(overrides) do
    Map.merge(
      %{
        repository: "openai/symphony",
        pull_request_number: 21,
        source_head_sha: full_sha("1"),
        review_thread_id: "thread-1",
        selected_review_comment_id: "comment-1",
        body: "P1 issue",
        invariant_violation?: false
      },
      overrides
    )
  end

  defp finding_facts(name, overrides) do
    Map.merge(
      finding_input(%{review_thread_id: "thread-" <> name, selected_review_comment_id: "comment-" <> name}),
      overrides
    )
  end

  defp rejected_finding_facts(name) do
    facts =
      finding_facts(name, %{
        introduced_by_pr?: false,
        invariant_violation?: false,
        still_applies?: true,
        in_scope?: true,
        root_cause_bounded?: true,
        requires_new_decision?: false
      })

    {:ok, finding_key} = FindingDisposition.build_finding_key(facts)
    {:ok, finding_lineage_key} = FindingDisposition.build_lineage_key(facts)

    native_readback = %{
      verified?: true,
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      review_thread_id: finding_key.review_thread_id,
      current_head_sha: finding_key.source_head_sha,
      finding_key_digest: finding_key.digest,
      finding_lineage_key_digest: finding_lineage_key.digest
    }

    receipt = %{
      disposition: :reject,
      verified?: true,
      valid?: true,
      evidence_conflict?: false,
      rejection_basis: "Exact contract evidence contradicts the review claim",
      evidence_references: ["spec:design-2a", "test:rejected-contract"],
      review_action: :unresolved_with_reason,
      validation_receipt_status: "PASS",
      hypothesis_rejected?: false,
      finding_key: finding_key,
      finding_lineage_key: finding_lineage_key,
      evaluated_head_sha: finding_key.source_head_sha,
      current_head_sha: finding_key.source_head_sha,
      native_readback: native_readback
    }

    Map.put(facts, :root_cause_receipt, receipt)
  end

  defp preflight_facts, do: %{verified?: true, valid?: true, repository: "openai/symphony", pull_request_number: 21}

  defp trusted_comment(id, body, connection_index), do: %{id: id, body: body, trusted_review_source?: true, managed_agent_reply?: false, settlement_marker?: false, connection_index: connection_index}

  defp managed_comment(id, body, connection_index), do: %{id: id, body: body, trusted_review_source?: true, managed_agent_reply?: true, settlement_marker?: true, connection_index: connection_index}

  defp fingerprint_intent do
    facts = finding_input(%{})
    {:ok, finding_key} = FindingDisposition.build_finding_key(facts)
    {:ok, finding_lineage_key} = FindingDisposition.build_lineage_key(facts)

    %{
      disposition: :fix_in_current_pr,
      finding_key: finding_key,
      finding_lineage_key: finding_lineage_key,
      evaluated_head_sha: full_sha("a"),
      policy_version: "design2-v1",
      target: %{repository: "openai/symphony", pull_request_number: 21},
      payload: %{patch: "bounded"},
      resulting_tree_or_commit: %{tree: "tree-1"},
      expected_transition: %{head_sha: full_sha("b")}
    }
  end

  defp fingerprint_with_intent(intent) do
    encoded = :erlang.term_to_binary({:symphony_request_fingerprint_v1, intent}, [:deterministic])
    "symphony_request_fingerprint_v1:" <> Base.url_encode64(encoded, padding: false)
  end

  defp full_sha(character) do
    String.duplicate(character, 40)
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
