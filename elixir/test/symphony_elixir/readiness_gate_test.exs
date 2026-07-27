defmodule SymphonyElixir.ReadinessGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue.StackedBase
  alias SymphonyElixir.ReadinessGate
  alias SymphonyElixir.ReadinessGate.{Failure, Receipt}

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

    assert {:ok,
            %Receipt{
              classification: :continuation,
              issue_branch: "codex/aro-102-ahead",
              head_sha: ^local_sha,
              upstream: nil
            }} =
             ReadinessGate.check(fixture.workspace, issue, workspace_created_now: false)

    assert git!(fixture.workspace, ["rev-parse", "HEAD"]) == local_sha
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

    refute Enum.any?(commands, fn args ->
             Enum.any?(args, &(&1 in ["reset", "rebase", "--force", "-f", "-D", "-C"]))
           end)
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

      if Enum.take(args, 3) == ["switch", "-c", issue.branch_name] do
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
