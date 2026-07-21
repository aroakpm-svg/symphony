defmodule SymphonyElixir.ReviewConvergenceTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubReviewClient
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ReviewConvergence
  alias SymphonyElixir.ReviewMonitor

  defmodule ReviewClient do
    @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
    def snapshot(_repository, _branch), do: Application.fetch_env!(:symphony_elixir, :review_snapshot)

    @spec request_review(String.t(), pos_integer()) :: :ok
    def request_review(repository, number) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:review_requested, repository, number})
      :ok
    end

    @spec publish_status(String.t(), String.t(), atom(), String.t(), String.t() | nil) :: :ok
    def publish_status(repository, head_sha, state, description, _target_url) do
      send(
        Application.fetch_env!(:symphony_elixir, :review_recipient),
        {:status, repository, head_sha, state, description}
      )

      :ok
    end
  end

  defmodule Tracker do
    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(_states), do: {:ok, Application.fetch_env!(:symphony_elixir, :review_issues)}

    @spec create_comment(String.t(), String.t()) :: :ok
    def create_comment(issue_id, body) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:comment, issue_id, body})
      :ok
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok
    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:state, issue_id, state})
      :ok
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :review_recipient, self())
    Application.put_env(:symphony_elixir, :review_issues, [issue()])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :review_recipient)
      Application.delete_env(:symphony_elixir, :review_issues)
      Application.delete_env(:symphony_elixir, :review_snapshot)
    end)
  end

  test "review convergence config is disabled by default and fail-closed when enabled without a repository" do
    assert {:ok, config} = Schema.parse(%{})
    refute config.review_convergence.enabled

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"review_convergence" => %{"enabled" => true}})

    assert message =~ "review_convergence.repository"
  end

  test "GitHub's no-checks CLI variants normalize to an empty prerequisite set" do
    assert {:ok, []} = GitHubReviewClient.normalize_no_required_checks_for_test("no checks reported on the branch")

    assert {:ok, []} =
             GitHubReviewClient.normalize_no_required_checks_for_test("no required checks reported on the branch")

    assert {:error, {:command_failed, 1, "authentication failed"}} =
             GitHubReviewClient.normalize_no_required_checks_for_test("authentication failed")
  end

  test "a new head invalidates an old formal review and requests one deduplicated review" do
    snapshot = snapshot(%{current_head_sha: "new", reviewed_head_sha: "old"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, "aroakpm-svg/repo", "new", :pending, _}
    assert_receive {:review_requested, "aroakpm-svg/repo", 42}

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:review_requested, _, _}
  end

  test "review, required checks, and actionable threads are independent gates" do
    assert {:converged, _} = ReviewConvergence.evaluate(snapshot(), 0, 3)

    assert {:request_review, _} =
             snapshot(%{reviewed_head_sha: "old"}) |> ReviewConvergence.evaluate(0, 3)

    assert {:wait, %{reason: :required_checks_not_passed}} =
             snapshot(%{required_checks: [%{name: "test", state: :pending}]})
             |> ReviewConvergence.evaluate(0, 3)

    assert {:rework, %{actionable_threads: [_]}} =
             snapshot(%{threads: [%{resolved: false, priority: 2, body: "P2", url: "url"}]})
             |> ReviewConvergence.evaluate(0, 3)
  end

  test "an unverified remote base claim fails closed" do
    result =
      snapshot(%{base_verification_required: true, base_verification: :unverified})
      |> ReviewConvergence.evaluate(0, 3)

    assert {:wait, %{reason: :base_unverified, base_ref_oid: "base"}} = result
  end

  test "actionable findings comment and return the issue for repair once per head and finding" do
    finding = %{resolved: false, priority: 1, body: "P1 data loss", url: "https://example.test/thread"}
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :failure, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "P1"
    assert_receive {:state, "issue-160", "In Progress"}

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
  end

  test "waiting on environment or human judgment neither rereviews nor changes state" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{waiting_reason: :staging, reviewed_head_sha: nil, review_result: :missing})}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :pending, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "waiting for team human judgment"
    refute_receive {:review_requested, _, _}
    refute_receive {:state, _, _}

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:comment, _, _}
  end

  test "persistent actionable findings escalate instead of scheduling another repair" do
    finding = %{resolved: false, priority: 3, body: "P3 recurring patch", url: "thread"}
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 3,
        head_sha: "head",
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :failure, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "review_not_converging"
    refute_receive {:state, _, _}
  end

  defp settings do
    %{
      repository: "aroakpm-svg/repo",
      review_state: "In Review",
      in_progress_state: "In Progress",
      max_fix_rounds: 3,
      human_owner: "owner"
    }
  end

  defp issue do
    %Issue{
      id: "issue-160",
      identifier: "ARO-160",
      title: "Review convergence",
      state: "In Review",
      branch_name: "codex/aro-160",
      url: "https://linear.test/ARO-160"
    }
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        repository: "aroakpm-svg/repo",
        pull_request_number: 42,
        current_head_sha: "head",
        reviewed_head_sha: "head",
        review_result: :no_major_issues,
        base_ref_oid: "base",
        base_verification_required: false,
        base_verification: :not_required,
        required_checks: [%{name: "test", state: :success}],
        threads: [],
        waiting_reason: nil
      },
      overrides
    )
  end
end
