defmodule SymphonyElixir.Design2StateTransitionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Design2HardeningFixtures, as: Fixtures
  alias SymphonyElixir.EffectLedger, as: RealEffectLedger
  alias SymphonyElixir.FindingDisposition
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ReviewMonitor

  defmodule ReviewClient do
    @spec snapshot(String.t(), String.t()) :: {:ok, map()}
    def snapshot(_repository, _branch) do
      {:ok, %{finding_summary: %{decisions: [], requires_lifecycle?: false}}}
    end
  end

  defmodule Tracker do
    @spec fetch_routed_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_routed_issues_by_states(_states), do: {:ok, [issue()]}

    defp issue do
      %Issue{
        id: Fixtures.issue_id(),
        identifier: "ARO-HARDENING",
        title: "Design 2 hardening",
        state: "In Review",
        branch_name: "codex/design2-hardening",
        labels: []
      }
    end
  end

  defmodule ClaimService do
    @spec claim(Issue.t(), pid()) :: {:ok, map()} | {:error, :claim_busy}
    def claim(issue, _owner) do
      mode = Application.fetch_env!(:symphony_elixir, :design2_claim_mode)

      case mode do
        :new -> {:ok, Map.merge(Fixtures.claim_context(2), %{acquisition: :new, issue_id: issue.id})}
        :existing -> {:ok, Map.merge(Fixtures.claim_context(2), %{acquisition: :existing, issue_id: issue.id})}
        :failed -> {:error, :claim_busy}
      end
    end

    @spec bind_worker(String.t(), pid()) :: :ok
    def bind_worker(issue_id, _worker) do
      send(Application.fetch_env!(:symphony_elixir, :design2_recipient), {:claim, :bind_worker, issue_id})
      :ok
    end

    @spec effect_context(String.t()) :: {:ok, term(), map()}
    def effect_context(issue_id) do
      send(Application.fetch_env!(:symphony_elixir, :design2_recipient), {:claim, :effect_context, issue_id})
      {:ok, :connection, Map.put(Fixtures.claim_context(2), :issue_id, issue_id)}
    end

    @spec release(String.t()) :: :ok
    def release(issue_id) do
      send(Application.fetch_env!(:symphony_elixir, :design2_recipient), {:claim, :release, issue_id})
      :ok
    end
  end

  defmodule AutonomousEffectLedger do
    @spec list_operations(term(), map()) :: {:ok, []}
    def list_operations(_connection, _claim_context), do: {:ok, []}
  end

  setup do
    Application.put_env(:symphony_elixir, :design2_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :design2_recipient)
      Application.delete_env(:symphony_elixir, :design2_claim_mode)
    end)
  end

  test "generation N release or expiry followed by reclaim creates N+1" do
    assert [%{from: 1, to: :released}, %{from: :released, to: 2}, %{from: 2, to: :expired}, %{from: :expired, to: 3}] =
             Fixtures.generation_transition()
  end

  test "a valid current claim reads unresolved effects from an older generation" do
    current_claim = Fixtures.claim_context(2)

    connection = fn _sql, _params ->
      rows = [
        Fixtures.effect_row("old-pending", 1, "pending"),
        Fixtures.effect_row("old-unknown", 1, "unknown"),
        Fixtures.effect_row("current-succeeded", 2, "succeeded")
      ]

      {:ok, %Postgrex.Result{rows: rows, num_rows: length(rows)}}
    end

    assert {:ok, operations} = RealEffectLedger.list_operations(connection, current_claim)
    assert Enum.map(operations, & &1.operation_id) == ["old-pending", "old-unknown", "current-succeeded"]
  end

  test "readback authenticates the current claim while mutation remains generation scoped" do
    sql = File.read!(Path.expand("../../priv/symphony_migrations/20260809000000_finding_effect_readback.sql", __DIR__))

    assert sql =~ "claims.generation = requested_generation"
    assert sql =~ "claims.claim_id = requested_claim_id"
    assert sql =~ "operations.issue_id = requested_issue_id"
    assert sql =~ "operations.status in ('pending', 'unknown')"
    refute sql =~ "operations.generation = requested_generation"
  end

  test "monitor does not release an existing worker claim" do
    run_monitor(:existing)

    assert_receive {:claim, :bind_worker, _}
    assert_receive {:claim, :effect_context, _}
    refute_receive {:claim, :release, _}
  end

  test "monitor does not release a claim after a failed acquisition" do
    run_monitor(:failed)

    refute_receive {:claim, :bind_worker, _}
    refute_receive {:claim, :release, _}
  end

  test "monitor releases only a claim newly acquired by this invocation" do
    run_monitor(:new)

    assert_receive {:claim, :release, _}
  end

  test "fingerprint decoding rejects a tampered canonical nested identity" do
    facts = Fixtures.finding_facts()
    {:ok, finding_key} = FindingDisposition.build_finding_key(facts)
    {:ok, lineage_key} = FindingDisposition.build_lineage_key(facts)
    intent = Fixtures.fingerprint_intent(%{finding_key: finding_key, finding_lineage_key: lineage_key})
    fingerprint = encoded_fingerprint(intent)
    tampered = tamper_fingerprint(fingerprint, &put_in(&1, [:finding_key, :digest], String.duplicate("f", 64)))

    assert {:error, _reason} = FindingDisposition.decode_request_fingerprint(tampered)
  end

  test "partial, malformed, or conflicting preflight evidence fails closed" do
    finding = Fixtures.finding_facts()

    for preflight <- [
          %{},
          %{verified?: true},
          %{valid?: true},
          %{verified?: true, valid?: :unknown},
          %{verified?: true, valid?: false},
          %{verified?: true, valid?: true, conflict?: true}
        ] do
      assert {:error, {:global_blocker, _reason}} = FindingDisposition.classify_all([finding], preflight)
    end
  end

  test "decision table covers OR responsibility proof and AND safety gates" do
    table = Fixtures.ownership_decision_table()

    assert Enum.map(table, & &1.case) == [
             :introduced_by_pr_only,
             :invariant_violation_only,
             :no_responsibility_proof,
             :missing_evidence,
             :malformed_evidence,
             :conflicting_evidence
           ]

    assert Enum.all?(Enum.take(table, 2), fn cell ->
             cell.expected == :fix_in_current_pr and
               (cell.introduced_by_pr? or cell.invariant_violation?) and
               cell.safety == :all_explicitly_safe
           end)

    assert Enum.all?(Enum.drop(table, 3), &(&1.expected == :blocked_unverified))
  end

  defp run_monitor(mode) do
    Application.put_env(:symphony_elixir, :design2_claim_mode, mode)

    ReviewMonitor.run_with(
      %{},
      %{repository: "aroakpm-svg/symphony", review_state: "In Review", in_progress_state: "In Progress"},
      ReviewClient,
      Tracker,
      %{profile: :aroak_autonomous_v1, claim_service: ClaimService, effect_ledger: AutonomousEffectLedger}
    )
  end

  defp encoded_fingerprint(intent) do
    {:ok, fingerprint} = FindingDisposition.request_fingerprint(intent)
    fingerprint
  end

  defp tamper_fingerprint("symphony_request_fingerprint_v1:" <> encoded, mutate) do
    {:ok, binary} = Base.url_decode64(encoded, padding: false)
    {:symphony_request_fingerprint_v1, intent} = :erlang.binary_to_term(binary, [:safe])
    tampered = mutate.(intent)
    encoded_tampered = Base.url_encode64(:erlang.term_to_binary({:symphony_request_fingerprint_v1, tampered}, [:deterministic]), padding: false)
    "symphony_request_fingerprint_v1:" <> encoded_tampered
  end
end
