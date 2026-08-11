defmodule SymphonyElixir.PatchAuthorizationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PatchAuthorization

  defmodule Design2Contract do
    def finding_set_digest(_finding_keys), do: {:ok, "finding-set-digest"}
  end

  defmodule UnavailableContract do
  end

  @tag :contract
  test "authorize fails closed when the Design 2 contract is unavailable" do
    assert {:blocked, :design2_contract_unavailable} =
             PatchAuthorization.authorize(
               input(),
               [],
               evidence(),
               effect_scope(),
               dependencies(design2: UnavailableContract)
             )
  end

  @tag :contract
  test "authorize rejects a non-current disposition without importing Design 2 types" do
    bad =
      put_in(
        input(),
        [:eligible_findings, Access.at(0), :disposition],
        :follow_up_required
      )

    assert {:blocked, {:invalid_finding_disposition, :follow_up_required}} =
             PatchAuthorization.authorize(
               bad,
               [],
               evidence(),
               effect_scope(),
               dependencies()
             )
  end

  @tag :contract
  test "authorize rejects findings evaluated on another head" do
    bad =
      put_in(
        input(),
        [:eligible_findings, Access.at(0), :evaluated_head_sha],
        String.duplicate("b", 40)
      )

    assert {:blocked, :finding_evaluated_head_mismatch} =
             PatchAuthorization.authorize(
               bad,
               [],
               evidence(),
               effect_scope(),
               dependencies()
             )
  end

  @tag :contract
  test "authorize fails closed when an eligible finding has the wrong shape" do
    bad = Map.put(input(), :eligible_findings, [:malformed])

    assert {:blocked, :invalid_finding_shape} =
             PatchAuthorization.authorize(
               bad,
               [],
               evidence(),
               effect_scope(),
               dependencies()
             )
  end

  defp input(overrides \\ %{}) do
    head = String.duplicate("a", 40)

    %{
      profile: :aroak_autonomous_v1,
      repository: "aroakpm-svg/symphony",
      pull_request_number: 25,
      evaluated_head_sha: head,
      eligible_findings: [
        %{
          finding_key: {:review_thread, "thread-1"},
          disposition: :fix_in_current_pr,
          source_head_sha: head,
          evaluated_head_sha: head,
          summary: "P2 scoped finding",
          correction_evidence: nil
        }
      ],
      human_summary: "One scoped finding"
    }
    |> Map.merge(overrides)
  end

  defp evidence do
    %{
      native: %{current_head_sha: String.duplicate("a", 40)},
      comments: [],
      active_requests: [],
      used_approval_comment_ids: MapSet.new()
    }
  end

  defp effect_scope do
    %{
      connection: nil,
      claim_context: %{
        repository: "aroakpm-svg/symphony",
        pull_request_number: 25
      }
    }
  end

  defp dependencies(overrides \\ []) do
    Map.merge(
      %{
        design2: Design2Contract,
        authority_policy: nil,
        effect_ledger: nil,
        github: nil
      },
      Map.new(overrides)
    )
  end
end
