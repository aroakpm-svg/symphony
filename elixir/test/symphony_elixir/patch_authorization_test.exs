defmodule SymphonyElixir.PatchAuthorizationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PatchAuthorization

  defmodule Design2Contract do
    def finding_set_digest(_finding_keys), do: {:ok, "finding-set-digest"}
  end

  defmodule ProjectionDesign2Contract do
    def finding_set_digest(_finding_keys), do: {:ok, "finding-set-digest"}

    def classify_managed_publish(:not_managed, _native), do: :not_managed

    def classify_managed_publish({:managed, slot, state, reconciliation}, _native) do
      state = if state in [:pending, :unknown], do: :reserved_unresolved, else: state

      {:ok,
       %{
         slot: slot,
         state: state,
         identity: %{opaque: {slot, state}},
         reconciliation: reconciliation
       }}
    end

    def classify_managed_publish({:conflict, reason}, _native), do: {:error, reason}

    def managed_publish_identity(context) do
      send(self(), {:managed_identity_requested, context.slot})

      {:ok,
       %{
         opaque: {:managed_publish, context.slot, context.finding_keys},
         expected_transition: %{head_sha: context.evaluated_head_sha}
       }}
    end

    def verify_correction(_finding, %{verified: true}, _native, _ledger_entries), do: :ok
    def verify_correction(_finding, _evidence, _native, _ledger_entries), do: {:error, :not_verified}
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

  @tag :projection
  test "an absent verified initial intent returns one initial grant" do
    assert {:ok, %{slot: :automatic_initial_v1}} =
             authorize_with_projection(ledger_entries: [])

    refute_received {:authority_policy_called, _}
  end

  @tag :projection
  test "the same evidence reconstructs the same result on three nodes" do
    results =
      for node <- ["node-a", "node-b", "node-c"] do
        authorize_with_projection(
          ledger_entries: [succeeded_initial_entry()],
          evidence: evidence(%{native: %{node: node, current_head_sha: full_sha("b")}}),
          eligible_findings: [correction_finding()]
        )
      end

    assert Enum.uniq(results) |> length() == 1
  end

  @tag :projection
  test "pending and unknown managed publishes return reconciliation evidence" do
    for status <- [:pending, :unknown] do
      assert {:reconcile, %{slot_state: :reserved_unresolved, operation_id: "opaque-1"}} =
               authorize_with_projection(ledger_entries: [managed_entry(:automatic_initial_v1, status)])
    end
  end

  @tag :projection
  test "matching native success consumes initial and exposes verified correction" do
    assert {:ok, %{slot: :automatic_correction_v1}} =
             authorize_with_projection(
               ledger_entries: [succeeded_initial_entry()],
               evidence: evidence(%{native: %{current_head_sha: full_sha("b")}}),
               eligible_findings: [correction_finding()]
             )

    assert {:blocked, :managed_publish_native_conflict} =
             authorize_with_projection(ledger_entries: [{:conflict, :managed_publish_native_conflict}])
  end

  @tag :projection
  test "failed-no-effect remains reserved and cannot mint another identity" do
    assert {:reconcile, %{slot_state: :reserved_failed_no_effect, operation_id: "opaque-1"}} =
             authorize_with_projection(ledger_entries: [managed_entry(:automatic_initial_v1, :reserved_failed_no_effect)])

    refute_received {:managed_identity_requested, _}
  end

  @tag :projection
  test "same Design 2 operation ID with another fingerprint blocks globally" do
    assert {:blocked, :operation_fingerprint_conflict} =
             authorize_with_projection(ledger_entries: [{:conflict, :operation_fingerprint_conflict}])
  end

  defp input(overrides \\ %{}) do
    head = full_sha("a")

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

  defp evidence(overrides \\ %{}) do
    Map.merge(
      %{
        native: %{current_head_sha: full_sha("a")},
        comments: [],
        active_requests: [],
        used_approval_comment_ids: MapSet.new()
      },
      overrides
    )
  end

  defp authorize_with_projection(overrides) do
    overrides = Map.new(overrides)

    PatchAuthorization.authorize(
      input(Map.take(overrides, [:eligible_findings])),
      Map.get(overrides, :ledger_entries, []),
      Map.get(overrides, :evidence, evidence()),
      effect_scope(),
      dependencies(design2: ProjectionDesign2Contract)
    )
  end

  defp succeeded_initial_entry do
    managed_entry(:automatic_initial_v1, :consumed)
  end

  defp managed_entry(slot, state) do
    {:managed, slot, state, %{operation_id: "opaque-1"}}
  end

  defp correction_finding do
    Map.put(finding(), :correction_evidence, %{verified: true})
  end

  defp finding do
    %{
      finding_key: {:review_thread, "thread-1"},
      disposition: :fix_in_current_pr,
      source_head_sha: full_sha("a"),
      evaluated_head_sha: full_sha("a"),
      summary: "One scoped finding",
      correction_evidence: nil
    }
  end

  defp full_sha(character), do: String.duplicate(character, 40)

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
