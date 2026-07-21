defmodule SymphonyElixir.ReviewConvergenceTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubReviewClient
  alias SymphonyElixir.Linear.{Adapter, Issue}
  alias SymphonyElixir.ReviewConvergence
  alias SymphonyElixir.ReviewMonitor

  defmodule ReviewClient do
    @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
    def snapshot(_repository, _branch), do: Application.fetch_env!(:symphony_elixir, :review_snapshot)

    @spec request_review(String.t(), pos_integer(), String.t()) :: :ok
    def request_review(repository, number, key) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:review_requested, repository, number, key})
      :ok
    end

    @spec review_request_exists?(String.t(), pos_integer(), String.t()) :: {:ok, boolean()}
    def review_request_exists?(_repository, _number, key) do
      {:ok, key in Application.get_env(:symphony_elixir, :existing_review_keys, [])}
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
    @spec fetch_routed_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_routed_issues_by_states(_states), do: {:ok, Application.fetch_env!(:symphony_elixir, :review_issues)}

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(_states), do: {:ok, Application.fetch_env!(:symphony_elixir, :review_issues)}

    @spec review_history(String.t()) :: {:ok, map()} | {:error, term()}
    def review_history(_issue_id),
      do: Application.get_env(:symphony_elixir, :review_history, {:ok, %{dedup: MapSet.new(), rework_count: 0}})

    @spec create_comment(String.t(), String.t()) :: :ok
    def create_comment(issue_id, body) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:comment, issue_id, body})
      :ok
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:state, issue_id, state})
      Application.get_env(:symphony_elixir, :review_state_result, :ok)
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :review_recipient, self())
    Application.put_env(:symphony_elixir, :review_issues, [issue()])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :review_recipient)
      Application.delete_env(:symphony_elixir, :review_issues)
      Application.delete_env(:symphony_elixir, :review_snapshot)
      Application.delete_env(:symphony_elixir, :existing_review_keys)
      Application.delete_env(:symphony_elixir, :review_history)
      Application.delete_env(:symphony_elixir, :linear_client_module)
      Application.delete_env(:symphony_elixir, :review_state_result)
    end)
  end

  test "review convergence config is disabled by default and fail-closed when enabled without a repository" do
    assert {:ok, config} = Schema.parse(%{})
    refute config.review_convergence.enabled

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"review_convergence" => %{"enabled" => true}})

    assert message =~ "review_convergence.repository"

    assert {:error, {:invalid_workflow_config, malformed_message}} =
             Schema.parse(%{
               "review_convergence" => %{"enabled" => true, "repository" => "symphony"}
             })

    assert malformed_message =~ "must use owner/name format"
  end

  test "missing expected GitHub Actions checks fail closed instead of treating zero rows as passing" do
    assert {:ok, checks} = GitHubReviewClient.normalize_expected_checks_for_test(%{"check_runs" => []})

    assert checks == [
             %{name: "make-all", state: :missing, link: nil},
             %{name: "validate-pr-description", state: :missing, link: nil}
           ]
  end

  test "expected checks require exact job and GitHub Actions app identities" do
    run = fn name, slug, id, conclusion ->
      %{
        "name" => name,
        "status" => "completed",
        "conclusion" => conclusion,
        "details_url" => "url/#{name}",
        "app" => %{"slug" => slug, "id" => id}
      }
    end

    payload = %{
      "check_runs" => [
        run.("make-all", "github-actions", 15_368, "success"),
        run.("validate-pr-description", "impostor", 15_368, "success"),
        run.("validate-pr-description", "github-actions", 15_368, "failure")
      ]
    }

    assert {:ok,
            [
              %{name: "make-all", state: :success},
              %{name: "validate-pr-description", state: :failure}
            ]} = GitHubReviewClient.normalize_expected_checks_for_test(payload)
  end

  test "check-run REST pages are all merged before expected checks are selected" do
    first = %{"check_runs" => [%{"name" => "unrelated"}]}

    second = %{
      "check_runs" => [
        %{
          "name" => "make-all",
          "status" => "completed",
          "conclusion" => "success",
          "app" => %{"slug" => "github-actions", "id" => 15_368}
        },
        %{
          "name" => "validate-pr-description",
          "status" => "completed",
          "conclusion" => "success",
          "app" => %{"slug" => "github-actions", "id" => 15_368}
        }
      ]
    }

    assert {:ok, payload} = GitHubReviewClient.merge_check_run_pages_for_test([first, second])

    assert {:ok, [%{state: :success}, %{state: :success}]} =
             GitHubReviewClient.normalize_expected_checks_for_test(payload)
  end

  test "GitHub skipped conclusion uses the explicitly allowed skipped gate state" do
    run = fn name ->
      %{
        "name" => name,
        "status" => "completed",
        "conclusion" => "skipped",
        "app" => %{"slug" => "github-actions", "id" => 15_368}
      }
    end

    assert {:ok, [%{state: :skipped}, %{state: :skipped}]} =
             GitHubReviewClient.normalize_expected_checks_for_test(%{
               "check_runs" => [run.("make-all"), run.("validate-pr-description")]
             })
  end

  test "formal pass requires the trusted reviewer database identity on the current head" do
    trusted = %{
      "body" => "No major issues found",
      "state" => "COMMENTED",
      "commit" => %{"oid" => "head"},
      "author" => %{
        "login" => "chatgpt-codex-connector",
        "__typename" => "Organization",
        "databaseId" => 261_883_814
      }
    }

    assert GitHubReviewClient.accepted_review_for_test?(trusted, "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(trusted, ["author", "databaseId"], 123), "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(trusted, ["commit", "oid"], "old"), "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "state" => "DISMISSED"}, "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "state" => "PENDING"}, "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "body" => "No major issues found"}, "other")

    bot = %{
      trusted
      | "author" => %{
          "login" => "chatgpt-codex-connector[bot]",
          "__typename" => "Bot",
          "databaseId" => 199_175_422
        }
    }

    assert GitHubReviewClient.accepted_review_for_test?(bot, "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(bot, ["author", "databaseId"], 123), "head")
  end

  test "pending required checks returned with gh exit status 8 remain pending evidence" do
    output = Jason.encode!([%{"name" => "ci", "bucket" => "pending", "state" => "PENDING", "link" => "url"}])

    assert {:ok, [%{name: "ci", state: :pending}]} =
             GitHubReviewClient.normalize_required_checks_for_test(output, 8)
  end

  test "review thread pagination merges every page before evaluation" do
    page = fn body ->
      %{
        "data" => %{
          "repository" => %{
            "pullRequest" => %{
              "reviewThreads" => %{
                "nodes" => [%{"comments" => %{"nodes" => [%{"body" => body}]}}]
              }
            }
          }
        }
      }
    end

    assert {:ok, pull_request} =
             GitHubReviewClient.merge_pull_request_pages_for_test([page.("P4 first"), page.("P1 second")])

    assert Enum.map(
             pull_request["reviewThreads"]["nodes"],
             &get_in(&1, ["comments", "nodes", Access.at(0), "body"])
           ) == ["P4 first", "P1 second"]
  end

  test "pull-request pagination exposes only the outer review-thread cursor" do
    query = GitHubReviewClient.pull_request_query_for_test()

    assert length(Regex.scan(~r/pageInfo \{ hasNextPage endCursor \}/, query)) == 1
    assert query =~ "reviewThreads(first: 100, after: $endCursor)"
    assert query =~ "comments(first: 100)"
  end

  test "only current-head review threads are actionable" do
    thread = fn commit, body ->
      %{
        "isResolved" => false,
        "comments" => %{
          "nodes" => [
            %{"body" => body, "path" => "lib/example.ex", "url" => "url", "commit" => %{"oid" => commit}}
          ]
        }
      }
    end

    assert [%{body: "P2 current", commit_sha: "new"}] =
             GitHubReviewClient.normalize_threads_for_test(
               [thread.("old", "P1 stale"), thread.("new", "P2 current")],
               "new"
             )
  end

  test "a current-head follow-up on an older thread remains actionable" do
    thread = %{
      "isResolved" => false,
      "comments" => %{
        "nodes" => [
          %{"body" => "P4 old", "commit" => %{"oid" => "old"}},
          %{"body" => "P1 current follow-up", "path" => "lib/current.ex", "url" => "thread", "commit" => %{"oid" => "head"}}
        ]
      }
    }

    assert [%{body: "P1 current follow-up", priority: 1, commit_sha: "head"}] =
             GitHubReviewClient.normalize_threads_for_test([thread], "head")
  end

  test "old-head base-missing claims do not contaminate current-head follow-ups" do
    thread = %{
      "comments" => %{
        "nodes" => [
          %{
            "body" => "The base branch is missing `lib/old.ex`",
            "commit" => %{"oid" => "old"}
          },
          %{"body" => "Current-head follow-up", "commit" => %{"oid" => "head"}}
        ]
      }
    }

    assert GitHubReviewClient.base_missing_paths_for_test([thread], "head") == []

    current = put_in(thread, ["comments", "nodes", Access.at(1), "body"], "Base ref is missing `lib/current.ex`")
    assert GitHubReviewClient.base_missing_paths_for_test([current], "head") == ["lib/current.ex"]
  end

  test "structural risk only uses unresolved current-head comments" do
    thread = fn resolved, commit, body ->
      %{
        "isResolved" => resolved,
        "comments" => %{"nodes" => [%{"body" => body, "commit" => %{"oid" => commit}}]}
      }
    end

    refute GitHubReviewClient.structural_risk_for_test?(
             [
               thread.(false, "old", "P2 spec conflict"),
               thread.(true, "head", "P2 scope keeps expanding")
             ],
             "head"
           )

    assert GitHubReviewClient.structural_risk_for_test?(
             [thread.(false, "head", "P2 one-off patch")],
             "head"
           )
  end

  test "review thread comments are merged across every comment page" do
    page = fn body ->
      %{"data" => %{"node" => %{"comments" => %{"nodes" => [%{"body" => body}]}}}}
    end

    assert {:ok, [%{"body" => "old"}, %{"body" => "current P1"}]} =
             GitHubReviewClient.merge_thread_comment_pages_for_test([
               page.("old"),
               page.("current P1")
             ])
  end

  test "a new head invalidates an old formal review and requests one deduplicated review" do
    snapshot = snapshot(%{current_head_sha: "new", reviewed_head_sha: "old"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, "aroakpm-svg/repo", "new", :pending, _}
    assert_receive {:review_requested, "aroakpm-svg/repo", 42, key}
    assert is_binary(key)

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "a persisted review-request key prevents a duplicate after monitor restart" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{reviewed_head_sha: nil})})
    key = ReviewConvergence.dedup_key(:review_request, "issue-160", "head", :codex)
    Application.put_env(:symphony_elixir, :existing_review_keys, [key])

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:review_requested, _, _, _}
    refute_receive {:status, _, _, _, _}
  end

  defmodule HistoryClient do
    @spec graphql(String.t(), map()) :: {:ok, map()}
    def graphql(_query, variables) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:history_page, variables.after})
      [response | rest] = Process.get(:history_responses)
      Process.put(:history_responses, rest)
      {:ok, response}
    end
  end

  test "review monitor ignores review-state issues outside tracker routing" do
    unroutable = %{issue() | id: "other", assigned_to_worker: false}
    Application.put_env(:symphony_elixir, :review_issues, [unroutable])
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{reviewed_head_sha: nil})})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:review_requested, _, _, _}
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
  end

  test "Linear rework history paginates and counts stable keys once" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)

    Process.put(:history_responses, [
      history_page([rework_body("one")], true, "next"),
      history_page([rework_body("one"), rework_body("two")], false, nil)
    ])

    assert {:ok, %{dedup: dedup, rework_count: 2}} = Adapter.review_history("issue-160")
    assert dedup == MapSet.new(["one", "two"])
    assert_receive {:history_page, nil}
    assert_receive {:history_page, "next"}
  end

  test "structured snapshot errors fail closed without crashing comment rendering" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, {:command_failed, 8, %{state: :pending}}})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", body}
    assert body =~ "command_failed"
  end

  test "evidence outage clears a known head's prior success with an error status" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: "known-head",
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "known-head", :error, _}
    assert_receive {:comment, "issue-160", _}
  end

  test "convergence republishes success after a transient error while keeping its comment deduplicated" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})
    key = ReviewConvergence.dedup_key(:converged, "issue-160", "head", :technical)

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new([key]),
        fix_rounds: 0,
        head_sha: "head",
        review_requested: false,
        waiting: true,
        last_finding_fingerprint: nil
      }
    }

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :success, _}
    refute_receive {:comment, _, _}
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

  test "missing current head fails closed and malformed threads are not actionable" do
    assert {:wait, %{reason: :missing_current_head}} =
             snapshot(%{current_head_sha: nil, threads: [:malformed]})
             |> ReviewConvergence.evaluate(0, 3)

    refute ReviewConvergence.actionable_thread?(:malformed)
  end

  test "structural risk escalates actionable findings before the retry limit" do
    assert {:escalate, %{reason: :review_not_converging}} =
             snapshot(%{
               structural_risk: true,
               threads: [%{resolved: false, priority: 4, body: "P4 architectural expansion"}]
             })
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
    assert_receive {:state, "issue-160", "In Progress"}
  end

  test "persisted rework key prevents duplicate tracker effects after restart" do
    finding = %{resolved: false, priority: 1, body: "P1 data loss", url: "https://example.test/thread"}
    fingerprint = [{1, nil, "P1 data loss"}]
    key = ReviewConvergence.dedup_key(:rework, "issue-160", "head", fingerprint)
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, %{dedup: MapSet.new([key]), rework_count: 1}}
    )

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :failure, _}
    refute_receive {:comment, _, _}
    assert_receive {:state, "issue-160", "In Progress"}
  end

  test "state transition retries after the rework comment already persisted" do
    finding = %{resolved: false, priority: 1, body: "P1 state retry", url: "thread"}
    fingerprint = [{1, nil, "P1 state retry"}]
    key = ReviewConvergence.dedup_key(:rework, "issue-160", "head", fingerprint)
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})
    Application.put_env(:symphony_elixir, :review_state_result, {:error, :linear_unavailable})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", _body}
    assert_receive {:state, "issue-160", "In Progress"}

    Application.put_env(:symphony_elixir, :review_history, {:ok, %{dedup: MapSet.new([key]), rework_count: 1}})
    Application.put_env(:symphony_elixir, :review_state_result, :ok)

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:comment, _, _}
    assert_receive {:state, "issue-160", "In Progress"}
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
    refute_receive {:review_requested, _, _, _}
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

  test "persisted rework rounds survive restart and force human escalation" do
    finding = %{resolved: false, priority: 2, body: "P2 recurring patch", url: "thread"}
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})
    Application.put_env(:symphony_elixir, :review_history, {:ok, %{dedup: MapSet.new(), rework_count: 3}})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", body}
    assert body =~ "review_not_converging"
    refute_receive {:state, _, _}
  end

  test "unverifiable persisted rework history fails closed" do
    Application.put_env(:symphony_elixir, :review_history, {:error, :linear_unavailable})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", body}
    assert body =~ "linear_unavailable"
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
      url: "https://linear.test/ARO-160",
      labels: ["owned"]
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

  defp rework_body(key) do
    %{"body" => "Review Convergence Gate found actionable latest-head findings.\n\ndedup-key: `#{key}`"}
  end

  defp history_page(nodes, has_next, cursor) do
    %{
      "data" => %{
        "issue" => %{
          "comments" => %{
            "nodes" => nodes,
            "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}
          }
        }
      }
    }
  end
end
