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

  defmodule AuthorityPolicy do
    def version, do: {:ok, "policy-v1"}

    def authorize_human_actor(%{approval: %{actor: %{id: "42"}}}), do: :authorized
    def authorize_human_actor(_evidence), do: :unauthorized
  end

  defmodule UnknownAuthorityPolicy do
    def version, do: :unknown

    def authorize_human_actor(_evidence), do: :unknown
  end

  defmodule ApprovalEffectLedger do
    def execute(_connection, :github_comment, context, adapter, reconciler) do
      send(self(), {:github_request_effect, context})

      case reconciler.() do
        :not_found -> adapter.()
        result -> result
      end
    end
  end

  defmodule ApprovalGitHubClient do
    def create_authorization_request(repository, pull_request_number, request) do
      send(self(), {:github_request_create, repository, pull_request_number, request})
      {:ok, %{comment_id: "request-comment-1"}}
    end

    def find_authorization_request(_repository, _pull_request_number, _request),
      do: :not_found
  end

  defmodule BadDigestContract do
    def finding_set_digest(_finding_keys), do: :invalid
  end

  defmodule RaisingDigestContract do
    def finding_set_digest(_finding_keys), do: raise("digest unavailable")
  end

  defmodule EdgeDesign2Contract do
    def finding_set_digest(_finding_keys) do
      case Process.get(:design2_digest_mode, :ok) do
        :ok -> {:ok, "finding-set-digest"}
        :invalid -> :invalid
        :raise -> raise("digest unavailable")
      end
    end

    def classify_managed_publish(entry, _native) do
      case Process.get(:design2_classify_mode, :entry) do
        :not_managed -> :not_managed
        :invalid -> :invalid
        :error -> {:error, :classification_error}
        :raise -> raise("classification unavailable")
        :entry -> classify_entry(entry)
      end
    end

    def managed_publish_identity(context) do
      case Process.get(:design2_identity_mode, :ok) do
        :ok ->
          {:ok,
           %{
             opaque: {:edge_identity, context.slot},
             expected_transition: %{head_sha: context.evaluated_head_sha}
           }}

        :missing_transition ->
          {:ok, %{opaque: :missing_transition}}

        :error ->
          {:error, :identity_error}

        :other ->
          :invalid

        :raise ->
          raise("identity unavailable")
      end
    end

    def verify_correction(_finding, _evidence, _native, _ledger_entries) do
      case Process.get(:design2_correction_mode, :ok) do
        :ok -> :ok
        :conflict -> {:error, {:conflict, :correction_conflict}}
        :correction_conflict -> {:error, :correction_conflict}
        :not_verified -> {:error, :not_verified}
        :other -> :invalid
        :raise -> raise("correction unavailable")
      end
    end

    defp classify_entry({:managed, slot, state, reconciliation}) do
      {:ok,
       %{
         slot: slot,
         state: state,
         identity: %{opaque: {slot, state}},
         reconciliation: reconciliation
       }}
    end

    defp classify_entry({:projection, projection}), do: {:ok, projection}
    defp classify_entry(_entry), do: :not_managed
  end

  defmodule EdgeAuthorityPolicy do
    def version, do: {:ok, "policy-v1"}

    def authorize_human_actor(_evidence),
      do: Process.get(:authority_result, :unknown)
  end

  defmodule EdgeEffectLedger do
    def execute(_connection, :github_comment, _context, adapter, _reconciler) do
      case Process.get(:effect_mode, :ok) do
        :ok -> adapter.()
        :operation_conflict -> {:error, :operation_fingerprint_conflict}
        :operation_conflict_tuple -> {:error, {:operation_fingerprint_conflict, :details}}
        :error -> {:error, :effect_error}
        :other -> :invalid
        :raise -> raise("effect unavailable")
      end
    end
  end

  defmodule EdgeGitHubClient do
    def create_authorization_request(_repository, _pull_request_number, _request),
      do: {:ok, %{comment_id: "request-comment-1"}}

    def find_authorization_request(_repository, _pull_request_number, _request),
      do: :not_found
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
  test "valid input fails closed when Design 2 projection callbacks are not present" do
    assert {:blocked, :design2_projection_contract_unavailable} =
             PatchAuthorization.authorize(
               input(),
               [],
               evidence(),
               effect_scope(),
               dependencies()
             )
  end

  @tag :contract
  test "invalid top-level and dependency shapes fail closed" do
    assert {:blocked, :invalid_authorization_input} =
             PatchAuthorization.authorize(:invalid, [], evidence(), effect_scope(), dependencies())

    assert {:blocked, :design2_contract_unavailable} =
             PatchAuthorization.authorize(input(), [], evidence(), effect_scope(), %{})
  end

  @tag :contract
  test "malformed authorization input fields fail closed" do
    cases = [
      {%{profile: :other}, {:invalid_profile, :other}},
      {%{delete: :profile}, :missing_profile},
      {%{repository: ""}, :invalid_repository},
      {%{pull_request_number: 0}, :invalid_pull_request_number},
      {%{evaluated_head_sha: nil}, :invalid_evaluated_head_sha},
      {%{eligible_findings: []}, :missing_eligible_findings}
    ]

    assert Enum.all?(cases, fn {override, reason} ->
             override = if Map.has_key?(override, :delete), do: Map.drop(input(), [:profile]), else: input(override)

             {:blocked, reason} ==
               PatchAuthorization.authorize(override, [], evidence(), effect_scope(), dependencies())
           end)
  end

  @tag :contract
  test "malformed finding evidence and Design 2 digest fail closed" do
    assert {:blocked, :missing_finding_key} =
             PatchAuthorization.authorize(
               input(%{eligible_findings: [%{disposition: :fix_in_current_pr}]}),
               [],
               evidence(),
               effect_scope(),
               dependencies()
             )

    assert {:blocked, :missing_finding_disposition} =
             PatchAuthorization.authorize(
               input(%{eligible_findings: [Map.delete(finding(), :disposition)]}),
               [],
               evidence(),
               effect_scope(),
               dependencies()
             )

    assert {:blocked, :invalid_finding_head_evidence} =
             PatchAuthorization.authorize(
               input(%{eligible_findings: [Map.put(finding(), :source_head_sha, nil)]}),
               [],
               evidence(),
               effect_scope(),
               dependencies()
             )

    assert {:blocked, :design2_finding_set_digest_unavailable} =
             PatchAuthorization.authorize(
               input(),
               [],
               evidence(),
               effect_scope(),
               dependencies(design2: BadDigestContract)
             )

    assert {:blocked, :design2_finding_set_digest_unavailable} =
             PatchAuthorization.authorize(
               input(),
               [],
               evidence(),
               effect_scope(),
               dependencies(design2: RaisingDigestContract)
             )
  end

  @tag :contract
  test "claim scope and correction evidence boundaries fail closed" do
    assert {:blocked, :claim_scope_unavailable} =
             PatchAuthorization.authorize(
               input(),
               [],
               evidence(),
               %{},
               dependencies()
             )

    assert {:authorization_required, _request} =
             with_process(:design2_correction_mode, :not_verified, fn ->
               edge_authorize(
                 ledger_entries: [{:managed, :automatic_initial_v1, :consumed, %{}}],
                 eligible_findings: [correction_finding()]
               )
             end)
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
    assert {
             :reconcile,
             %{slot_state: :reserved_failed_no_effect, operation_id: "opaque-1"}
           } =
             authorize_with_projection(
               ledger_entries: [
                 managed_entry(:automatic_initial_v1, :reserved_failed_no_effect)
               ]
             )

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

  @tag :projection
  test "projection ignores non-managed entries and rejects malformed Design 2 results" do
    assert {:ok, %{slot: :automatic_initial_v1}} =
             edge_authorize(ledger_entries: [:not_managed])

    assert {:blocked, :design2_projection_invalid} =
             with_process(:design2_classify_mode, :invalid, fn -> edge_authorize(ledger_entries: [:entry]) end)

    assert {:blocked, :classification_error} =
             with_process(:design2_classify_mode, :error, fn -> edge_authorize(ledger_entries: [:entry]) end)

    assert {:blocked, :design2_callback_failed} =
             with_process(:design2_classify_mode, :raise, fn -> edge_authorize(ledger_entries: [:entry]) end)

    assert {:blocked, :design2_projection_invalid} =
             edge_authorize(ledger_entries: [{:projection, :not_a_record}])
  end

  @tag :projection
  test "projection rejects malformed slot records and duplicate automatic slots" do
    malformed = [
      {:bad_slot, :consumed, %{opaque: :id}, %{}},
      {:automatic_initial_v1, :bad_state, %{opaque: :id}, %{}},
      {:automatic_initial_v1, :consumed, :bad_identity, %{}},
      {:automatic_initial_v1, :consumed, %{opaque: :id}, :bad_reconciliation},
      {{:human, "", "comment", "actor"}, :consumed, %{opaque: :id}, %{}},
      {:automatic_initial_v1, :consumed, %{opaque: :id}, %{}}
    ]

    expected = [
      :design2_projection_invalid_slot,
      :design2_projection_invalid_state,
      :design2_projection_invalid_identity,
      :design2_projection_invalid_reconciliation,
      :design2_projection_invalid_slot
    ]

    assert Enum.zip(malformed, expected)
           |> Enum.all?(fn {{slot, state, identity, reconciliation}, reason} ->
             projection = %{slot: slot, state: state, identity: identity, reconciliation: reconciliation}

             {:blocked, reason} == edge_authorize(ledger_entries: [{:projection, projection}])
           end)

    duplicate = {:managed, :automatic_initial_v1, :consumed, %{}}

    assert {:blocked, :duplicate_managed_slot} =
             edge_authorize(ledger_entries: [duplicate, duplicate])
  end

  @tag :projection
  test "available initial slot and missing Design 2 identity details fail closed" do
    assert {:ok, %{slot: :automatic_initial_v1}} =
             edge_authorize(ledger_entries: [{:managed, :automatic_initial_v1, :available, %{}}])

    for mode <- [:missing_transition, :error, :other, :raise] do
      expected =
        case mode do
          :missing_transition -> :design2_managed_publish_identity_unavailable
          :error -> :identity_error
          :other -> :design2_managed_publish_identity_unavailable
          :raise -> :design2_callback_failed
        end

      assert {:blocked, ^expected} =
               with_process(:design2_identity_mode, mode, fn -> edge_authorize(ledger_entries: []) end)
    end
  end

  @tag :projection
  test "correction state routes and correction verifier failures stay fail closed" do
    assert {:ok, %{slot: :automatic_correction_v1}} =
             edge_authorize(
               ledger_entries: [
                 {:managed, :automatic_initial_v1, :consumed, %{}},
                 {:managed, :automatic_correction_v1, :available, %{}}
               ],
               eligible_findings: [correction_finding()]
             )

    assert {:authorization_required, _request} =
             edge_authorize(
               ledger_entries: [
                 {:managed, :automatic_initial_v1, :consumed, %{}},
                 {:managed, :automatic_correction_v1, :consumed, %{}}
               ],
               eligible_findings: [correction_finding()]
             )

    assert {:blocked, :correction_conflict} =
             with_process(:design2_correction_mode, :conflict, fn ->
               edge_authorize(
                 ledger_entries: [{:managed, :automatic_initial_v1, :consumed, %{}}],
                 eligible_findings: [correction_finding()]
               )
             end)

    assert {:blocked, :correction_conflict} =
             with_process(:design2_correction_mode, :correction_conflict, fn ->
               edge_authorize(
                 ledger_entries: [{:managed, :automatic_initial_v1, :consumed, %{}}],
                 eligible_findings: [correction_finding()]
               )
             end)

    assert {:blocked, :design2_correction_verification_invalid} =
             with_process(:design2_correction_mode, :other, fn ->
               edge_authorize(
                 ledger_entries: [{:managed, :automatic_initial_v1, :consumed, %{}}],
                 eligible_findings: [correction_finding()]
               )
             end)

    assert {:blocked, :invalid_correction_evidence} =
             edge_authorize(
               ledger_entries: [{:managed, :automatic_initial_v1, :consumed, %{}}],
               eligible_findings: [Map.put(finding(), :correction_evidence, :malformed)]
             )
  end

  @tag :approval
  test "only the fixed command after outer whitespace is accepted" do
    assert {:ok, %{slot: {:human, _, "approval-1", "42"}}} =
             authorize_with_approval(approval: approval(%{body: "  批准再修一輪  "}))

    assert {:blocked, :invalid_authorization_command} =
             authorize_with_approval(approval: approval(%{body: "可以，繼續修"}))
  end

  @tag :approval
  test "missing actor identity or explicit unauthorized result fails closed" do
    assert {:blocked, :authorization_actor_unknown} =
             authorize_with_approval(approval: approval(%{actor: %{login: "maintainer", id: nil}}))

    assert {:blocked, :unauthorized_actor} =
             authorize_with_approval(approval: approval(%{actor: %{login: "untrusted", id: "99"}}))
  end

  @tag :approval
  test "missing policy blocks only the human request path" do
    assert {:blocked, :authorization_policy_unavailable} =
             authorize_with_approval(authority_policy: nil, active_requests: [])

    refute_received {:github_request_effect, _}
    refute_received {:github_request_create, _, _, _}
  end

  @tag :approval
  test "authorization request uses one existing github_comment effect path" do
    assert {:authorization_required, _request} =
             authorize_with_approval(active_requests: [], approval: nil)

    assert_received {:github_request_effect, %{operation_id: operation_id}}
    assert String.starts_with?(operation_id, "symphony_authorization_request_v1:")
    assert_received {:github_request_create, "aroakpm-svg/symphony", 25, _request}
  end

  @tag :approval
  test "human authorization evidence and effect failures fail closed" do
    assert {:blocked, :authorization_policy_unavailable} =
             authorize_with_approval(authority_policy: "not-a-policy")

    assert {:blocked, :authorization_evidence_unavailable} =
             authorize_with_approval(evidence_overrides: %{active_requests: nil})

    assert {:blocked, :authorization_current_head_unavailable} =
             authorize_with_approval(
               active_requests: [],
               evidence_overrides: %{native: %{current_head_sha: "bad"}}
             )

    assert {:blocked, :authorization_current_head_unavailable} =
             authorize_with_approval(active_requests: [], evidence_overrides: %{native: %{}})

    assert {:blocked, :authorization_claim_context_unavailable} =
             authorize_with_approval(
               active_requests: [],
               effect_scope: %{connection: nil, claim_context: %{repository: "aroakpm-svg/symphony", pull_request_number: 25}}
             )

    for mode <- [:operation_conflict, :operation_conflict_tuple, :error, :other, :raise] do
      expected =
        case mode do
          :operation_conflict -> :operation_fingerprint_conflict
          :operation_conflict_tuple -> :operation_fingerprint_conflict
          :error -> {:authorization_request_effect_failed, :effect_error}
          :other -> :authorization_request_effect_invalid
          :raise -> {:authorization_request_effect_failed, :external_callback_failed}
        end

      assert {:blocked, ^expected} =
               with_process(:effect_mode, mode, fn ->
                 authorize_with_approval(
                   active_requests: [],
                   effect_ledger: EdgeEffectLedger,
                   github: EdgeGitHubClient
                 )
               end)
    end
  end

  @tag :approval
  test "approval evidence validation is explicit and fail closed" do
    assert {:error, :authorization_approval_pending} =
             human_authorization_for_test(evidence_overrides: %{comments: []})

    assert {:error, :invalid_authorization_approval} =
             human_authorization_for_test(evidence_overrides: %{comments: [nil]})

    assert {:error, :authorization_evidence_unavailable} =
             human_authorization_for_test(evidence_overrides: %{comments: nil})

    assert {:error, :invalid_authorization_command} =
             human_authorization_for_test(approval: %{})

    assert {:error, :authorization_approval_identity_unavailable} =
             human_authorization_for_test(
               approval: %{body: "批准再修一輪", actor: %{id: "42"}},
               evidence_overrides: %{used_approval_comment_ids: MapSet.new()}
             )

    assert {:error, :authorization_evidence_unavailable} =
             human_authorization_for_test(evidence_overrides: %{used_approval_comment_ids: nil})

    assert {:error, :authorization_policy_unavailable} =
             with_process(:authority_result, :unknown, fn ->
               human_authorization_for_test(
                 approval: approval(),
                 authority_policy: EdgeAuthorityPolicy
               )
             end)
  end

  @tag :approval
  test "human request binding rejects digest, identity, and dependency drift" do
    assert {:blocked, :authorization_finding_set_changed} =
             authorize_with_approval(active_request: request(%{eligible_finding_set_digest: "different-digest"}))

    assert {:blocked, :authorization_evidence_unavailable} =
             authorize_with_approval(active_request: request(), evidence_overrides: %{comments: nil})

    assert {:blocked, :authorization_effect_unavailable} =
             authorize_with_approval(
               active_requests: [],
               dependencies: %{design2: ProjectionDesign2Contract, authority_policy: AuthorityPolicy}
             )

    for mode <- [:error, :other] do
      expected =
        if mode == :error, do: :identity_error, else: :design2_managed_publish_identity_unavailable

      assert {:blocked, ^expected} =
               with_process(:design2_identity_mode, mode, fn ->
                 authorize_with_approval(active_request: request(), design2: EdgeDesign2Contract)
               end)
    end
  end

  @tag :approval
  test "tampered managed request identity fails closed" do
    assert {:blocked, :authorization_request_identity_mismatch} =
             authorize_with_approval(active_request: request(%{request_fingerprint: "tampered-fingerprint"}))

    assert {:blocked, :authorization_request_identity_mismatch} =
             authorize_with_approval(active_request: request(%{request_id: "tampered-request"}))
  end

  @tag :approval
  test "unknown policy blocks human approval without transferring authority" do
    assert {:blocked, :authorization_policy_unavailable} =
             authorize_with_approval(authority_policy: UnknownAuthorityPolicy)

    refute_received {:managed_identity_requested, {:human, _}}
  end

  @tag :approval
  test "changed head or FindingKey set cannot inherit approval" do
    assert {:blocked, :authorization_request_stale} =
             authorize_with_approval(
               active_request: request(%{evaluated_head_sha: full_sha("b")}),
               current_head_sha: full_sha("a")
             )

    assert {:blocked, :authorization_finding_set_changed} =
             authorize_with_approval(extra_finding: true)
  end

  @tag :approval
  test "one approval comment ID cannot authorize two human slots" do
    assert {:blocked, :approval_comment_already_used} =
             authorize_with_approval(used_approval_comment_ids: MapSet.new(["approval-1"]))
  end

  @tag :approval
  test "zero or duplicate managed request markers fail deterministically" do
    assert {:authorization_required, request} =
             authorize_with_approval(active_requests: [])

    assert request.request_id != "request-1"

    assert {:blocked, :ambiguous_active_request} =
             authorize_with_approval(active_requests: [request(), request(%{request_id: "request-2"})])
  end

  @tag :approval
  test "zero or more historical human slots do not cap future requests" do
    assert {:authorization_required, request} =
             authorize_with_approval(
               ledger_entries: [
                 managed_entry(:automatic_initial_v1, :consumed),
                 managed_entry(:automatic_correction_v1, :consumed),
                 managed_entry({:human, "request-1", "comment-1", "actor-1"}, :consumed),
                 managed_entry({:human, "request-2", "comment-2", "actor-1"}, :consumed)
               ],
               active_requests: []
             )

    refute request.request_id in ["request-1", "request-2"]
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

  defp edge_authorize(overrides) do
    overrides = Map.new(overrides)

    PatchAuthorization.authorize(
      input(Map.take(overrides, [:eligible_findings])),
      Map.get(overrides, :ledger_entries, []),
      Map.get(overrides, :evidence, evidence()),
      effect_scope(),
      dependencies(
        design2: EdgeDesign2Contract,
        authority_policy: EdgeAuthorityPolicy,
        effect_ledger: EdgeEffectLedger,
        github: EdgeGitHubClient
      )
    )
  end

  defp human_authorization_for_test(overrides) do
    case authorize_with_approval(overrides) do
      {:blocked, reason} -> {:error, reason}
      result -> result
    end
  end

  defp authorize_with_approval(overrides) do
    overrides = Map.new(overrides)
    active_request = Map.get(overrides, :active_request, request())
    current_head_sha = Map.get(overrides, :current_head_sha, full_sha("a"))
    eligible_findings = if Map.get(overrides, :extra_finding, false), do: [finding(), extra_finding()], else: [finding()]

    approval_evidence =
      Map.merge(
        evidence(%{
          native: %{current_head_sha: current_head_sha},
          comments: [Map.get(overrides, :approval, approval())],
          active_requests: Map.get(overrides, :active_requests, [active_request]),
          used_approval_comment_ids: Map.get(overrides, :used_approval_comment_ids, MapSet.new())
        }),
        Map.get(overrides, :evidence_overrides, %{})
      )

    dependency_defaults =
      dependencies(
        design2: Map.get(overrides, :design2, ProjectionDesign2Contract),
        authority_policy: Map.get(overrides, :authority_policy, AuthorityPolicy),
        effect_ledger: Map.get(overrides, :effect_ledger, ApprovalEffectLedger),
        github: Map.get(overrides, :github, ApprovalGitHubClient)
      )

    PatchAuthorization.authorize(
      input(%{eligible_findings: eligible_findings}),
      Map.get(overrides, :ledger_entries, [succeeded_initial_entry()]),
      approval_evidence,
      Map.get(overrides, :effect_scope, effect_scope()),
      Map.get(overrides, :dependencies, dependency_defaults)
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

  defp extra_finding do
    Map.merge(finding(), %{finding_key: {:review_thread, "thread-2"}, summary: "Second finding"})
  end

  defp request(overrides \\ %{}) do
    request =
      Map.merge(
        %{
          request_id: nil,
          repository: "aroakpm-svg/symphony",
          pull_request_number: 25,
          evaluated_head_sha: full_sha("a"),
          eligible_finding_set_digest: "finding-set-digest",
          eligible_finding_keys: [{:review_thread, "thread-1"}],
          policy_version: "policy-v1",
          human_summary: "One scoped finding",
          expected_transition: %{head_sha: full_sha("a")},
          request_fingerprint: nil,
          created_at: "2026-08-11T00:00:00Z"
        },
        overrides
      )

    request =
      if Map.has_key?(overrides, :request_id),
        do: request,
        else: Map.put(request, :request_id, canonical_request_id(request))

    if Map.has_key?(overrides, :request_fingerprint),
      do: request,
      else: Map.put(request, :request_fingerprint, canonical_request_fingerprint(request))
  end

  defp canonical_request_id(request) do
    stable_digest({
      :symphony_authorization_request_v1,
      request.repository,
      request.pull_request_number,
      request.evaluated_head_sha,
      request.eligible_finding_set_digest,
      request.eligible_finding_keys,
      request.policy_version
    })
  end

  defp canonical_request_fingerprint(request) do
    request_without_fingerprint = Map.drop(request, [:request_fingerprint, :created_at])

    stable_digest({
      :symphony_authorization_request_fingerprint_v1,
      request_without_fingerprint
    })
  end

  defp stable_digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp approval(overrides \\ %{}) do
    Map.merge(
      %{
        comment_id: "approval-1",
        body: "批准再修一輪",
        actor: %{login: "maintainer", id: "42", type: "User"},
        created_at: "2026-08-11T00:01:00Z"
      },
      overrides
    )
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

  defp with_process(key, value, fun) do
    Process.put(key, value)
    result = fun.()
    Process.delete(key)
    result
  end

  defp effect_scope do
    %{
      connection: nil,
      claim_context: %{
        issue_id: "issue-25",
        claim_id: "claim-25",
        generation: 1,
        node_id: "node-25",
        node_instance_id: "node-instance-25",
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
