defmodule SymphonyElixir.PatchAuthorization.RequestIdentityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PatchAuthorization.RequestIdentity

  test "builds the same immutable identity for reordered opaque finding keys" do
    assert {:ok, first} = RequestIdentity.build(input(eligible_finding_keys: [{:finding, "b"}, {:finding, "a"}]))

    assert {:ok, second} =
             RequestIdentity.build(input(eligible_finding_keys: [{:finding, "a"}, {:finding, "b"}]))

    assert first.request_id == second.request_id
    assert first.request_fingerprint == second.request_fingerprint
    assert first.eligible_finding_keys == [{:finding, "a"}, {:finding, "b"}]
  end

  test "binds request identity to the exact head, digest, and human summary" do
    assert {:ok, request} = RequestIdentity.build(input())

    assert :ok = RequestIdentity.validate(request, input())

    assert {:error, :authorization_request_stale} =
             RequestIdentity.validate(request, input(evaluated_head_sha: "new-head"))

    assert {:error, :authorization_finding_set_changed} =
             RequestIdentity.validate(request, input(eligible_finding_set_digest: "new-digest"))

    assert {:error, :authorization_request_changed} =
             RequestIdentity.validate(request, input(human_summary: "different summary"))
  end

  test "rejects malformed or incomplete request identity input" do
    assert {:error, :invalid_request_input} = RequestIdentity.build(:not_a_map)
    assert {:error, :invalid_request_input} = RequestIdentity.validate(:not_a_map, input())

    for overrides <- [
          [profile: :other_profile],
          [repository: ""],
          [pull_request_number: 0],
          [evaluated_head_sha: ""],
          [eligible_finding_keys: :not_a_list],
          [eligible_finding_keys: []],
          [eligible_finding_set_digest: ""],
          [policy_version: ""],
          [human_summary: ""],
          [expected_transition: []]
        ] do
      assert {:error, _reason} = RequestIdentity.build(input(overrides))
    end
  end

  test "rejects a request whose stored fingerprint no longer matches its fields" do
    assert {:ok, request} = RequestIdentity.build(input())
    tampered = %{request | human_summary: "tampered after creation"}

    assert {:error, :request_fingerprint_mismatch} = RequestIdentity.validate(tampered, input())
  end

  defp input(overrides \\ []) do
    Enum.into(overrides, %{
      profile: :aroak_autonomous_v1,
      repository: "aroakpm-svg/symphony",
      pull_request_number: 28,
      evaluated_head_sha: "head-1",
      eligible_finding_keys: [{:finding, "b"}, {:finding, "a"}],
      eligible_finding_set_digest: "finding-digest-1",
      policy_version: "policy-v1",
      human_summary: "修正目前列出的責任範圍內問題",
      expected_transition: %{kind: :managed_patch, target: "head-2"}
    })
  end
end
