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
      System.cmd("git", ["-C", workspace, "remote", "add", "origin", actual_url],
        stderr_to_stdout: true
      )

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
    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-preflight-timeout-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(workspace_root, "bin")
    workspace = Path.join(workspace_root, "MT-TIMEOUT")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(workspace)
      write_sleeping_git!(fake_bin)
      System.put_env("PATH", fake_bin <> path_separator() <> (previous_path || ""))
      write_workflow_file!(Workflow.workflow_file_path(), hook_timeout_ms: 10)

      assert {:error, {:workspace_preflight_failed, :workspace_not_git_repo, command, detail}} =
               Workspace.preflight(workspace, "MT-TIMEOUT")

      assert command == "git rev-parse --is-inside-work-tree"
      assert detail == "timed out after 10ms"
    after
      File.rm_rf(workspace_root)
    end
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

  defp wait_for_blocked_issue(pid, issue_id, timeout_ms \\ 200) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_blocked_issue(pid, issue_id, deadline_ms)
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

  defp write_sleeping_git!(fake_bin) do
    if match?({:win32, _}, :os.type()) do
      File.write!(
        Path.join(fake_bin, "git.cmd"),
        "@echo off\r\nping -n 2 127.0.0.1 >NUL\r\nexit /b 0\r\n"
      )
    else
      git_path = Path.join(fake_bin, "git")
      File.write!(git_path, "#!/bin/sh\nsleep 1\nexit 0\n")
      File.chmod!(git_path, 0o755)
    end
  end

  defp path_separator do
    if match?({:win32, _}, :os.type()), do: ";", else: ":"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
