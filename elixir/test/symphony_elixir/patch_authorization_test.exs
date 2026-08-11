defmodule SymphonyElixir.PatchAuthorizationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PatchAuthorization

  defmodule Design2Contract do
    def finding_set_digest(_finding_keys), do: {:ok, "finding-set-digest"}
  end

  defmodule ProjectionDesign2Contract do
    def finding_set_digest(finding_keys) when length(finding_keys) > 1,
      do: {:ok, "finding-set-digest-2"}

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

      transition_head = Process.get(:managed_transition_head, context.evaluated_head_sha)

      {:ok,
       %{
         opaque: {:managed_publish, context.slot, context.finding_keys},
         expected_transition: %{head_sha: transition_head}
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

  defmodule ManagedRequestProvenancePolicy do
    def verify_managed_request(%{authorization_request_author: %{id: "integration-1"}}),
      do: :verified

    def verify_managed_request(_request), do: :unverified
  end

  defmodule NativeHeadReader do
    def current_head(repository, pull_request_number) do
      send(self(), {:native_head_read, repository, pull_request_number})
      {:ok, Process.get(:native_reader_head, String.duplicate("a", 40))}
    end
  end

  defmodule InvalidNativeHeadReader do
    def current_head(_repository, _pull_request_number), do: {:ok, :invalid}
  end

  defmodule MissingNativeHeadReader do
  end

  defmodule TrustedManagedRequestProvenancePolicy do
    def verify_managed_request(_request), do: :verified
  end

  defmodule UnknownManagedRequestProvenancePolicy do
    def verify_managed_request(_request), do: :unknown
  end

  defmodule UnknownAuthorityPolicy do
    def version, do: :unknown

    def authorize_human_actor(_evidence), do: :unknown
  end

  defmodule ApprovalEffectLedger do
    def execute(_connection, :github_comment, context, adapter, reconciler) do
      send(self(), {:github_request_effect, context})

      case reconciler.() do
        :not_found -> consume_adapter(adapter.())
        {:unknown, reason} -> {:error, {:reconciliation_unknown, reason}}
        {:found, resource} -> {:ok, resource}
        result -> {:error, {:invalid_reconciliation_result, result}}
      end
    end

    defp consume_adapter({:ok, resource}), do: {:ok, resource}
    defp consume_adapter({:error, :no_effect, reason}), do: {:error, {:failed_no_effect, reason}}
    defp consume_adapter({:error, :unknown, reason}), do: {:error, {:effect_unknown, reason}}
    defp consume_adapter(other), do: {:error, {:invalid_adapter_result, other}}
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
        :not_candidate -> {:error, :not_candidate}
        :not_candidate_tuple -> {:error, {:not_candidate, :not_eligible}}
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
    def execute(_connection, :github_comment, _context, adapter, reconciler) do
      case Process.get(:effect_mode, :ok) do
        :ok ->
          consume_adapter(adapter.())

        :reconcile ->
          reconcile(reconciler, adapter)

        :operation_conflict ->
          {:error, :operation_fingerprint_conflict}

        :operation_conflict_tuple ->
          {:error, {:operation_fingerprint_conflict, :details}}

        :error ->
          {:error, :effect_error}

        :other ->
          :invalid

        :raise ->
          raise("effect unavailable")
      end
    end

    defp reconcile(reconciler, adapter) do
      case reconciler.() do
        :not_found -> consume_adapter(adapter.())
        {:unknown, reason} -> {:error, {:reconciliation_unknown, reason}}
        {:found, resource} -> {:ok, resource}
        result -> {:error, {:invalid_reconciliation_result, result}}
      end
    end

    defp consume_adapter({:ok, resource}), do: {:ok, resource}
    defp consume_adapter({:error, :no_effect, reason}), do: {:error, {:failed_no_effect, reason}}
    defp consume_adapter({:error, :unknown, reason}), do: {:error, {:effect_unknown, reason}}
    defp consume_adapter(other), do: {:error, {:invalid_adapter_result, other}}
  end

  defmodule EdgeGitHubClient do
    def create_authorization_request(_repository, _pull_request_number, _request) do
      case Process.get(:github_create_mode, :ok) do
        :ok -> {:ok, %{comment_id: "request-comment-1"}}
        :error -> {:error, :github_create_error}
        :no_effect -> {:error, :no_effect, :github_no_effect}
        :unknown -> {:error, :unknown, :github_unknown}
        :invalid -> :invalid
      end
    end

    def find_authorization_request(_repository, _pull_request_number, _request) do
      case Process.get(:github_find_mode, :not_found) do
        :not_found -> :not_found
        :found -> {:found, %{comment_id: "request-comment-1"}}
        :unknown -> {:unknown, :github_unknown}
        :error -> {:error, :github_find_error}
        :invalid -> :invalid
      end
    end
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
  test "missing human summary fails closed before building an authorization request" do
    assert {:blocked, :invalid_human_summary} =
             PatchAuthorization.authorize(
               Map.delete(input(), :human_summary),
               [],
               evidence(),
               effect_scope(),
               dependencies()
             )
  end

  @tag :contract
  test "malformed active request and missing provenance verifier fail closed" do
    assert {:blocked, :invalid_authorization_request} =
             authorize_with_approval(active_requests: [:malformed])

    assert {:blocked, :authorization_request_provenance_unavailable} =
             authorize_with_approval(managed_request_provenance: nil)

    assert {:blocked, :authorization_request_provenance_unavailable} =
             authorize_with_approval(managed_request_provenance: "not-a-policy")

    assert {:blocked, :authorization_request_provenance_unavailable} =
             authorize_with_approval(managed_request_provenance: UnknownManagedRequestProvenancePolicy)
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
             with_process(:design2_correction_mode, :not_candidate, fn ->
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
               evidence: evidence(%{native: %{current_head_sha: full_sha("a")}}),
               eligible_findings: [correction_finding()]
             )

    assert {:blocked, :managed_publish_native_conflict} =
             authorize_with_projection(ledger_entries: [{:conflict, :managed_publish_native_conflict}])
  end

  @tag :projection
  test "human history may follow an absent correction slot" do
    assert {:authorization_required, _request} =
             authorize_with_approval(
               ledger_entries: [
                 managed_entry(:automatic_initial_v1, :consumed),
                 managed_entry({:human, "request-1", "comment-1", "actor-1"}, :consumed)
               ],
               active_requests: []
             )
  end

  @tag :projection
  test "human history with unresolved correction evidence blocks as a transition conflict" do
    assert {:blocked, :design3_slot_transition_conflict} =
             authorize_with_approval(
               ledger_entries: [
                 managed_entry(:automatic_initial_v1, :consumed),
                 managed_entry(:automatic_correction_v1, :blocked_conflict),
                 managed_entry({:human, "request-1", "comment-1", "actor-1"}, :consumed)
               ],
               active_requests: []
             )
  end

  @tag :projection
  test "automatic grants fail closed when the native head has advanced" do
    assert {:blocked, :authorization_request_stale} =
             authorize_with_projection(evidence: evidence(%{native: %{current_head_sha: full_sha("b")}}))

    assert {:blocked, :authorization_request_stale} =
             authorize_with_projection(
               ledger_entries: [succeeded_initial_entry()],
               evidence: evidence(%{native: %{current_head_sha: full_sha("b")}}),
               eligible_findings: [correction_finding()]
             )
  end

  @tag :projection
  test "automatic grant refreshes native head evidence at the grant boundary" do
    assert {:blocked, :authorization_request_stale} =
             with_process(:native_reader_head, full_sha("b"), fn ->
               authorize_with_projection(evidence: evidence(%{native: %{current_head_sha: full_sha("a")}}))
             end)

    assert_received {:native_head_read, "aroakpm-svg/symphony", 25}
  end

  @tag :projection
  test "missing or malformed native head reader blocks the grant boundary" do
    for reader <- [InvalidNativeHeadReader, MissingNativeHeadReader, "not-a-reader"] do
      assert {:blocked, :authorization_current_head_unavailable} =
               PatchAuthorization.authorize(
                 input(),
                 [],
                 evidence(),
                 effect_scope(),
                 dependencies(design2: ProjectionDesign2Contract, native_head_reader: reader)
               )
    end
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
  test "projection rejects correction history without its initial predecessor" do
    assert {:blocked, :design3_slot_transition_conflict} =
             edge_authorize(ledger_entries: [{:managed, :automatic_correction_v1, :consumed, %{}}])

    assert {:blocked, :design3_slot_transition_conflict} =
             edge_authorize(
               ledger_entries: [
                 {:managed, {:human, "request-1", "comment-1", "actor-1"}, :consumed, %{}}
               ]
             )
  end

  @tag :projection
  test "two human slots cannot reuse one approval comment ID" do
    assert {:blocked, :duplicate_managed_slot} =
             edge_authorize(
               ledger_entries: [
                 {:managed, :automatic_initial_v1, :consumed, %{}},
                 {:managed, :automatic_correction_v1, :consumed, %{}},
                 {:managed, {:human, "request-1", "comment-1", "actor-1"}, :consumed, %{}},
                 {:managed, {:human, "request-2", "comment-1", "actor-2"}, :consumed, %{}}
               ]
             )
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

    assert {:authorization_required, _request} =
             with_process(:design2_correction_mode, :not_candidate_tuple, fn ->
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

  @tag :projection
  test "correction verifier operational failure does not escalate to human authorization" do
    assert {:blocked, {:design2_correction_verification_failed, :not_verified}} =
             with_process(:design2_correction_mode, :not_verified, fn ->
               edge_authorize(
                 ledger_entries: [{:managed, :automatic_initial_v1, :consumed, %{}}],
                 eligible_findings: [correction_finding()]
               )
             end)
  end

  @tag :approval
  test "only the fixed command after outer whitespace is accepted" do
    assert {:ok, %{slot: {:human, _, "approval-1", "42"}}} =
             authorize_with_approval(approval: approval(%{body: "  批准再修一輪  "}))

    assert {:blocked, :invalid_authorization_command} =
             authorize_with_approval(approval: approval(%{body: "可以，繼續修"}))
  end

  @tag :approval
  test "human grant transition must match the request transition" do
    assert {:blocked, :authorization_transition_mismatch} =
             with_process(:managed_transition_head, full_sha("b"), fn ->
               authorize_with_approval(%{})
             end)
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
    reconciliation_provenance_error =
      {:authorization_request_effect_failed, {:reconciliation_unknown, :authorization_request_provenance_unverified}}

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

    assert {:blocked, {:authorization_request_effect_failed, {:effect_unknown, :github_create_error}}} =
             with_process(:github_create_mode, :error, fn ->
               authorize_with_approval(
                 active_requests: [],
                 effect_ledger: EdgeEffectLedger,
                 github: EdgeGitHubClient
               )
             end)

    assert {:blocked, {:authorization_request_effect_failed, {:reconciliation_unknown, :github_find_error}}} =
             with_process(:github_find_mode, :error, fn ->
               with_process(:effect_mode, :reconcile, fn ->
                 authorize_with_approval(
                   active_requests: [],
                   approval: nil,
                   effect_ledger: EdgeEffectLedger,
                   github: EdgeGitHubClient
                 )
               end)
             end)

    for {mode, expected} <- [
          {:no_effect, {:failed_no_effect, :github_no_effect}},
          {:unknown, {:effect_unknown, :github_unknown}},
          {:invalid, {:effect_unknown, {:invalid_adapter_result, :invalid}}}
        ] do
      assert {:blocked, {:authorization_request_effect_failed, ^expected}} =
               with_process(:github_create_mode, mode, fn ->
                 authorize_with_approval(
                   active_requests: [],
                   approval: nil,
                   effect_ledger: EdgeEffectLedger,
                   github: EdgeGitHubClient
                 )
               end)
    end

    assert {:blocked, ^reconciliation_provenance_error} =
             with_process(:github_find_mode, :found, fn ->
               with_process(:effect_mode, :reconcile, fn ->
                 authorize_with_approval(
                   active_requests: [],
                   approval: nil,
                   effect_ledger: EdgeEffectLedger,
                   github: EdgeGitHubClient
                 )
               end)
             end)

    for {mode, expected} <- [
          {:unknown, {:reconciliation_unknown, :github_unknown}},
          {:invalid, {:reconciliation_unknown, {:invalid_reconciler_result, :invalid}}}
        ] do
      assert {:blocked, {:authorization_request_effect_failed, ^expected}} =
               with_process(:github_find_mode, mode, fn ->
                 with_process(:effect_mode, :reconcile, fn ->
                   authorize_with_approval(
                     active_requests: [],
                     approval: nil,
                     effect_ledger: EdgeEffectLedger,
                     github: EdgeGitHubClient
                   )
                 end)
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

    assert {:error, :invalid_authorization_approval} =
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

    assert {:error, :authorization_request_provenance_unavailable} =
             human_authorization_for_test(
               active_request: request(%{created_at: nil}),
               approval: approval()
             )

    assert {:error, :authorization_request_provenance_unavailable} =
             human_authorization_for_test(
               active_request: request(%{created_at: "not-a-timestamp"}),
               approval: approval()
             )

    assert {:error, :authorization_request_provenance_unavailable} =
             human_authorization_for_test(
               active_request: Map.delete(request(), :created_at),
               approval: approval()
             )

    assert {:ok, %{slot: {:human, _, "approval-1", "42"}}} =
             human_authorization_for_test(
               active_request:
                 request(%{
                   authorization_request_created_at: "2026-08-11T00:00:00Z"
                 }),
               approval: approval(%{created_at: "2026-08-11T00:01:00Z"})
             )
  end

  @tag :approval
  test "human request binding rejects digest, identity, and dependency drift" do
    assert {:authorization_required, replacement} =
             authorize_with_approval(
               active_request: request(%{eligible_finding_set_digest: "different-digest"}),
               approval: nil
             )

    assert replacement.eligible_finding_set_digest == "finding-set-digest"

    assert {:blocked, :authorization_evidence_unavailable} =
             authorize_with_approval(active_request: request(), evidence_overrides: %{comments: nil})

    assert {:blocked, :authorization_effect_unavailable} =
             authorize_with_approval(
               active_requests: [],
               dependencies: %{
                 design2: ProjectionDesign2Contract,
                 authority_policy: AuthorityPolicy,
                 native_head_reader: NativeHeadReader
               }
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
  test "managed request provenance must be verified before approval binding" do
    assert {:blocked, :authorization_request_provenance_unverified} =
             authorize_with_approval(
               active_request:
                 request(%{
                   authorization_request_author: %{login: "attacker", id: "attacker-1", type: "User"}
                 })
             )
  end

  @tag :approval
  test "native head is rechecked before binding a human approval" do
    assert {:blocked, :authorization_request_stale} =
             authorize_with_approval(
               active_request: request(),
               current_head_sha: full_sha("b")
             )
  end

  @tag :approval
  test "human grant refreshes native head evidence at the grant boundary" do
    assert {:blocked, :authorization_request_stale} =
             with_process(:native_reader_head, full_sha("b"), fn ->
               authorize_with_approval(active_request: request())
             end)

    assert_received {:native_head_read, "aroakpm-svg/symphony", 25}
  end

  @tag :approval
  test "approval must be newer than the managed request and skip used approvals" do
    assert {:blocked, :authorization_approval_pending} =
             authorize_with_approval(
               active_request: request(%{created_at: "2026-08-11T00:02:00Z"}),
               approval: approval(%{created_at: "2026-08-11T00:01:00Z"})
             )

    assert {:ok, %{slot: {:human, _, "approval-2", "42"}}} =
             authorize_with_approval(
               approvals: [
                 approval(%{comment_id: "approval-1", created_at: "2026-08-11T00:01:00Z"}),
                 approval(%{comment_id: "approval-2", created_at: "2026-08-11T00:00:02Z"})
               ],
               used_approval_comment_ids: MapSet.new(["approval-1"]),
               active_request: request(%{created_at: "2026-08-11T00:00:00Z"})
             )
  end

  @tag :approval
  test "ineligible approval is skipped so a later eligible approval can bind" do
    assert {:ok, %{slot: {:human, _, "approval-2", "42"}}} =
             authorize_with_approval(
               approvals: [
                 approval(%{comment_id: "approval-unauthorized", actor: %{login: "other", id: "99", type: "User"}}),
                 approval(%{comment_id: "approval-2"})
               ],
               active_request: request()
             )
  end

  @tag :approval
  test "unverified reconciled request is not recorded as a successful effect" do
    reconciliation_provenance_error =
      {:authorization_request_effect_failed, {:reconciliation_unknown, :authorization_request_provenance_unverified}}

    assert {:blocked, ^reconciliation_provenance_error} =
             with_process(:effect_mode, :reconcile, fn ->
               with_process(:github_find_mode, :found, fn ->
                 authorize_with_approval(
                   active_requests: [],
                   approval: nil,
                   effect_ledger: EdgeEffectLedger,
                   github: EdgeGitHubClient
                 )
               end)
             end)
  end

  @tag :approval
  test "verified reconciled request remains a successful existing effect" do
    assert {:authorization_required, _request} =
             with_process(:effect_mode, :reconcile, fn ->
               with_process(:github_find_mode, :found, fn ->
                 authorize_with_approval(
                   active_requests: [],
                   approval: nil,
                   managed_request_provenance: TrustedManagedRequestProvenancePolicy,
                   effect_ledger: EdgeEffectLedger,
                   github: EdgeGitHubClient
                 )
               end)
             end)
  end

  @tag :approval
  test "a stale canonical request is retired so the current snapshot gets a replacement" do
    stale_request =
      request(%{
        evaluated_head_sha: full_sha("b"),
        expected_transition: %{head_sha: full_sha("b")}
      })

    assert {:authorization_required, replacement} =
             authorize_with_approval(
               active_request: stale_request,
               active_requests: [stale_request],
               approval: nil
             )

    assert replacement.evaluated_head_sha == full_sha("a")
    refute replacement.request_id == stale_request.request_id
  end

  @tag :approval
  test "missing authority policy key blocks without raising" do
    dependencies_without_policy =
      dependencies(
        design2: ProjectionDesign2Contract,
        authority_policy: AuthorityPolicy,
        effect_ledger: ApprovalEffectLedger,
        github: ApprovalGitHubClient
      )
      |> Map.delete(:authority_policy)

    assert {:blocked, :authorization_policy_unavailable} =
             authorize_with_approval(
               active_requests: [],
               dependencies: dependencies_without_policy
             )
  end

  @tag :approval
  test "finding key order does not change canonical request identity" do
    assert {:authorization_required, first} =
             authorize_with_approval(
               active_requests: [],
               approval: nil,
               eligible_findings: [finding(), extra_finding()]
             )

    assert {:authorization_required, second} =
             authorize_with_approval(
               active_requests: [],
               approval: nil,
               eligible_findings: [extra_finding(), finding()]
             )

    assert first.request_id == second.request_id
    assert first.request_fingerprint == second.request_fingerprint
  end

  @tag :approval
  test "unknown policy blocks human approval without transferring authority" do
    assert {:blocked, :authorization_policy_unavailable} =
             authorize_with_approval(authority_policy: UnknownAuthorityPolicy)

    refute_received {:managed_identity_requested, {:human, _}}
  end

  @tag :approval
  test "changed head or FindingKey set cannot inherit approval" do
    assert {:authorization_required, replacement} =
             authorize_with_approval(
               active_request: request(%{evaluated_head_sha: full_sha("b")}),
               current_head_sha: full_sha("a")
             )

    assert replacement.evaluated_head_sha == full_sha("a")

    assert {:authorization_required, replacement} =
             authorize_with_approval(extra_finding: true, approval: nil)

    assert length(replacement.eligible_finding_keys) == 2
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
             authorize_with_approval(active_requests: [request(), request()])
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

    eligible_findings =
      Map.get(
        overrides,
        :eligible_findings,
        if(Map.get(overrides, :extra_finding, false), do: [finding(), extra_finding()], else: [finding()])
      )

    comments = Map.get(overrides, :approvals, [Map.get(overrides, :approval, approval())])

    approval_evidence =
      Map.merge(
        evidence(%{
          native: %{current_head_sha: current_head_sha},
          comments: comments,
          active_requests: Map.get(overrides, :active_requests, [active_request]),
          used_approval_comment_ids: Map.get(overrides, :used_approval_comment_ids, MapSet.new())
        }),
        Map.get(overrides, :evidence_overrides, %{})
      )

    dependency_defaults =
      dependencies(
        design2: Map.get(overrides, :design2, ProjectionDesign2Contract),
        authority_policy: Map.get(overrides, :authority_policy, AuthorityPolicy),
        managed_request_provenance: Map.get(overrides, :managed_request_provenance, ManagedRequestProvenancePolicy),
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
          authorization_request_author: %{login: "symphony-integration", id: "integration-1", type: "Bot"},
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
      request.policy_version
    })
  end

  defp canonical_request_fingerprint(request) do
    request_without_fingerprint =
      Map.drop(request, [
        :request_fingerprint,
        :created_at,
        :eligible_finding_keys,
        :authorization_request_author,
        :authorization_request_comment_id,
        :authorization_request_created_at
      ])

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
        managed_request_provenance: ManagedRequestProvenancePolicy,
        native_head_reader: NativeHeadReader,
        effect_ledger: nil,
        github: nil
      },
      Map.new(overrides)
    )
  end
end
