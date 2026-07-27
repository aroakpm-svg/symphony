defmodule SymphonyElixir.ReadinessGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue.StackedBase
  alias SymphonyElixir.ReadinessGate
  alias SymphonyElixir.ReadinessGate.{Failure, Receipt}

  test "public check requires typed workspace creation provenance before Git access" do
    issue = issue("ARO-099-PROVENANCE", "codex/aro-099-provenance")

    assert {:error,
            %Failure{
              code: :workspace_provenance_missing,
              command: nil,
              operator_action: action
            }} = ReadinessGate.check("/unused", issue)

    assert action =~ "AgentRunner"
  end

  test "rejects missing, non-string, padded, and malformed tracker branch evidence before Git access" do
    runner = fn _args -> flunk("invalid issue branch must fail before invoking Git") end

    cases = [
      {nil, "nil"},
      {42, "42"},
      {" codex/padded", "padded"},
      {"codex/bad branch", "bad branch"}
    ]

    Enum.each(cases, fn {branch, detail_fragment} ->
      invalid_issue = Map.put(issue("ARO-099-BRANCH", "codex/valid"), :branch_name, branch)

      assert {:error,
              %Failure{
                code: :issue_branch_missing_or_invalid,
                detail: detail
              }} =
               ReadinessGate.check("/unused", invalid_issue,
                 workspace_created_now: true,
                 command_runner: runner
               )

      assert detail =~ detail_fragment
    end)
  end

  test "creates independent work only from the verified live non-main canonical head" do
    fixture = git_fixture!("release/stable")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-101", "codex/aro-101")

    assert {:ok,
            %Receipt{
              classification: :independent_new,
              issue_branch: "codex/aro-101",
              head_sha: head_sha,
              canonical: %{branch: "release/stable", fetched_sha: head_sha}
            }} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert git!(fixture.workspace, ["branch", "--show-current"]) == "codex/aro-101"
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == head_sha
  end

  test "blocks a fresh workspace when the tracker issue branch is the canonical default" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-100-FRESH", "main")
    original_sha = git!(fixture.workspace, ["rev-parse", "HEAD"])

    assert {:error,
            %Failure{
              code: :issue_branch_is_canonical_default,
              operator_action: action
            }} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert action =~ "tracker issue branch"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == "main"
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == original_sha
  end

  test "blocks a reused workspace when the tracker issue branch is the canonical default" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-100-REUSED", "main")
    original_sha = git!(fixture.workspace, ["rev-parse", "HEAD"])

    assert {:error, %Failure{code: :issue_branch_is_canonical_default}} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: false)

    assert git!(fixture.workspace, ["branch", "--show-current"]) == "main"
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == original_sha
  end

  test "preserves a matching continuation branch and dirty local work after default advances" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-102", "codex/aro-102")

    git!(fixture.workspace, ["switch", "-c", issue.branch_name])
    File.write!(Path.join(fixture.workspace, "local-progress.txt"), "keep me\n")
    continuation_sha = git!(fixture.workspace, ["rev-parse", "HEAD"])
    live_default_sha = advance_default!(fixture, "default advanced\n")

    assert live_default_sha != continuation_sha

    assert {:ok,
            %Receipt{
              classification: :continuation,
              issue_branch: "codex/aro-102",
              head_sha: ^continuation_sha,
              canonical: %{fetched_sha: ^live_default_sha}
            }} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: false)

    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name
    assert File.read!(Path.join(fixture.workspace, "local-progress.txt")) == "keep me\n"
  end

  test "allows a reused continuation branch when its remote head is an ancestor of local HEAD" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-102-AHEAD", "codex/aro-102-ahead")
    remote_sha = push_branch!(fixture, issue.branch_name, "remote continuation\n")

    git!(fixture.workspace, ["fetch", "origin", "refs/heads/#{issue.branch_name}"])
    git!(fixture.workspace, ["switch", "-c", issue.branch_name, remote_sha])

    local_sha =
      commit_file!(
        fixture.workspace,
        "local-ahead.txt",
        "local continuation\n",
        "advance local continuation"
      )

    test_pid = self()

    runner = fn args ->
      send(test_pid, {:readiness_git_command, args})
      Workspace.run_git_command(fixture.workspace, args)
    end

    assert {:ok,
            %Receipt{
              classification: :continuation,
              issue_branch: "codex/aro-102-ahead",
              head_sha: ^local_sha,
              upstream: nil
            }} =
             ReadinessGate.check(fixture.workspace, issue,
               workspace_created_now: false,
               command_runner: runner
             )

    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == local_sha

    commands = drain_commands([])

    assert [
             ["merge-base", "--is-ancestor", ^remote_sha, ^local_sha],
             ["branch", "--show-current"],
             ["rev-parse", "--verify", "HEAD^{commit}"]
           ] =
             commands
             |> Enum.drop_while(&(&1 != ["merge-base", "--is-ancestor", remote_sha, local_sha]))
             |> Enum.take(3)
  end

  test "blocks a reused continuation branch that is behind its same-name remote" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-102-BEHIND", "codex/aro-102-behind")
    remote_sha = push_branch!(fixture, issue.branch_name, "initial remote continuation\n")

    git!(fixture.workspace, ["fetch", "origin", "refs/heads/#{issue.branch_name}"])
    git!(fixture.workspace, ["switch", "-c", issue.branch_name, remote_sha])
    advanced_remote_sha = advance_branch!(fixture, issue.branch_name, "remote advanced\n")
    refute advanced_remote_sha == remote_sha

    assert {:error,
            %Failure{
              code: :continuation_remote_not_ancestor,
              operator_action: action
            }} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: false)

    assert String.downcase(action) =~ "preserve"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == remote_sha
  end

  test "blocks a reused continuation branch that diverged from its same-name remote" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-102-DIVERGED", "codex/aro-102-diverged")
    remote_base_sha = push_branch!(fixture, issue.branch_name, "shared continuation base\n")

    git!(fixture.workspace, ["fetch", "origin", "refs/heads/#{issue.branch_name}"])
    git!(fixture.workspace, ["switch", "-c", issue.branch_name, remote_base_sha])

    local_sha =
      commit_file!(fixture.workspace, "local-side.txt", "local side\n", "advance local side")

    remote_sha = advance_branch!(fixture, issue.branch_name, "remote side\n")
    refute local_sha == remote_sha

    assert {:error, %Failure{code: :continuation_remote_not_ancestor}} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: false)

    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == local_sha
  end

  test "blocks a reused continuation branch with no merge base to its same-name remote" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-102-UNRELATED", "codex/aro-102-unrelated")

    git!(fixture.workspace, ["switch", "-c", issue.branch_name])
    local_sha = git!(fixture.workspace, ["rev-parse", "HEAD"])
    remote_sha = push_orphan_branch!(fixture, issue.branch_name)
    refute local_sha == remote_sha

    assert {:error, %Failure{code: :continuation_remote_not_ancestor}} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: false)

    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == local_sha
  end

  test "reuses an exact remote issue branch in a fresh clean workspace" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-103", "codex/aro-103")

    remote_issue_sha = push_branch!(fixture, issue.branch_name, "remote issue branch\n")

    assert {:ok,
            %Receipt{
              classification: :continuation,
              issue_branch: "codex/aro-103",
              head_sha: ^remote_issue_sha
            }} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == remote_issue_sha
  end

  test "accepts an already checked-out exact remote branch in a fresh workspace" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-103-EXACT-FRESH", "codex/aro-103-exact-fresh")
    remote_sha = push_branch!(fixture, issue.branch_name, "exact fresh branch\n")

    git!(fixture.workspace, ["fetch", "origin", "refs/heads/#{issue.branch_name}"])
    git!(fixture.workspace, ["switch", "-c", issue.branch_name, remote_sha])

    assert {:ok,
            %Receipt{
              classification: :continuation,
              issue_branch: "codex/aro-103-exact-fresh",
              head_sha: ^remote_sha
            }} = ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)
  end

  test "accepts an exact same-name remote head for a reused local continuation" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-103-EXACT-REUSED", "codex/aro-103-exact-reused")
    remote_sha = push_branch!(fixture, issue.branch_name, "exact reused branch\n")

    git!(fixture.workspace, ["fetch", "origin", "refs/heads/#{issue.branch_name}"])
    git!(fixture.workspace, ["switch", "-c", issue.branch_name, remote_sha])

    assert {:ok, %Receipt{classification: :continuation, head_sha: ^remote_sha}} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: false)
  end

  test "blocks a fresh checked-out issue branch that differs from its same-name remote" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-103-MISMATCH", "codex/aro-103-mismatch")
    local_sha = git!(fixture.workspace, ["rev-parse", "HEAD"])
    remote_sha = push_branch!(fixture, issue.branch_name, "different remote branch\n")
    refute local_sha == remote_sha
    git!(fixture.workspace, ["switch", "-c", issue.branch_name, local_sha])

    assert {:error,
            %Failure{
              code: :new_issue_branch_remote_mismatch,
              detail: detail
            }} = ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert detail =~ local_sha
    assert detail =~ remote_sha
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == local_sha
  end

  test "blocks a pre-created local issue branch in a newly created stale workspace" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-104", "codex/aro-104")
    stale_sha = git!(fixture.workspace, ["rev-parse", "HEAD"])

    git!(fixture.workspace, ["switch", "-c", issue.branch_name, stale_sha])
    live_default_sha = advance_default!(fixture, "new live default\n")

    assert live_default_sha != stale_sha

    assert {:error,
            %Failure{
              code: :new_issue_branch_already_exists,
              operator_action: action
            }} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert String.downcase(action) =~ "preserve"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == stale_sha
  end

  test "blocks detached and mismatched continuation workspaces without switching branches" do
    detached_fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(detached_fixture) end)
    detached_issue = issue("ARO-105", "codex/aro-105")
    git!(detached_fixture.workspace, ["checkout", "--detach"])

    assert {:error, %Failure{code: :detached_head}} =
             ReadinessGate.check(detached_fixture.workspace, detached_issue, workspace_created_now: false)

    mismatch_fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(mismatch_fixture) end)
    mismatch_issue = issue("ARO-106", "codex/aro-106")
    git!(mismatch_fixture.workspace, ["branch", mismatch_issue.branch_name])
    original_branch = git!(mismatch_fixture.workspace, ["branch", "--show-current"])

    assert {:error, %Failure{code: :continuation_branch_not_checked_out}} =
             ReadinessGate.check(mismatch_fixture.workspace, mismatch_issue, workspace_created_now: false)

    assert git!(mismatch_fixture.workspace, ["branch", "--show-current"]) == original_branch
  end

  test "blocks dirty independent workspaces rather than hiding changes" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-107", "codex/aro-107")
    File.write!(Path.join(fixture.workspace, "untracked.txt"), "do not hide\n")

    assert {:error, %Failure{code: :independent_workspace_dirty, detail: detail}} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert detail =~ "untracked.txt"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == "main"
  end

  test "blocks a dirty workspace before materializing an exact remote issue branch" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-107-REMOTE", "codex/aro-107-remote")
    remote_sha = push_branch!(fixture, issue.branch_name, "remote continuation\n")
    File.write!(Path.join(fixture.workspace, "preserve-before-remote.txt"), "preserve me\n")

    assert {:error,
            %Failure{
              code: :continuation_workspace_dirty,
              detail: detail
            }} = ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert detail =~ "preserve-before-remote.txt"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == "main"
    refute git!(fixture.workspace, ["rev-parse", "HEAD"]) == remote_sha
    assert File.read!(Path.join(fixture.workspace, "preserve-before-remote.txt")) == "preserve me\n"
  end

  test "blocks an unsupported typed readiness base without creating a branch" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)

    issue =
      issue("ARO-107-BASE", "codex/aro-107-base")
      |> Map.put(:readiness_base, :unsupported)

    assert {:error,
            %Failure{
              code: :readiness_base_invalid,
              detail: detail
            }} = ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert detail =~ ":unsupported"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == "main"
  end

  test "creates explicit stacked work only from one exact typed upstream branch and SHA" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    upstream_branch = "stack/aro-108-base"
    upstream_sha = push_branch!(fixture, upstream_branch, "stack base\n")

    issue =
      issue("ARO-108", "codex/aro-108")
      |> Map.put(
        :readiness_base,
        {:stacked, [%StackedBase{branch: upstream_branch, head_sha: upstream_sha}]}
      )

    assert {:ok,
            %Receipt{
              classification: :explicit_stack,
              issue_branch: "codex/aro-108",
              head_sha: ^upstream_sha,
              upstream: %{branch: ^upstream_branch, fetched_sha: ^upstream_sha}
            }} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name
    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == upstream_sha
  end

  test "fails closed for missing, multiple, malformed, stale, or absent stacked evidence" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    upstream_branch = "stack/aro-109-base"
    upstream_sha = push_branch!(fixture, upstream_branch, "stack base\n")

    cases = [
      {{:stacked, []}, :stacked_evidence_missing},
      {{:stacked,
        [
          %StackedBase{branch: upstream_branch, head_sha: upstream_sha},
          %StackedBase{branch: "stack/other", head_sha: upstream_sha}
        ]}, :stacked_evidence_ambiguous},
      {{:stacked, [%StackedBase{branch: "", head_sha: upstream_sha}]}, :stacked_evidence_invalid},
      {{:stacked, [:not_typed_evidence]}, :stacked_evidence_invalid},
      {{:stacked, [%StackedBase{branch: upstream_branch, head_sha: String.duplicate("c", 40)}]}, :stacked_head_mismatch},
      {{:stacked, [%StackedBase{branch: "stack/missing", head_sha: upstream_sha}]}, :stacked_branch_missing}
    ]

    Enum.with_index(cases, 1)
    |> Enum.each(fn {{readiness_base, expected_code}, index} ->
      issue =
        issue("ARO-109-#{index}", "codex/aro-109-#{index}")
        |> Map.put(:readiness_base, readiness_base)

      assert {:error, %Failure{code: ^expected_code}} =
               ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)
    end)
  end

  test "does not infer stacked work from issue prose or blocker relations" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    upstream_sha = push_branch!(fixture, "stack/prose-only", "prose branch\n")
    canonical_sha = remote_default_sha!(fixture)

    assert upstream_sha != canonical_sha

    issue = %{
      issue("ARO-110", "codex/aro-110")
      | description: "Stack this on stack/prose-only at #{upstream_sha}",
        blocked_by: [%{identifier: "ARO-109", state: "In Progress"}]
    }

    assert {:ok, %Receipt{classification: :independent_new, head_sha: ^canonical_sha}} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)
  end

  test "independent materialization preserves an ignored file that the canonical head tracks" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-110-IGNORED-INDEPENDENT", "codex/aro-110-ignored-independent")
    collision = "independent-collision.txt"

    push_tracked_file!(fixture, fixture.default_branch, collision, "canonical contents\n")
    preserve_ignored_file!(fixture.workspace, collision, "local ignored contents\n")

    assert {:error,
            %Failure{
              code: :command_failed,
              command: command
            }} = ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert command =~ "git switch --no-overwrite-ignore -c #{issue.branch_name}"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == fixture.default_branch
    assert git!(fixture.workspace, ["branch", "--list", issue.branch_name]) == ""
    assert File.read!(Path.join(fixture.workspace, collision)) == "local ignored contents\n"
  end

  test "remote continuation materialization preserves an ignored file tracked by the issue branch" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-110-IGNORED-REMOTE", "codex/aro-110-ignored-remote")
    collision = "remote-collision.txt"

    push_tracked_file!(fixture, issue.branch_name, collision, "remote contents\n")
    preserve_ignored_file!(fixture.workspace, collision, "local ignored contents\n")

    assert {:error, %Failure{code: :command_failed, command: command}} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert command =~ "git switch --no-overwrite-ignore -c #{issue.branch_name}"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == fixture.default_branch
    assert git!(fixture.workspace, ["branch", "--list", issue.branch_name]) == ""
    assert File.read!(Path.join(fixture.workspace, collision)) == "local ignored contents\n"
  end

  test "stacked materialization preserves an ignored file tracked by the exact upstream" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue_branch = "codex/aro-110-ignored-stacked"
    upstream_branch = "stack/aro-110-ignored-base"
    collision = "stacked-collision.txt"

    upstream_sha =
      push_tracked_file!(fixture, upstream_branch, collision, "stacked contents\n")

    issue =
      issue("ARO-110-IGNORED-STACKED", issue_branch)
      |> Map.put(
        :readiness_base,
        {:stacked, [%StackedBase{branch: upstream_branch, head_sha: upstream_sha}]}
      )

    preserve_ignored_file!(fixture.workspace, collision, "local ignored contents\n")

    assert {:error, %Failure{code: :command_failed, command: command}} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: true)

    assert command =~ "git switch --no-overwrite-ignore -c #{issue.branch_name}"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == fixture.default_branch
    assert git!(fixture.workspace, ["branch", "--list", issue.branch_name]) == ""
    assert File.read!(Path.join(fixture.workspace, collision)) == "local ignored contents\n"
  end

  test "branch creation never invokes reset, rebase, force checkout, or branch deletion" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-111", "codex/aro-111")
    test_pid = self()

    runner = fn args ->
      send(test_pid, {:readiness_git_command, args})
      Workspace.run_git_command(fixture.workspace, args)
    end

    assert {:ok, %Receipt{classification: :independent_new}} =
             ReadinessGate.check(fixture.workspace, issue,
               workspace_created_now: true,
               command_runner: runner
             )

    commands = drain_commands([])
    issue_branch = issue.branch_name

    refute Enum.any?(commands, fn args ->
             Enum.any?(args, &(&1 in ["reset", "rebase", "--force", "-f", "-D", "-C"]))
           end)

    assert [
             ["switch", "--no-overwrite-ignore", "-c", ^issue_branch, _base_sha],
             ["branch", "--show-current"],
             ["rev-parse", "--verify", "HEAD^{commit}"],
             ["status", "--porcelain=v1", "--untracked-files=all"]
           ] =
             commands
             |> Enum.drop_while(fn args ->
               Enum.take(args, 4) != ["switch", "--no-overwrite-ignore", "-c", issue_branch]
             end)
             |> Enum.take(4)
  end

  test "blocks and preserves a continuation branch whose HEAD changes during remote lookup" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-112", "codex/aro-112")
    git!(fixture.workspace, ["switch", "-c", issue.branch_name])
    initial_sha = git!(fixture.workspace, ["rev-parse", "HEAD"])
    lookup_args = ["ls-remote", "--heads", "origin", "refs/heads/#{issue.branch_name}"]

    runner = fn args ->
      result = Workspace.run_git_command(fixture.workspace, args)

      if args == lookup_args do
        commit_file!(
          fixture.workspace,
          "concurrent-head.txt",
          "preserve concurrent commit\n",
          "concurrent continuation change"
        )
      end

      result
    end

    assert {:error, %Failure{code: :workspace_changed_during_readiness}} =
             ReadinessGate.check(fixture.workspace, issue,
               workspace_created_now: false,
               command_runner: runner
             )

    final_sha = git!(fixture.workspace, ["rev-parse", "HEAD"])
    refute final_sha == initial_sha
    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name

    assert File.read!(Path.join(fixture.workspace, "concurrent-head.txt")) ==
             "preserve concurrent commit\n"
  end

  test "blocks and preserves changes that appear after materializing an independent branch" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-113", "codex/aro-113")
    concurrent_path = Path.join(fixture.workspace, "concurrent-untracked.txt")

    runner = fn args ->
      result = Workspace.run_git_command(fixture.workspace, args)

      if Enum.take(args, 4) ==
           ["switch", "--no-overwrite-ignore", "-c", issue.branch_name] do
        File.write!(concurrent_path, "preserve concurrent file\n")
      end

      result
    end

    assert {:error,
            %Failure{
              code: :workspace_changed_during_readiness,
              detail: detail
            }} =
             ReadinessGate.check(fixture.workspace, issue,
               workspace_created_now: true,
               command_runner: runner
             )

    assert detail =~ "concurrent-untracked.txt"
    assert git!(fixture.workspace, ["branch", "--show-current"]) == issue.branch_name
    assert File.read!(concurrent_path) == "preserve concurrent file\n"
  end

  test "maps ancestry command timeout, failure, unexpected, rescue, and catch results" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    issue = issue("ARO-114", "codex/aro-114")
    remote_sha = push_branch!(fixture, issue.branch_name, "ancestry base\n")
    git!(fixture.workspace, ["fetch", "origin", "refs/heads/#{issue.branch_name}"])
    git!(fixture.workspace, ["switch", "-c", issue.branch_name, remote_sha])
    local_sha = commit_file!(fixture.workspace, "ahead.txt", "ahead\n", "advance local")
    merge_args = ["merge-base", "--is-ancestor", remote_sha, local_sha]
    merge_command = Enum.join(["git" | merge_args], " ")
    secret = "readiness-secret-token"

    cases = [
      {"timeout", fn -> {:error, {:workspace_hook_timeout, "ignored command", 25}} end, :command_timeout, "25ms", merge_command},
      {"status failure",
       fn ->
         {:error, {:git_command_failed, "git merge custom", 128, "fatal: https://user:#{secret}@github.com/example/private.git"}}
       end, :command_failed, "https://[redacted]@github.com/example/private.git", "git merge custom"},
      {"term detail", fn -> {:error, {:git_command_failed, "git merge custom", %{reason: :transport_down}}} end, :command_failed, "transport_down", "git merge custom"},
      {"unexpected", fn -> :unexpected_result end, :command_failed, "unexpected command result", merge_command},
      {"rescue", fn -> raise "readiness runner exploded" end, :command_failed, "readiness runner exploded", merge_command},
      {"catch", fn -> throw(:readiness_runner_threw) end, :command_failed, "readiness_runner_threw", merge_command}
    ]

    Enum.each(cases, fn {name, merge_result, expected_code, detail_fragment, expected_command} ->
      runner = fn args ->
        if args == merge_args do
          merge_result.()
        else
          Workspace.run_git_command(fixture.workspace, args)
        end
      end

      assert {:error,
              %Failure{
                code: ^expected_code,
                command: ^expected_command,
                detail: detail
              }} =
               ReadinessGate.check(fixture.workspace, issue,
                 workspace_created_now: false,
                 command_runner: runner
               ),
             name

      assert detail =~ detail_fragment, name
      refute detail =~ secret, name
      assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == local_sha
    end)
  end

  test "fails closed for malformed workspace branch and HEAD command output" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    sha = git!(fixture.workspace, ["rev-parse", "HEAD"])

    cases = [
      {"invalid branch", ["branch", "--show-current"], "bad branch\n", :workspace_branch_invalid},
      {"ambiguous branch", ["branch", "--show-current"], "main\nother\n", :workspace_branch_ambiguous},
      {"invalid head", ["rev-parse", "--verify", "HEAD^{commit}"], "not-a-sha\n", :workspace_head_invalid},
      {"ambiguous head", ["rev-parse", "--verify", "HEAD^{commit}"], "#{sha}\n#{String.duplicate("d", 40)}\n", :workspace_head_invalid}
    ]

    Enum.with_index(cases, 1)
    |> Enum.each(fn {{name, overridden_args, output, expected_code}, index} ->
      issue = issue("ARO-115-#{index}", "codex/aro-115-#{index}")

      runner = fn args ->
        if args == overridden_args do
          {:ok, output}
        else
          Workspace.run_git_command(fixture.workspace, args)
        end
      end

      assert {:error, %Failure{code: ^expected_code, operator_action: action}} =
               ReadinessGate.check(fixture.workspace, issue,
                 workspace_created_now: true,
                 command_runner: runner
               ),
             name

      assert is_binary(action) and action != "", name
    end)
  end

  test "translates canonical and issue-branch resolver failures without losing evidence" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)

    canonical_issue = issue("ARO-116-CANONICAL", "codex/aro-116-canonical")

    canonical_runner = fn
      ["ls-remote", "--symref", "origin", "HEAD"] -> {:ok, ""}
      args -> Workspace.run_git_command(fixture.workspace, args)
    end

    assert {:error,
            %Failure{
              code: :canonical_symref_missing,
              command: "git ls-remote --symref origin HEAD",
              operator_action: canonical_action
            }} =
             ReadinessGate.check(fixture.workspace, canonical_issue,
               workspace_created_now: true,
               command_runner: canonical_runner
             )

    assert canonical_action =~ "origin HEAD"

    issue_branch_issue = issue("ARO-116-BRANCH", "codex/aro-116-branch")
    issue_ref = "refs/heads/#{issue_branch_issue.branch_name}"

    issue_runner = fn
      ["ls-remote", "--heads", "origin", ^issue_ref] ->
        {:ok, "#{String.duplicate("a", 40)}\trefs/heads/wrong\n"}

      args ->
        Workspace.run_git_command(fixture.workspace, args)
    end

    assert {:error,
            %Failure{
              code: :branch_head_invalid,
              command: command,
              detail: detail
            }} =
             ReadinessGate.check(fixture.workspace, issue_branch_issue,
               workspace_created_now: true,
               command_runner: issue_runner
             )

    assert command == "git ls-remote --heads origin #{issue_ref}"
    assert detail =~ "invalid remote branch evidence"
  end

  test "propagates a malformed explicit stacked-branch lookup as one readiness failure" do
    fixture = git_fixture!("main")
    on_exit(fn -> cleanup_fixture(fixture) end)
    upstream_branch = "stack/malformed"
    upstream_ref = "refs/heads/#{upstream_branch}"

    issue =
      issue("ARO-117", "codex/aro-117")
      |> Map.put(
        :readiness_base,
        {:stacked, [%StackedBase{branch: upstream_branch, head_sha: String.duplicate("a", 40)}]}
      )

    runner = fn
      ["ls-remote", "--heads", "origin", ^upstream_ref] ->
        {:ok, "#{String.duplicate("a", 40)}\trefs/heads/wrong\n"}

      args ->
        Workspace.run_git_command(fixture.workspace, args)
    end

    assert {:error,
            %Failure{
              code: :branch_head_invalid,
              command: "git ls-remote --heads origin " <> ^upstream_ref
            }} =
             ReadinessGate.check(fixture.workspace, issue,
               workspace_created_now: true,
               command_runner: runner
             )

    assert git!(fixture.workspace, ["branch", "--show-current"]) == "main"
  end

  test "blocks and preserves concurrent branch or HEAD changes after materialization" do
    cases = [
      {"branch switch", :created_branch_mismatch, fn fixture, _issue -> git!(fixture.workspace, ["switch", fixture.default_branch]) end},
      {"HEAD commit", :created_branch_head_mismatch,
       fn fixture, issue ->
         commit_file!(
           fixture.workspace,
           "#{String.replace(issue.branch_name, "/", "-")}-concurrent.txt",
           "concurrent head\n",
           "concurrent head change"
         )
       end}
    ]

    Enum.with_index(cases, 1)
    |> Enum.each(fn {{name, expected_code, mutate}, index} ->
      fixture = git_fixture!("main")
      on_exit(fn -> cleanup_fixture(fixture) end)
      issue = issue("ARO-118-#{index}", "codex/aro-118-#{index}")

      runner = fn args ->
        result = Workspace.run_git_command(fixture.workspace, args)

        if Enum.take(args, 4) ==
             ["switch", "--no-overwrite-ignore", "-c", issue.branch_name] do
          mutate.(fixture, issue)
        end

        result
      end

      assert {:error,
              %Failure{
                code: ^expected_code,
                operator_action: action
              }} =
               ReadinessGate.check(fixture.workspace, issue,
                 workspace_created_now: true,
                 command_runner: runner
               ),
             name

      assert String.downcase(action) =~ "preserve", name
      assert git!(fixture.workspace, ["show-ref", "--verify", "refs/heads/#{issue.branch_name}"]) != ""
    end)
  end

  defp issue(identifier, branch_name) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Readiness for #{identifier}",
      description: "Use the typed readiness contract",
      state: "In Progress",
      branch_name: branch_name,
      readiness_base: :canonical,
      labels: []
    }
  end

  defp git_fixture!(default_branch) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-readiness-git-#{System.unique_integer([:positive])}"
      )

    remote = Path.join(root, "origin.git")
    seed = Path.join(root, "seed")
    workspace = Path.join(root, "workspace")

    File.mkdir_p!(root)
    cmd!("git", ["init", "--bare", remote])
    cmd!("git", ["init", "-b", default_branch, seed])
    configure_identity!(seed)
    File.write!(Path.join(seed, "README.md"), "initial\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-m", "initial"])
    git!(seed, ["remote", "add", "origin", remote])
    git!(seed, ["push", "-u", "origin", default_branch])
    cmd!("git", ["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/#{default_branch}"])
    cmd!("git", ["clone", remote, workspace])
    configure_identity!(workspace)

    %{root: root, remote: remote, seed: seed, workspace: workspace, default_branch: default_branch}
  end

  defp advance_default!(fixture, contents) do
    git!(fixture.seed, ["switch", fixture.default_branch])
    File.write!(Path.join(fixture.seed, "README.md"), contents)
    git!(fixture.seed, ["add", "README.md"])
    git!(fixture.seed, ["commit", "-m", "advance default"])
    git!(fixture.seed, ["push", "origin", fixture.default_branch])
    git!(fixture.seed, ["rev-parse", "HEAD"])
  end

  defp push_branch!(fixture, branch, contents) do
    git!(fixture.seed, ["switch", fixture.default_branch])
    git!(fixture.seed, ["switch", "-c", branch])
    path = Path.join(fixture.seed, String.replace(branch, "/", "-") <> ".txt")
    File.write!(path, contents)
    git!(fixture.seed, ["add", Path.basename(path)])
    git!(fixture.seed, ["commit", "-m", "add #{branch}"])
    git!(fixture.seed, ["push", "-u", "origin", branch])
    sha = git!(fixture.seed, ["rev-parse", "HEAD"])
    git!(fixture.seed, ["switch", fixture.default_branch])
    sha
  end

  defp advance_branch!(fixture, branch, contents) do
    git!(fixture.seed, ["switch", branch])
    path = Path.join(fixture.seed, String.replace(branch, "/", "-") <> "-advance.txt")
    File.write!(path, contents)
    git!(fixture.seed, ["add", Path.basename(path)])
    git!(fixture.seed, ["commit", "-m", "advance #{branch}"])
    git!(fixture.seed, ["push", "origin", branch])
    sha = git!(fixture.seed, ["rev-parse", "HEAD"])
    git!(fixture.seed, ["switch", fixture.default_branch])
    sha
  end

  defp push_tracked_file!(fixture, branch, filename, contents) do
    git!(fixture.seed, ["switch", fixture.default_branch])

    if branch != fixture.default_branch do
      git!(fixture.seed, ["switch", "-c", branch])
    end

    File.write!(Path.join(fixture.seed, filename), contents)
    git!(fixture.seed, ["add", filename])
    git!(fixture.seed, ["commit", "-m", "track #{filename} on #{branch}"])
    git!(fixture.seed, ["push", "origin", branch])
    sha = git!(fixture.seed, ["rev-parse", "HEAD"])

    if branch != fixture.default_branch do
      git!(fixture.seed, ["switch", fixture.default_branch])
    end

    sha
  end

  defp preserve_ignored_file!(workspace, filename, contents) do
    File.write!(Path.join([workspace, ".git", "info", "exclude"]), "#{filename}\n", [:append])
    File.write!(Path.join(workspace, filename), contents)
    assert git!(workspace, ["status", "--porcelain=v1", "--untracked-files=all"]) == ""
  end

  defp push_orphan_branch!(fixture, branch) do
    tree_sha = git!(fixture.seed, ["write-tree"])
    orphan_sha = git!(fixture.seed, ["commit-tree", tree_sha, "-m", "unrelated #{branch}"])
    git!(fixture.seed, ["push", "origin", "#{orphan_sha}:refs/heads/#{branch}"])
    orphan_sha
  end

  defp commit_file!(repo, filename, contents, message) do
    File.write!(Path.join(repo, filename), contents)
    git!(repo, ["add", filename])
    git!(repo, ["commit", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp remote_default_sha!(fixture) do
    git!(fixture.seed, ["rev-parse", fixture.default_branch])
  end

  defp configure_identity!(repo) do
    git!(repo, ["config", "user.name", "Symphony Test"])
    git!(repo, ["config", "user.email", "symphony@example.com"])
  end

  defp git!(repo, args) do
    cmd!("git", ["-C", repo | args])
  end

  defp cmd!(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("command failed status=#{status}: #{executable} #{Enum.join(args, " ")}\n#{output}")
    end
  end

  defp cleanup_fixture(%{root: root}), do: File.rm_rf(root)

  defp drain_commands(commands) do
    receive do
      {:readiness_git_command, args} -> drain_commands([args | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end
end
