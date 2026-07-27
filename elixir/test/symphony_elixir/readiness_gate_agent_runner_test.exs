defmodule SymphonyElixir.ReadinessGateAgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "stale branch in a fresh workspace hard-blocks before before_run and AppServer" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)
    System.put_env("SOURCE_REPO_URL", fixture.remote)

    issue = issue("ARO-201", "codex/aro-201")
    stale_sha = fixture.initial_sha
    live_sha = advance_default!(fixture, "live default advanced\n")
    refute stale_sha == live_sha

    before_run_marker = Path.join(fixture.root, "before-run.marker")
    app_server_marker = Path.join(fixture.root, "app-server.marker")
    after_run_marker = Path.join(fixture.root, "after-run.marker")
    fake_codex = Path.join(fixture.root, "fake-codex")

    File.write!(fake_codex, """
    #!/bin/sh
    printf launched > #{shell_escape(app_server_marker)}
    exit 91
    """)

    File.chmod!(fake_codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      hook_after_create: """
      git clone #{shell_escape(fixture.remote)} .
      git switch -c #{shell_escape(issue.branch_name)} #{shell_escape(stale_sha)}
      """,
      hook_before_run: "printf before > #{shell_escape(before_run_marker)}",
      hook_after_run: "printf after > #{shell_escape(after_run_marker)}",
      codex_command: "#{fake_codex} app-server"
    )

    assert :ok = AgentRunner.run(issue, self())

    assert_receive {:agent_hard_blocker, "issue-ARO-201", blocker}
    assert blocker.error =~ "workspace readiness failed"
    assert blocker.error =~ "new_issue_branch_already_exists"
    assert File.exists?(after_run_marker)
    refute File.exists?(before_run_marker)
    refute File.exists?(app_server_marker)

    assert git!(blocker.workspace_path, ["branch", "--show-current"]) == issue.branch_name
    assert git!(blocker.workspace_path, ["rev-parse", "HEAD"]) == stale_sha
  end

  test "canonical default as tracker issue branch hard-blocks before before_run and AppServer" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)
    System.put_env("SOURCE_REPO_URL", fixture.remote)

    issue = issue("ARO-203", "main")
    before_run_marker = Path.join(fixture.root, "before-default-run.marker")
    app_server_marker = Path.join(fixture.root, "default-app-server.marker")
    fake_codex = Path.join(fixture.root, "fake-default-codex")

    File.write!(fake_codex, """
    #!/bin/sh
    printf launched > #{shell_escape(app_server_marker)}
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-default"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-default"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    File.chmod!(fake_codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      hook_after_create: "git clone #{shell_escape(fixture.remote)} .",
      hook_before_run: "printf before > #{shell_escape(before_run_marker)}",
      codex_command: "#{fake_codex} app-server"
    )

    state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

    assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

    assert_receive {:agent_hard_blocker, "issue-ARO-203", blocker}
    assert blocker.error =~ "workspace readiness failed"
    assert blocker.error =~ "issue_branch_is_canonical_default"
    refute File.exists?(before_run_marker)
    refute File.exists?(app_server_marker)
    assert git!(blocker.workspace_path, ["branch", "--show-current"]) == "main"
  end

  test "existing continuation branch remains usable after the canonical default advances" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)
    System.put_env("SOURCE_REPO_URL", fixture.remote)

    issue = issue("ARO-202", "codex/aro-202")
    before_run_marker = Path.join(fixture.root, "before-run.marker")
    app_server_marker = Path.join(fixture.root, "app-server.marker")
    fake_codex = Path.join(fixture.root, "fake-codex")

    File.write!(fake_codex, """
    #!/bin/sh
    printf launched > #{shell_escape(app_server_marker)}
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-readiness"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-readiness"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    File.chmod!(fake_codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      hook_after_create: "git clone #{shell_escape(fixture.remote)} .",
      hook_before_run: "printf before > #{shell_escape(before_run_marker)}",
      codex_command: "#{fake_codex} app-server"
    )

    assert {:ok, workspace} = Workspace.create_for_issue(issue)
    configure_identity!(workspace)
    git!(workspace, ["switch", "-c", issue.branch_name])
    File.write!(Path.join(workspace, "continuation.txt"), "preserve continuation\n")
    git!(workspace, ["add", "continuation.txt"])
    git!(workspace, ["commit", "-m", "continuation work"])
    continuation_sha = git!(workspace, ["rev-parse", "HEAD"])

    live_sha = advance_default!(fixture, "default moved again\n")
    refute continuation_sha == live_sha

    state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

    assert :ok =
             AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

    assert File.exists?(before_run_marker)
    assert File.exists?(app_server_marker)
    assert git!(workspace, ["branch", "--show-current"]) == issue.branch_name
    assert git!(workspace, ["rev-parse", "HEAD"]) == continuation_sha
  end

  defp issue(identifier, branch_name) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Agent readiness for #{identifier}",
      description: "Exercise the typed gate",
      state: "In Progress",
      branch_name: branch_name,
      readiness_base: :canonical,
      labels: []
    }
  end

  defp git_fixture! do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-readiness-runner-#{System.unique_integer([:positive])}"
      )

    remote = Path.join(root, "origin.git")
    seed = Path.join(root, "seed")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(workspace_root)
    cmd!("git", ["init", "--bare", remote])
    cmd!("git", ["init", "-b", "main", seed])
    configure_identity!(seed)
    File.write!(Path.join(seed, "README.md"), "initial\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-m", "initial"])
    git!(seed, ["remote", "add", "origin", remote])
    git!(seed, ["push", "-u", "origin", "main"])
    cmd!("git", ["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/main"])

    %{
      root: root,
      remote: remote,
      seed: seed,
      workspace_root: workspace_root,
      initial_sha: git!(seed, ["rev-parse", "HEAD"])
    }
  end

  defp advance_default!(fixture, contents) do
    git!(fixture.seed, ["switch", "main"])
    File.write!(Path.join(fixture.seed, "README.md"), contents)
    git!(fixture.seed, ["add", "README.md"])
    git!(fixture.seed, ["commit", "-m", "advance main"])
    git!(fixture.seed, ["push", "origin", "main"])
    git!(fixture.seed, ["rev-parse", "HEAD"])
  end

  defp configure_identity!(repo) do
    git!(repo, ["config", "user.name", "Symphony Test"])
    git!(repo, ["config", "user.email", "symphony@example.com"])
  end

  defp git!(repo, args), do: cmd!("git", ["-C", repo | args])

  defp cmd!(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("command failed status=#{status}: #{executable} #{Enum.join(args, " ")}\n#{output}")
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
