defmodule SymphonyElixir.FindingRouterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{FindingRouter, GitHubReviewClient}

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @digest String.duplicate("c", 64)

  test "accepts only the fixed Actions publisher, workflow, check name, and exact PR envelope" do
    check_run = check_run(receipt([]))
    identity = identity()

    assert {:ok, verified} =
             FindingRouter.verify_receipt(check_run, workflow_run(), identity)

    assert verified["repository"] == "aroakpm-svg/aroak-central-brain"
    assert verified["headSha"] == @head

    assert {:error, :readiness_workflow_envelope_invalid} =
             FindingRouter.verify_receipt(
               check_run,
               Map.put(workflow_run(), "path", ".github/workflows/impostor.yml"),
               identity
             )

    assert {:error, :readiness_workflow_envelope_invalid} =
             FindingRouter.verify_receipt(
               check_run,
               Map.put(workflow_run(), "head_sha", String.duplicate("d", 40)),
               identity
             )

    assert {:error, :readiness_workflow_envelope_invalid} =
             FindingRouter.verify_receipt(
               check_run,
               Map.put(workflow_run(), "check_suite_id", 999),
               identity
             )

    assert {:error, :readiness_workflow_envelope_invalid} =
             FindingRouter.verify_receipt(
               check_run,
               Map.put(workflow_run(), "event", "workflow_dispatch"),
               identity
             )
  end

  test "selects one unique latest completed check and never falls back to an older trusted run" do
    older = check_run(receipt([])) |> Map.put("created_at", "2026-08-01T00:00:00Z")
    latest = check_run(receipt([])) |> Map.put("created_at", "2026-08-02T00:00:00Z")

    assert {:ok, ^latest} = FindingRouter.select_latest_check_run([older, latest], @head)

    impostor =
      latest
      |> Map.put("created_at", "2026-08-03T00:00:00Z")
      |> put_in(["app", "id"], 999)

    assert {:error, :readiness_check_envelope_invalid} =
             FindingRouter.select_latest_check_run([older, impostor], @head)

    tied = Map.put(latest, "id", 2)

    assert {:error, :readiness_check_latest_ambiguous} =
             FindingRouter.select_latest_check_run([latest, tied], @head)

    pending =
      latest
      |> Map.put("completed_at", nil)
      |> Map.put("started_at", "2026-08-04T00:00:00Z")
      |> Map.put("created_at", "2026-08-04T00:00:00Z")
      |> Map.put("status", "in_progress")

    assert {:error, :readiness_check_envelope_invalid} =
             FindingRouter.select_latest_check_run([older, pending], @head)
  end

  test "selects the workflow run by immutable check-suite identity, not details_url" do
    check = check_run(receipt([])) |> Map.put("details_url", "https://github.com/forged/run")
    canonical = workflow_run()
    other = Map.put(canonical, "check_suite_id", 88)

    assert {:ok, ^canonical} =
             GitHubReviewClient.select_bound_workflow_run_for_test(
               [%{"workflow_runs" => [other, canonical]}],
               check
             )

    assert {:error, :readiness_workflow_run_missing} =
             GitHubReviewClient.select_bound_workflow_run_for_test(
               [%{"workflow_runs" => [other]}],
               check
             )

    assert {:error, :readiness_workflow_run_ambiguous} =
             GitHubReviewClient.select_bound_workflow_run_for_test(
               [%{"workflow_runs" => [canonical, Map.put(canonical, "id", 2)]}],
               check
             )

    assert {:error, :readiness_workflow_run_evidence_invalid} =
             GitHubReviewClient.select_bound_workflow_run_for_test(
               [%{"workflow_runs" => [canonical, "malformed"]}],
               check
             )

    assert {:error, :readiness_workflow_run_evidence_invalid} =
             GitHubReviewClient.select_bound_workflow_run_for_test([%{}], check)
  end

  test "fails closed on malformed, mismatched, or outcome-inconsistent receipts" do
    wrong_head = put_in(receipt([]), ["headSha"], String.duplicate("d", 40))

    assert {:error, :readiness_receipt_shape_invalid} =
             FindingRouter.verify_receipt(check_run(wrong_head), workflow_run(), identity())

    extra_key = Map.put(receipt([]), "mergeMode", "auto_ready")

    assert {:error, :readiness_receipt_shape_invalid} =
             FindingRouter.verify_receipt(check_run(extra_key), workflow_run(), identity())

    assert {:error, :readiness_check_outcome_mismatch} =
             FindingRouter.verify_receipt(
               Map.put(check_run(receipt([])), "conclusion", "success"),
               workflow_run(),
               identity()
             )
  end

  test "routes blocked evidence, current-PR fixes, and pending removals without guessing" do
    thread = thread("thread-1")

    assert {:hold, :finding_ownership_unverified} =
             FindingRouter.plan(
               receipt_for_plan([disposition("thread-1", "blocked_unverified")]),
               [thread],
               []
             )

    assert {:rework, [%{router_action: :fix_in_current_pr}]} =
             FindingRouter.plan(
               receipt_for_plan([disposition("thread-1", "fix_in_current_pr")]),
               [thread],
               []
             )

    pending =
      disposition("thread-1", "remove_out_of_scope_change")
      |> Map.put("removalStatus", "pending")

    assert {:rework, [%{router_action: :remove_out_of_scope_change}]} =
             FindingRouter.plan(receipt_for_plan([pending]), [thread], [])
  end

  test "every unresolved P1-P4 thread requires a disposition bound to its selected comment" do
    unresolved = thread("thread-1")

    assert {:hold, :finding_router_evidence_invalid} =
             FindingRouter.plan(receipt_for_plan([]), [unresolved], [])

    mismatched =
      disposition("thread-1", "fix_in_current_pr")
      |> Map.put("findingCommentId", "another-comment")

    assert {:hold, :finding_router_evidence_invalid} =
             FindingRouter.plan(receipt_for_plan([mismatched]), [unresolved], [])

    assert :pass =
             FindingRouter.plan(receipt_for_plan([]), [%{unresolved | resolved: true}], [])
  end

  test "follow-up marker authority uses only the fixed actor and three exact JSON fields" do
    disposition =
      disposition("thread-1", "suggest_follow_up")
      |> Map.put("followUp", follow_up())

    body = FindingRouter.follow_up_comment(disposition, @head, @digest)

    trusted = %{
      "body" => body,
      "user" => %{"node_id" => FindingRouter.trusted_follow_up_actor_node_id()}
    }

    assert FindingRouter.trusted_follow_up_comment?(trusted, "thread-1", @head, @digest)

    refute FindingRouter.trusted_follow_up_comment?(
             put_in(trusted, ["user", "node_id"], "other"),
             "thread-1",
             @head,
             @digest
           )

    refute FindingRouter.trusted_follow_up_comment?(trusted, "thread-2", @head, @digest)

    altered = String.replace(body, ~s("receiptDigest":"#{@digest}"), ~s("receiptDigest":"#{@digest}","extra":true))

    refute FindingRouter.trusted_follow_up_comment?(
             Map.put(trusted, "body", altered),
             "thread-1",
             @head,
             @digest
           )
  end

  test "follow-up must be durable before Resolve and an already-resolved unmarked thread holds" do
    disposition =
      disposition("thread-1", "suggest_follow_up")
      |> Map.put("followUp", follow_up())

    receipt = receipt_for_plan([disposition])

    assert {:settle, [{:comment_then_resolve, ^disposition}]} =
             FindingRouter.plan(receipt, [thread("thread-1")], [])

    assert {:hold, :follow_up_marker_missing_before_resolve} =
             FindingRouter.plan(receipt, [%{thread("thread-1") | resolved: true}], [])

    comment = %{
      "body" => FindingRouter.follow_up_comment(disposition, @head, @digest),
      "user" => %{"node_id" => FindingRouter.trusted_follow_up_actor_node_id()}
    }

    assert {:settle, [{:resolve, ^disposition}]} =
             FindingRouter.plan(receipt, [thread("thread-1")], [comment])

    assert :pass =
             FindingRouter.plan(receipt, [%{thread("thread-1") | resolved: true}], [comment])
  end

  test "verified out-of-scope removal resolves only after Central explicitly says verified" do
    verified =
      disposition("thread-1", "remove_out_of_scope_change")
      |> Map.put("removalStatus", "verified")

    assert {:settle, [{:resolve, ^verified}]} =
             FindingRouter.plan(receipt_for_plan([verified]), [thread("thread-1")], [])
  end

  test "receipt schema accepts every finite disposition shape" do
    blocked =
      disposition("thread-1", "blocked_unverified")
      |> Map.put("findingCommentId", nil)

    fix = disposition("thread-2", "fix_in_current_pr")

    removal =
      disposition("thread-3", "remove_out_of_scope_change")
      |> Map.put("removalStatus", "verified")

    removal_with_follow_up =
      disposition("thread-4", "remove_out_of_scope_change")
      |> Map.put("removalStatus", "pending")
      |> Map.put("followUp", follow_up())

    suggestion =
      disposition("thread-5", "suggest_follow_up")
      |> Map.put("followUp", follow_up())

    dispositions = [blocked, fix, removal, removal_with_follow_up, suggestion]

    assert {:ok, _receipt} =
             FindingRouter.verify_receipt(
               check_run(receipt(dispositions)),
               workflow_run(),
               identity()
             )
  end

  test "accepts Central V3 merge decisions without treating them as Symphony merge authority" do
    v3 =
      receipt([])
      |> Map.put("schemaVersion", "aroak.work-routing-readiness.v3")
      |> Map.put("mergeDecision", "blocked")

    assert {:ok, %{"mergeDecision" => "blocked"}} =
             FindingRouter.verify_receipt(
               check_run(v3, :v3),
               workflow_run(),
               identity()
             )

    invalid = Map.put(v3, "mergeDecision", "auto_ready")

    assert {:error, :readiness_receipt_shape_invalid} =
             FindingRouter.verify_receipt(
               check_run(invalid, :v3),
               workflow_run(),
               identity()
             )
  end

  test "all malformed public inputs and marker shapes fail closed" do
    assert {:error, :readiness_check_missing} =
             FindingRouter.select_latest_check_run([], @head)

    assert {:error, :readiness_check_evidence_invalid} =
             FindingRouter.select_latest_check_run(:invalid, @head)

    assert {:error, :readiness_check_envelope_invalid} =
             FindingRouter.select_latest_check_run([check_run(receipt([])), "malformed"], @head)

    assert {:error, :readiness_check_envelope_invalid} =
             FindingRouter.select_latest_check_run([check_run(receipt([]))], "short")

    no_time =
      check_run(receipt([]))
      |> Map.drop(["created_at"])
      |> Map.put("started_at", nil)

    assert {:error, :readiness_check_time_missing} =
             FindingRouter.select_latest_check_run([no_time], @head)

    assert {:error, :readiness_receipt_envelope_invalid} =
             FindingRouter.verify_receipt(:invalid, workflow_run(), identity())

    missing_marker = put_in(check_run(receipt([])), ["output", "text"], "no receipt marker")

    assert {:error, :readiness_receipt_marker_invalid} =
             FindingRouter.verify_receipt(missing_marker, workflow_run(), identity())

    assert {:hold, :finding_router_evidence_invalid} =
             FindingRouter.plan(:invalid, [], [])

    assert {:hold, :finding_router_evidence_invalid} =
             FindingRouter.plan(receipt_for_plan([]), [:invalid], [])

    refute FindingRouter.trusted_follow_up_comment?(:invalid, "thread", @head, @digest)
    response = %{"body" => "expected", "user" => %{"node_id" => "U_kgDOEDjIhA"}}
    assert FindingRouter.trusted_follow_up_response?(response, "expected")
    refute FindingRouter.trusted_follow_up_response?(response, "different")
    refute FindingRouter.trusted_follow_up_response?(:invalid, "expected")

    trusted_actor = %{"node_id" => FindingRouter.trusted_follow_up_actor_node_id()}

    malformed_bodies = [
      nil,
      "no marker",
      "<!-- symphony-follow-up:v1\nnot-json\n-->",
      "<!-- symphony-follow-up:v1\n{\n}\n-->",
      "<!-- symphony-follow-up:v1\n[]\n-->",
      "<!-- symphony-follow-up:v1\n{}\n-->\n<!-- symphony-follow-up:v1\n{}\n-->"
    ]

    Enum.each(malformed_bodies, fn body ->
      refute FindingRouter.trusted_follow_up_comment?(
               %{"body" => body, "user" => trusted_actor},
               "thread",
               @head,
               @digest
             )
    end)
  end

  test "malformed receipt field types and disposition details are rejected" do
    invalid_receipts = [
      Map.put(receipt([]), "blockers", "not-a-list"),
      Map.put(receipt([]), "snapshotDigest", 42),
      Map.put(receipt([]), "receiptDigest", %{}),
      Map.put(receipt([]), "findingDispositions", "not-a-list"),
      receipt([disposition("thread-1", "unknown")]),
      receipt([
        disposition("thread-1", "remove_out_of_scope_change")
        |> Map.put("removalStatus", "assumed")
      ]),
      receipt([
        disposition("thread-1", "suggest_follow_up")
        |> Map.put("followUp", "not-an-object")
      ]),
      receipt([
        disposition("thread-1", "suggest_follow_up")
        |> Map.put("followUp", Map.put(follow_up(), "risk", 42))
      ])
    ]

    Enum.each(invalid_receipts, fn invalid ->
      assert {:error, :readiness_receipt_shape_invalid} =
               FindingRouter.verify_receipt(check_run(invalid), workflow_run(), identity())
    end)

    assert {:hold, :finding_router_evidence_invalid} =
             FindingRouter.plan(%{"findingDispositions" => "invalid"}, [], [])

    assert {:hold, :finding_router_evidence_invalid} =
             FindingRouter.plan(
               receipt_for_plan([disposition("missing", "fix_in_current_pr")]),
               [thread("other")],
               []
             )

    assert {:hold, :finding_router_evidence_invalid} =
             FindingRouter.plan(
               receipt_for_plan([disposition("missing", "fix_in_current_pr")]),
               [%{thread("other") | resolved: true}],
               []
             )
  end

  defp identity do
    %{
      repository: "aroakpm-svg/aroak-central-brain",
      pull_request_number: 79,
      base_sha: @base,
      head_sha: @head
    }
  end

  defp workflow_run do
    %{
      "status" => "completed",
      "path" => FindingRouter.workflow_path(),
      "event" => "pull_request_target",
      "head_sha" => @base,
      "check_suite_id" => 77,
      "repository" => %{"full_name" => "aroakpm-svg/aroak-central-brain"}
    }
  end

  defp check_run(receipt, version \\ :v2) do
    marker = if version == :v3, do: "v3", else: "v2"

    %{
      "id" => 1,
      "name" => FindingRouter.check_name(),
      "status" => "completed",
      "conclusion" => "failure",
      "head_sha" => @head,
      "completed_at" => "2026-08-01T00:00:00Z",
      "created_at" => "2026-08-01T00:00:00Z",
      "app" => %{"id" => FindingRouter.publisher_app_id()},
      "check_suite" => %{"id" => 77},
      "output" => %{
        "text" => "<!-- aroak-readiness-receipt:#{marker}\n#{Jason.encode!(receipt)}\n-->"
      }
    }
  end

  defp receipt(dispositions) do
    %{
      "schemaVersion" => "aroak.work-routing-readiness.v2",
      "repository" => "aroakpm-svg/aroak-central-brain",
      "pullRequestNumber" => 79,
      "baseSha" => @base,
      "headSha" => @head,
      "snapshotDigest" => String.duplicate("e", 64),
      "decision" => "blocked",
      "checkSet" => "full",
      "blockers" => ["actionable_threads_unresolved"],
      "findingDispositions" => dispositions,
      "evidence" => %{"policySha" => @base, "baseSha" => @base, "headSha" => @head},
      "receiptDigest" => @digest
    }
  end

  defp receipt_for_plan(dispositions),
    do: %{"headSha" => @head, "receiptDigest" => @digest, "findingDispositions" => dispositions}

  defp disposition(finding_id, disposition) do
    %{
      "findingId" => finding_id,
      "findingCommentId" => "comment-#{finding_id}",
      "disposition" => disposition,
      "evidenceDigest" => String.duplicate("f", 64)
    }
  end

  defp follow_up do
    %{
      "whySeparate" => "問題原本就在 main。",
      "work" => "另開一張票修正共享驗證器。",
      "risk" => "後續仍可能遇到同一問題。",
      "benefit" => "目前 PR 可以維持原本範圍。"
    }
  end

  defp thread(finding_id) do
    %{
      finding_id: finding_id,
      finding_comment_id: "comment-#{finding_id}",
      resolved: false,
      priority: 2,
      body: "P2 finding",
      path: "lib/example.ex",
      url: "https://example.test/thread"
    }
  end
end
