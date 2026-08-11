defmodule SymphonyElixir.PatchAuthorizationGitHubTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubReviewClient

  @tag :github_authorization
  test "comment evidence preserves exact approval body and stable actor identity" do
    raw_comments = [
      %{
        "id" => 101,
        "body" => "  批准再修一輪  ",
        "created_at" => "2026-08-11T00:01:00Z",
        "user" => %{"login" => "maintainer", "id" => 42, "type" => "User"}
      }
    ]

    assert {:ok, [approval]} =
             GitHubReviewClient.normalize_authorization_comments_for_test(raw_comments)

    assert approval.comment_id == "101"
    assert approval.body == "  批准再修一輪  "
    assert approval.actor == %{login: "maintainer", id: "42", type: "User"}
    assert approval.created_at == "2026-08-11T00:01:00Z"
  end

  @tag :github_authorization
  test "null author does not invalidate the complete evidence snapshot" do
    raw_comments = [
      %{
        "id" => 102,
        "body" => "批准再修一輪",
        "created_at" => "2026-08-11T00:01:00Z",
        "user" => nil
      },
      %{
        "id" => 103,
        "body" => "批准再修一輪",
        "created_at" => "2026-08-11T00:02:00Z",
        "user" => %{"login" => "maintainer", "id" => 42, "type" => "User"}
      }
    ]

    assert {:ok, [unknown, known]} =
             GitHubReviewClient.normalize_authorization_comments_for_test(raw_comments)

    assert unknown.actor == %{login: nil, id: nil, type: nil}
    assert known.actor.id == "42"
  end

  @tag :github_authorization
  test "managed request marker round trips opaque finding keys without selecting a newest marker" do
    request = %{
      request_id: "request-1",
      repository: "aroakpm-svg/symphony",
      pull_request_number: 25,
      evaluated_head_sha: String.duplicate("a", 40),
      eligible_finding_set_digest: "digest-1",
      eligible_finding_keys: [{:review_thread, "thread-1"}],
      policy_version: "policy-v1",
      human_summary: "One finding",
      expected_transition: %{head_sha: String.duplicate("a", 40)},
      request_fingerprint: "fingerprint-1"
    }

    body = GitHubReviewClient.authorization_request_body_for_test(request)

    assert {:ok, decoded} = GitHubReviewClient.parse_authorization_request_for_test(body)
    assert decoded == request
  end

  @tag :github_authorization
  test "managed request body includes bounded human instructions and summary" do
    request = %{
      request_id: "request-1",
      repository: "aroakpm-svg/symphony",
      pull_request_number: 27,
      evaluated_head_sha: String.duplicate("b", 40),
      eligible_finding_set_digest: "digest-1",
      eligible_finding_keys: [{:review_thread, "thread-1"}],
      policy_version: "policy-v1",
      human_summary: "P1 stale approval binding",
      expected_transition: %{head_sha: String.duplicate("b", 40)},
      request_fingerprint: "fingerprint-1"
    }

    body = GitHubReviewClient.authorization_request_body_for_test(request)

    assert body =~ "Pull request: #27"
    assert body =~ "Head: #{String.duplicate("b", 40)}"
    assert body =~ "Findings: P1 stale approval binding"
    assert body =~ "批准再修一輪"
  end

  @tag :github_authorization
  test "managed request normalization preserves comment provenance metadata" do
    request = %{
      request_id: "request-1",
      repository: "aroakpm-svg/symphony",
      pull_request_number: 27,
      evaluated_head_sha: String.duplicate("b", 40),
      eligible_finding_set_digest: "digest-1",
      eligible_finding_keys: [{:review_thread, "thread-1"}],
      policy_version: "policy-v1",
      human_summary: "P1 stale approval binding",
      expected_transition: %{head_sha: String.duplicate("b", 40)},
      request_fingerprint: "fingerprint-1"
    }

    body = GitHubReviewClient.authorization_request_body_for_test(request)

    assert {:ok, [normalized]} =
             GitHubReviewClient.normalize_authorization_requests_for_test([
               %{
                 "id" => 707,
                 "body" => body,
                 "created_at" => "2026-08-11T00:00:00Z",
                 "user" => %{"login" => "symphony-integration", "id" => 1, "type" => "Bot"}
               }
             ])

    assert normalized.authorization_request_comment_id == "707"
    assert normalized.authorization_request_created_at == "2026-08-11T00:00:00Z"
    assert normalized.authorization_request_author == %{login: "symphony-integration", id: "1", type: "Bot"}

    assert Map.drop(normalized, [
             :authorization_request_comment_id,
             :authorization_request_created_at,
             :authorization_request_author
           ]) == request
  end

  @tag :github_authorization
  test "malformed managed request marker is rejected instead of becoming active evidence" do
    assert {:error, :invalid_authorization_request_marker} =
             GitHubReviewClient.parse_authorization_request_for_test("<!-- symphony-managed-patch-authorization:v1 -->\nrequest-payload: not-base64")
  end
end
