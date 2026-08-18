defmodule SymphonyElixir.ReviewMonitorMergeReadyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewMonitor
  alias SymphonyElixir.Linear.Issue

  defmodule EvidenceProvider do
    def read(_issue, _landing, _settings, _deps) do
      count = Process.get(:merge_ready_reads, 0) + 1
      Process.put(:merge_ready_reads, count)
      send(Process.get(:merge_ready_owner), {:evidence_read, count})
      {:ok, %{proof: :complete}, %{head: Process.get(:merge_ready_head, "head-1")}}
    end
  end

  defmodule Candidate do
    def derive(%{proof: :complete}, %{head: head}, landing_mode: :human) do
      send(Process.get(:merge_ready_owner), :candidate_derived)
      {:ok, %{candidate_schema_version: 1, head: head}}
    end

    def matches_live_snapshot?(candidate, snapshot), do: candidate.head == snapshot.head
  end

  defmodule DriftingProvider do
    def read(issue, landing, settings, deps) do
      result =
        SymphonyElixir.ReviewMonitorMergeReadyTest.EvidenceProvider.read(
          issue,
          landing,
          settings,
          deps
        )

      case Process.get(:merge_ready_reads) do
        1 -> result
        2 -> {:ok, %{proof: :complete}, %{head: "head-2"}}
      end
    end
  end

  setup do
    Process.put(:merge_ready_owner, self())
    Process.put(:merge_ready_reads, 0)
    Process.put(:merge_ready_head, "head-1")
    :ok
  end

  test "publishes a human candidate only after two matching native reads" do
    assert {:ok, result} =
             ReviewMonitor.derive_merge_ready_for_test(
               %{terminal_result: nil},
               issue(),
               %{settlement: :complete},
               settings(),
               options()
             )

    assert {:merge_ready_candidate, %{head: "head-1"}} = result.terminal_result
    assert_receive {:evidence_read, 1}
    assert_receive :candidate_derived
    assert_receive {:evidence_read, 2}
    refute_received {:merge, _pull_request}
    refute_received {:linear_done, _issue}
  end

  test "fails closed when the final native snapshot changes" do
    assert {:ok, result} =
             ReviewMonitor.derive_merge_ready_for_test(
               %{terminal_result: nil},
               issue(),
               %{settlement: :complete},
               settings(),
               Map.put(options(), :merge_ready_evidence, DriftingProvider)
             )

    assert {:merge_ready_blocked, [%{code: :live_snapshot_changed}]} = result.terminal_result
  end

  defp options do
    %{
      merge_ready_evidence: EvidenceProvider,
      merge_ready_candidate: Candidate,
      landing_mode: :human,
      review_client: :unused,
      tracker: :unused,
      now: fn -> ~U[2026-08-18 00:00:00Z] end
    }
  end

  defp settings do
    %{repository: "aroakpm-svg/symphony", review_state: "In Review", in_progress_state: "In Progress"}
  end

  defp issue do
    %Issue{id: "issue-246", identifier: "ARO-246", branch_name: "agent/aro-246"}
  end
end
