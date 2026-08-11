defmodule SymphonyElixir.PatchAuthorization.ApprovalBindingStruct do
  defstruct [:request_id, :evaluated_head_sha, :eligible_finding_set_digest]
end

defmodule SymphonyElixir.PatchAuthorization.ApprovalBindingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PatchAuthorization.ApprovalBinding

  test "binds only the exact command to the current request snapshot" do
    assert {:ok, binding} = ApprovalBinding.bind(request(), approval(body: "  批准再修一輪  "), evidence())

    assert binding.slot == {:human, "request-1", "comment-1", "actor-42"}
    assert binding.authorization_identity == "actor-42"

    assert {:error, :invalid_authorization_command} =
             ApprovalBinding.bind(request(), approval(body: "可以，繼續修"), evidence())
  end

  test "rejects stale head and changed finding-set evidence" do
    assert {:error, :authorization_request_stale} =
             ApprovalBinding.bind(request(), approval(), evidence(current_head_sha: "new-head"))

    assert {:error, :authorization_finding_set_changed} =
             ApprovalBinding.bind(request(), approval(), evidence(current_finding_set_digest: "new-digest"))
  end

  test "requires verified actor and authorized policy evidence" do
    assert {:ok, _binding} =
             ApprovalBinding.bind(
               request(),
               approval(actor: %{"id" => "actor-42", "type" => "User"}),
               evidence()
             )

    assert {:error, :authorization_actor_unknown} =
             ApprovalBinding.bind(
               request(),
               approval(actor: %{id: nil, login: "maintainer", type: "User"}),
               evidence()
             )

    assert {:error, :authorization_actor_unknown} =
             ApprovalBinding.bind(request(), approval(actor: "actor-42"), evidence())

    assert {:error, :authorization_actor_unknown} =
             ApprovalBinding.bind(request(), approval(actor: %{id: "", type: "User"}), evidence())

    assert {:error, :authorization_actor_unknown} =
             ApprovalBinding.bind(request(), approval(actor: %URI{}), evidence())

    consistent_actor = %{
      "id" => "actor-42",
      "type" => "User",
      id: "actor-42",
      type: "User"
    }

    assert {:ok, _binding} =
             ApprovalBinding.bind(request(), approval(actor: consistent_actor), evidence())

    assert {:error, :authorization_actor_mismatch} =
             ApprovalBinding.bind(
               request(),
               approval(),
               evidence(authority_result: %{status: :authorized, actor_id: "different-actor"})
             )

    assert {:error, :authorization_actor_unknown} =
             ApprovalBinding.bind(
               request(),
               approval(),
               evidence(authority_result: %{status: :authorized})
             )

    assert {:error, :authorization_actor_unknown} =
             ApprovalBinding.bind(
               request(),
               approval(),
               evidence(authority_result: %{status: :authorized, actor_id: ""})
             )

    for actor_type <- ["Bot", "App", "Organization"] do
      assert {:error, :non_human_actor} =
               ApprovalBinding.bind(request(), approval(actor: %{id: "actor-42", type: actor_type}), evidence())
    end

    assert {:error, :unauthorized_actor} =
             ApprovalBinding.bind(
               request(),
               approval(),
               evidence(authority_result: %{status: :unauthorized, actor_id: "actor-42"})
             )

    assert {:error, :authorization_policy_unavailable} =
             ApprovalBinding.bind(
               request(),
               approval(),
               evidence(authority_result: %{status: :unknown, actor_id: "actor-42"})
             )
  end

  test "rejects contradictory atom and string actor identities" do
    conflicting_actor = %{
      "id" => "different-actor",
      "type" => "Bot",
      id: "actor-42",
      type: "User"
    }

    assert {:error, :authorization_actor_conflict} =
             ApprovalBinding.bind(request(), approval(actor: conflicting_actor), evidence())

    conflicting_authority = %{
      "actor_id" => "different-actor",
      status: :authorized,
      actor_id: "actor-42"
    }

    assert {:error, :authorization_actor_conflict} =
             ApprovalBinding.bind(request(), approval(), evidence(authority_result: conflicting_authority))
  end

  test "requires approval provenance to match the immutable request scope" do
    for overrides <- [
          [request_id: "different-request"],
          [repository: "other-owner/other-repo"],
          [pull_request_number: 31],
          [head_sha: "different-head"],
          [finding_set_digest: "different-digest"]
        ] do
      assert {:error, :authorization_request_mismatch} =
               ApprovalBinding.bind(request(), approval(provenance: provenance(overrides)), evidence())
    end

    assert {:error, :authorization_provenance_unknown} =
             ApprovalBinding.bind(request(), approval(provenance: provenance(status: :unknown)), evidence())

    assert {:error, :authorization_provenance_unknown} =
             ApprovalBinding.bind(request(), approval(provenance: provenance(repository: "")), evidence())

    assert {:error, :authorization_provenance_unknown} =
             ApprovalBinding.bind(request(), approval(provenance: nil), evidence())
  end

  test "rejects reused approval comments and malformed evidence" do
    assert {:error, :invalid_approval_evidence} = ApprovalBinding.bind(:bad, approval(), evidence())

    assert {:error, :approval_comment_already_used} =
             ApprovalBinding.bind(request(), approval(), evidence(used_comment_ids: MapSet.new(["comment-1"])))

    assert {:error, :invalid_approval_evidence} =
             ApprovalBinding.bind(request(), approval(comment_id: ""), evidence())

    forged_map_set = Map.put(MapSet.new(), :map, :not_a_map)

    assert {:error, :invalid_approval_evidence} =
             ApprovalBinding.bind(request(), approval(), evidence(used_comment_ids: forged_map_set))

    assert {:error, :invalid_approval_evidence} =
             ApprovalBinding.bind(request(), approval(), %{current_head_sha: "head-1"})
  end

  test "rejects struct-shaped request, approval, and evidence without raising" do
    struct_record = %SymphonyElixir.PatchAuthorization.ApprovalBindingStruct{}

    assert {:error, :invalid_approval_evidence} =
             ApprovalBinding.bind(struct_record, approval(), evidence())

    assert {:error, :invalid_approval_evidence} =
             ApprovalBinding.bind(request(), struct_record, evidence())

    assert {:error, :invalid_approval_evidence} =
             ApprovalBinding.bind(request(), approval(), struct_record)
  end

  defp request do
    %{
      request_id: "request-1",
      repository: "aroakpm-svg/symphony",
      pull_request_number: 30,
      evaluated_head_sha: "head-1",
      eligible_finding_set_digest: "digest-1"
    }
  end

  defp approval(overrides \\ []) do
    Enum.into(overrides, %{
      comment_id: "comment-1",
      body: "批准再修一輪",
      actor: %{id: "actor-42", login: "maintainer", type: "User"},
      provenance: provenance()
    })
  end

  defp provenance(overrides \\ []) do
    Enum.into(overrides, %{
      status: :verified,
      request_id: "request-1",
      repository: "aroakpm-svg/symphony",
      pull_request_number: 30,
      head_sha: "head-1",
      finding_set_digest: "digest-1"
    })
  end

  defp evidence(overrides \\ []) do
    Enum.into(overrides, %{
      current_head_sha: "head-1",
      current_finding_set_digest: "digest-1",
      authority_result: %{status: :authorized, actor_id: "actor-42"},
      used_comment_ids: MapSet.new()
    })
  end
end
