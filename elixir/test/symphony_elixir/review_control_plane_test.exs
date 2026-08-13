defmodule SymphonyElixir.ReviewControlPlaneTest do
  use ExUnit.Case

  alias SymphonyElixir.ReviewControlPlane
  alias SymphonyElixir.ReviewTarget

  defmodule ReviewClient do
    @spec snapshot_target(ReviewTarget.t()) :: {:ok, map()} | {:error, term()}
    def snapshot_target(target) do
      case Application.get_env(:symphony_elixir, :control_plane_snapshot_error) do
        {:error, _reason} = error ->
          error

        nil ->
          snapshots = Application.fetch_env!(:symphony_elixir, :control_plane_snapshots)
          {:ok, Map.fetch!(snapshots, ReviewTarget.key(target))}
      end
    end

    @spec publish_status(String.t(), String.t(), atom(), String.t(), String.t() | nil) :: :ok
    def publish_status(repository, head_sha, state, description, _target_url) do
      send(
        Application.fetch_env!(:symphony_elixir, :control_plane_recipient),
        {:status, repository, head_sha, state, description}
      )

      :ok
    end

    @spec review_request_exists_for_target?(ReviewTarget.t(), String.t()) :: {:ok, boolean()}
    def review_request_exists_for_target?(_target, _key), do: {:ok, false}

    @spec request_review_for_target(ReviewTarget.t(), String.t()) :: :ok
    def request_review_for_target(target, key) do
      send(
        Application.fetch_env!(:symphony_elixir, :control_plane_recipient),
        {:request, target.repository, target.pull_request_number, target.head_sha, key}
      )

      :ok
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :control_plane_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :control_plane_recipient)
      Application.delete_env(:symphony_elixir, :control_plane_snapshots)
      Application.delete_env(:symphony_elixir, :control_plane_snapshot_error)
    end)
  end

  test "publishes each target status to its own repository and immutable head" do
    symphony_target = target("aroakpm-svg/symphony", 25, "a")
    central_brain_target = target("aroakpm-svg/aroak-central-brain", 25, "b")

    Application.put_env(
      :symphony_elixir,
      :control_plane_snapshots,
      %{
        ReviewTarget.key(symphony_target) => converged_snapshot(symphony_target),
        ReviewTarget.key(central_brain_target) => converged_snapshot(central_brain_target)
      }
    )

    assert {:ok, state, outcomes} =
             ReviewControlPlane.run(
               [symphony_target, central_brain_target],
               %{},
               ReviewClient,
               3
             )

    assert length(outcomes) == 2
    assert Map.has_key?(state, ReviewTarget.key(symphony_target))
    assert Map.has_key?(state, ReviewTarget.key(central_brain_target))
    assert_receive {:status, "aroakpm-svg/symphony", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", :success, _}
    assert_receive {:status, "aroakpm-svg/aroak-central-brain", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", :success, _}
  end

  test "target-scoped history and dedup state do not collide across repositories" do
    first = target("aroakpm-svg/symphony", 25, "a")
    second = target("aroakpm-svg/aroak-central-brain", 25, "a")

    Application.put_env(
      :symphony_elixir,
      :control_plane_snapshots,
      %{
        ReviewTarget.key(first) => converged_snapshot(first),
        ReviewTarget.key(second) => converged_snapshot(second)
      }
    )

    assert {:ok, state, _outcomes} = ReviewControlPlane.run([first, second], %{}, ReviewClient, 3)

    assert Map.keys(state) |> Enum.sort() == Enum.sort([ReviewTarget.key(first), ReviewTarget.key(second)])
    assert state[ReviewTarget.key(first)].target_identity.repository == "aroakpm-svg/symphony"
    assert state[ReviewTarget.key(second)].target_identity.repository == "aroakpm-svg/aroak-central-brain"
    refute state[ReviewTarget.key(first)].history == state[ReviewTarget.key(second)].history
  end

  test "a snapshot for another head is blocked without publishing a status" do
    target = target("aroakpm-svg/symphony", 25, "a")
    mismatched_snapshot = %{converged_snapshot(target) | current_head_sha: String.duplicate("b", 40)}

    Application.put_env(:symphony_elixir, :control_plane_snapshots, %{ReviewTarget.key(target) => mismatched_snapshot})

    assert {:ok, state, [outcome]} = ReviewControlPlane.run([target], %{}, ReviewClient, 3)
    assert outcome.status == :blocked
    assert outcome.reason == :target_identity_mismatch
    assert state[ReviewTarget.key(target)].last_status == :blocked
    refute_received {:status, _, _, _, _}
  end

  test "review request deduplication is scoped to the immutable target" do
    target = target("aroakpm-svg/symphony", 25, "a")

    pending_snapshot =
      converged_snapshot(target)
      |> Map.put(:reviewed_head_sha, nil)
      |> Map.put(:review_result, :missing)

    Application.put_env(:symphony_elixir, :control_plane_snapshots, %{ReviewTarget.key(target) => pending_snapshot})

    assert {:ok, state, [%{status: :pending}]} = ReviewControlPlane.run([target], %{}, ReviewClient, 3)
    assert_receive {:request, "aroakpm-svg/symphony", 25, head_sha, request_key}
    assert head_sha == target.head_sha
    assert request_key == ReviewTarget.dedup_key(target, :review_request, :codex)

    assert {:ok, _state, [%{status: :pending}]} = ReviewControlPlane.run([target], state, ReviewClient, 3)
    refute_receive {:request, _, _, _, _}
  end

  test "publishes an error on the last head when later evidence becomes unavailable" do
    target = target("aroakpm-svg/symphony", 25, "a")

    Application.put_env(
      :symphony_elixir,
      :control_plane_snapshots,
      %{ReviewTarget.key(target) => converged_snapshot(target)}
    )

    assert {:ok, state, [%{status: :success}]} = ReviewControlPlane.run([target], %{}, ReviewClient, 3)
    assert_receive {:status, "aroakpm-svg/symphony", head_sha, :success, _}
    assert head_sha == target.head_sha

    Application.put_env(:symphony_elixir, :control_plane_snapshot_error, {:error, :github_unavailable})

    assert {:ok, _blocked_state, [%{status: :error, reason: :external_evidence_unavailable}]} =
             ReviewControlPlane.run([target], state, ReviewClient, 3)

    assert_receive {:status, "aroakpm-svg/symphony", ^head_sha, :error, description}
    assert description =~ "evidence"
  end

  test "does not overwrite a prior status on an identity mismatch" do
    target = target("aroakpm-svg/symphony", 25, "a")

    Application.put_env(
      :symphony_elixir,
      :control_plane_snapshots,
      %{ReviewTarget.key(target) => converged_snapshot(target)}
    )

    assert {:ok, state, [%{status: :success}]} = ReviewControlPlane.run([target], %{}, ReviewClient, 3)
    head_sha = target.head_sha
    assert_receive {:status, "aroakpm-svg/symphony", ^head_sha, :success, _}

    mismatched_snapshot = %{converged_snapshot(target) | current_head_sha: String.duplicate("b", 40)}

    Application.put_env(
      :symphony_elixir,
      :control_plane_snapshots,
      %{ReviewTarget.key(target) => mismatched_snapshot}
    )

    assert {:ok, _blocked_state, [%{status: :blocked, reason: :target_identity_mismatch}]} =
             ReviewControlPlane.run([target], state, ReviewClient, 3)

    refute_receive {:status, "aroakpm-svg/symphony", _, _, _}
  end

  test "malformed persisted state is blocked without publishing a status" do
    target = target("aroakpm-svg/symphony", 25, "a")

    Application.put_env(
      :symphony_elixir,
      :control_plane_snapshots,
      %{ReviewTarget.key(target) => converged_snapshot(target)}
    )

    malformed_state = %{ReviewTarget.key(target) => %{target_identity: ReviewTarget.identity(target)}}

    assert {:ok, state, [outcome]} = ReviewControlPlane.run([target], malformed_state, ReviewClient, 3)
    assert outcome.status == :error
    assert outcome.reason == :external_evidence_unavailable
    assert state[ReviewTarget.key(target)].last_status == :blocked
    refute_received {:status, _, _, _, _}
  end

  defp target(repository, number, letter) do
    {:ok, target} =
      ReviewTarget.new(%{
        repository: repository,
        pull_request_number: number,
        head_sha: String.duplicate(letter, 40)
      })

    target
  end

  defp converged_snapshot(target) do
    %{
      repository: target.repository,
      pull_request_number: target.pull_request_number,
      current_head_sha: target.head_sha,
      reviewed_head_sha: target.head_sha,
      review_result: :no_major_issues,
      base_ref_oid: String.duplicate("c", 40),
      base_verification_required: true,
      base_verification: :verified,
      required_checks: [%{state: :success}],
      threads: [],
      finding_summary: %{decisions: [], requires_lifecycle?: false},
      structural_risk: false
    }
  end
end
