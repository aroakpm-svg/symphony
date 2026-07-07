defmodule SymphonyElixir.WorkspacePreflightBlockerTest do
  use SymphonyElixir.TestSupport

  test "workspace preflight rejects an existing issue directory that is not a git repo" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-preflight-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-NOT-GIT")

      assert {:error, {:workspace_preflight_failed, :workspace_not_git_repo, command, status, output}} =
               Workspace.preflight(workspace, "MT-NOT-GIT")

      assert command == "git rev-parse --is-inside-work-tree"
      assert status != 0
      assert output =~ "not a git repository"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace preflight redacts credentials from remote mismatch diagnostics" do
    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)

    expected_secret = "expected-token-123"
    actual_secret = "actual-token-456"
    expected_url = "https://user:#{expected_secret}@github.com/example/right.git"
    actual_url = "https://user:#{actual_secret}@github.com/example/wrong.git"
    System.put_env("SOURCE_REPO_URL", expected_url)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-preflight-redaction-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(workspace_root, "MT-REDACT")

    try do
      File.mkdir_p!(workspace)
      System.cmd("git", ["-C", workspace, "init"], stderr_to_stdout: true)
      System.cmd("git", ["-C", workspace, "remote", "add", "origin", actual_url], stderr_to_stdout: true)

      assert {:error, {:workspace_preflight_failed, :git_remote_mismatch, _command, detail}} =
               Workspace.preflight(workspace, "MT-REDACT")

      refute detail =~ expected_secret
      refute detail =~ actual_secret
      assert detail =~ "https://[redacted]@github.com/example/right"
      assert detail =~ "https://[redacted]@github.com/example/wrong"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "local git preflight commands time out instead of hanging the worker slot" do
    write_workflow_file!(Workflow.workflow_file_path(), hook_timeout_ms: 10)
    {executable, args} = sleep_command()

    assert {:error, {:workspace_hook_timeout, "sleep", 10}} =
             Workspace.run_local_preflight_command_for_test(
               executable,
               args,
               "sleep"
             )
  end

  test "local git preflight preserves custom SSH command while forcing batch mode" do
    refute Enum.any?(
             Workspace.local_git_preflight_env_for_test(nil),
             &(elem(&1, 0) == "GIT_SSH_COMMAND")
           )

    refute Enum.any?(
             Workspace.local_git_preflight_env_for_test(""),
             &(elem(&1, 0) == "GIT_SSH_COMMAND")
           )

    assert Workspace.batch_mode_ssh_command_for_test("ssh -i /tmp/deploy-key") ==
             "ssh -i /tmp/deploy-key -o BatchMode=yes"

    assert Workspace.batch_mode_ssh_command_for_test("ssh -i /tmp/deploy-key -o BatchMode=yes") ==
             "ssh -i /tmp/deploy-key -o BatchMode=yes"
  end

  test "remote preflight normalizes actual origin trailing slashes" do
    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)

    System.put_env("SOURCE_REPO_URL", "https://github.com/example/repo")

    script = Workspace.remote_expected_repo_script_for_test()

    assert script =~ ~s(actual_remote="${actual_remote%/}"\nactual_remote="${actual_remote%.git}")
    assert script =~ ~s(expected_remote="${expected_remote%/}"\nexpected_remote="${expected_remote%.git}")
  end

  test "agent-reported workspace preflight failure blocks without retrying" do
    issue_id = "issue-preflight-blocker"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PREFLIGHT",
      title: "Preflight blocker",
      description: "Workspace is not usable",
      state: "In Progress",
      url: "https://example.org/issues/MT-PREFLIGHT"
    }

    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      worker_host: "worker-01",
      workspace_path: nil,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:retry_attempts, %{issue_id => %{attempt: 3}})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:agent_hard_blocker, issue_id,
       %{
         worker_host: "worker-01",
         workspace_path: "/workspaces/MT-PREFLIGHT",
         error: "workspace preflight failed type=workspace_not_git_repo command=git rev-parse --is-inside-work-tree status=128 output=fatal"
       }}
    )

    state = wait_for_blocked_issue(pid, issue_id)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert MapSet.member?(state.claimed, issue_id)

    assert %{
             identifier: "MT-PREFLIGHT",
             worker_host: "worker-01",
             workspace_path: "/workspaces/MT-PREFLIGHT",
             error: "workspace preflight failed type=workspace_not_git_repo" <> _
           } = state.blocked[issue_id]
  end

  test "agent run raises when a workspace preflight blocker cannot be reported" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-preflight-unreported-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-preflight-unreported",
      identifier: "MT-PREFLIGHT-UNREPORTED",
      title: "Preflight blocker without recipient",
      description: "Workspace is not usable",
      state: "In Progress",
      url: "https://example.org/issues/MT-PREFLIGHT-UNREPORTED"
    }

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      File.mkdir_p!(workspace)

      assert_raise RuntimeError, ~r/agent_hard_blocker_unreported/, fn ->
        AgentRunner.run(issue, nil)
      end
    after
      File.rm_rf(workspace_root)
    end
  end

  test "agent reports preflight blocker after after_run cleanup finishes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-preflight-cleanup-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-preflight-cleanup",
      identifier: "MT-PREFLIGHT-CLEANUP",
      title: "Preflight blocker waits for cleanup",
      description: "Workspace is not usable",
      state: "In Progress",
      url: "https://example.org/issues/MT-PREFLIGHT-CLEANUP"
    }

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_run: "printf cleanup > cleanup.marker"
      )

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      File.mkdir_p!(workspace)

      assert :ok = AgentRunner.run(issue, self())

      assert_receive {:agent_hard_blocker, "issue-preflight-cleanup", blocker_info}
      assert File.read!(Path.join(workspace, "cleanup.marker")) == "cleanup"
      assert blocker_info.workspace_path == workspace
    after
      File.rm_rf(workspace_root)
    end
  end

  defp wait_for_blocked_issue(pid, issue_id, timeout_ms \\ 200) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_blocked_issue(pid, issue_id, deadline_ms)
  end

  defp sleep_command do
    cond do
      System.find_executable("sh") ->
        {"sh", ["-c", "sleep 1"]}

      System.find_executable("pwsh") ->
        {"pwsh", ["-NoProfile", "-Command", "Start-Sleep -Seconds 1"]}

      true ->
        {"powershell.exe", ["-NoProfile", "-Command", "Start-Sleep -Seconds 1"]}
    end
  end

  defp do_wait_for_blocked_issue(pid, issue_id, deadline_ms) do
    state = :sys.get_state(pid)

    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for blocked issue: #{inspect(state)}")
      else
        Process.sleep(5)
        do_wait_for_blocked_issue(pid, issue_id, deadline_ms)
      end
    end
  end
end
