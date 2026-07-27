defmodule SymphonyElixir.WorkspaceReadinessStateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitBranchResolver.Receipt, as: GitReceipt
  alias SymphonyElixir.ReadinessGate
  alias SymphonyElixir.ReadinessGate.{Failure, Receipt}

  @sha String.duplicate("a", 40)

  test "new workspace readiness provenance survives reuse and advances only from a matching receipt" do
    test_root = temporary_root!("local-state")
    workspace_root = Path.join(test_root, "workspaces")
    issue = issue("ARO-301", "codex/aro-301")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok,
            %{
              path: workspace,
              created_now: true,
              readiness_state:
                %{
                  provenance: :created,
                  phase: :unverified,
                  issue_id: "issue-ARO-301",
                  issue_identifier: "ARO-301",
                  issue_branch: "codex/aro-301",
                  workspace_path: workspace,
                  verified_head_sha: nil
                } = initial_state
            } = initial_preparation} = Workspace.prepare_for_issue(issue)

    state_path = Workspace.readiness_state_path(workspace)
    assert File.regular?(state_path)

    assert {:ok,
            %{
              path: ^workspace,
              created_now: false,
              readiness_state: ^initial_state
            }} = Workspace.prepare_for_issue(issue)

    mismatched_receipt = %{readiness_receipt(issue) | issue_branch: "codex/other"}

    assert {:error, {:workspace_readiness_receipt_mismatch, ^workspace, :issue_branch}} =
             Workspace.mark_readiness_ready(
               initial_preparation,
               issue,
               mismatched_receipt
             )

    assert {:ok, %{readiness_state: %{phase: :unverified}}} =
             Workspace.prepare_for_issue(issue)

    assert :ok =
             Workspace.mark_readiness_ready(
               initial_preparation,
               issue,
               readiness_receipt(issue),
               nil,
               command_runner: readiness_checkout_runner(issue)
             )

    assert {:ok,
            %{
              created_now: false,
              readiness_state: %{
                provenance: :created,
                phase: :ready,
                verified_head_sha: @sha
              }
            }} = Workspace.prepare_for_issue(issue)

    assert {:ok, _removed} = Workspace.remove(workspace)
    refute File.exists?(workspace)
    refute File.exists?(state_path)
  end

  test "malformed, cross-issue, and workspace-mismatched state all fail closed" do
    test_root = temporary_root!("invalid-state")
    workspace_root = Path.join(test_root, "workspaces")
    first_issue = issue("ARO/302", "codex/aro-302")
    colliding_issue = issue("ARO_302", "codex/aro-302-other")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, %{path: workspace}} = Workspace.prepare_for_issue(first_issue)
    state_path = Workspace.readiness_state_path(workspace)
    original_json = File.read!(state_path)

    assert {:error, {:workspace_readiness_identity_mismatch, ^workspace, identity_detail}} =
             Workspace.prepare_for_issue(colliding_issue)

    assert identity_detail =~ "issue"

    tampered_json =
      original_json
      |> Jason.decode!()
      |> Map.put("workspace_path", workspace <> "-different")
      |> Jason.encode!()

    File.write!(state_path, tampered_json)

    assert {:error, {:workspace_readiness_identity_mismatch, ^workspace, workspace_detail}} =
             Workspace.prepare_for_issue(first_issue)

    assert workspace_detail =~ "workspace_path"

    File.write!(state_path, "{not-json")

    assert {:error, {:workspace_readiness_state_invalid, ^workspace, invalid_detail}} =
             Workspace.prepare_for_issue(first_issue)

    assert invalid_detail =~ "JSON"
  end

  test "legacy state adopts only an exact same-name remote continuation" do
    fixture = git_fixture!("legacy-exact")
    issue = issue("ARO-303", "codex/aro-303")
    remote_sha = push_branch!(fixture, issue.branch_name, "exact remote continuation\n")
    legacy_workspace = Path.join(fixture.workspace_root, issue.identifier)

    cmd!("git", ["clone", fixture.remote, legacy_workspace])
    configure_identity!(legacy_workspace)
    git!(legacy_workspace, ["fetch", "origin", "refs/heads/#{issue.branch_name}"])
    git!(legacy_workspace, ["switch", "-c", issue.branch_name, remote_sha])

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: fixture.workspace_root)

    assert {:ok, preparation} = Workspace.prepare_for_issue(issue)

    assert %{
             path: workspace,
             created_now: false,
             readiness_state:
               %{
                 provenance: :legacy,
                 phase: :unverified
               } = legacy_state
           } = preparation

    assert {:ok,
            %Receipt{
              classification: :continuation,
              head_sha: ^remote_sha
            } = receipt} =
             ReadinessGate.check(workspace, issue, workspace_readiness_state: legacy_state)

    assert :ok = Workspace.mark_readiness_ready(preparation, issue, receipt)

    assert {:ok, %{readiness_state: %{provenance: :legacy, phase: :ready}}} =
             Workspace.prepare_for_issue(issue)
  end

  test "legacy state accepts an exact local continuation without a remote and blocks ambiguous remote evidence" do
    fixture = git_fixture!("legacy-unverified")
    issue = issue("ARO-304", "codex/aro-304")
    legacy_workspace = Path.join(fixture.workspace_root, issue.identifier)

    cmd!("git", ["clone", fixture.remote, legacy_workspace])
    configure_identity!(legacy_workspace)
    git!(legacy_workspace, ["switch", "-c", issue.branch_name])

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: fixture.workspace_root)

    assert {:ok, preparation} = Workspace.prepare_for_issue(issue)

    assert %{
             path: workspace,
             readiness_state:
               %{
                 provenance: :legacy,
                 phase: :unverified
               } = legacy_state
           } = preparation

    local_sha = git!(workspace, ["rev-parse", "HEAD"])

    assert {:ok,
            %Receipt{
              classification: :continuation,
              issue_branch: "codex/aro-304",
              head_sha: ^local_sha
            }} =
             ReadinessGate.check(workspace, issue, workspace_readiness_state: legacy_state)

    git!(workspace, ["switch", "main"])

    assert {:error, %Failure{code: :legacy_workspace_provenance_unverified}} =
             ReadinessGate.check(workspace, issue, workspace_readiness_state: legacy_state)

    git!(workspace, ["switch", issue.branch_name])

    issue_ref = "refs/heads/#{issue.branch_name}"
    other_sha = String.duplicate("b", 40)

    ambiguous_runner = fn
      ["ls-remote", "--heads", "origin", ^issue_ref] ->
        {:ok, "#{@sha}\t#{issue_ref}\n#{other_sha}\t#{issue_ref}\n"}

      args ->
        Workspace.run_git_command(workspace, args)
    end

    assert {:error, %Failure{code: :branch_head_ambiguous}} =
             ReadinessGate.check(workspace, issue,
               workspace_readiness_state: legacy_state,
               command_runner: ambiguous_runner
             )
  end

  test "readiness persistence rejects a branch or HEAD changed after the gate receipt" do
    cases = [
      {"branch", fn workspace, _issue -> git!(workspace, ["switch", "main"]) end},
      {"head",
       fn workspace, _issue ->
         File.write!(Path.join(workspace, "concurrent.txt"), "preserve\n")
         git!(workspace, ["add", "concurrent.txt"])
         git!(workspace, ["commit", "-m", "concurrent persistence change"])
       end}
    ]

    Enum.with_index(cases, 1)
    |> Enum.each(fn {{name, mutate}, index} ->
      fixture = git_fixture!("persist-#{index}")
      issue = issue("ARO-306-#{index}", "codex/aro-306-#{index}")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: fixture.workspace_root,
        hook_after_create: "git clone #{fixture.remote} ."
      )

      assert {:ok, %{path: workspace, readiness_state: state} = preparation} =
               Workspace.prepare_for_issue(issue)

      configure_identity!(workspace)

      assert {:ok, %Receipt{} = receipt} =
               ReadinessGate.check(workspace, issue, workspace_readiness_state: state)

      mutate.(workspace, issue)

      assert {:error, {:workspace_changed_before_readiness_persist, ^workspace, detail}} =
               Workspace.mark_readiness_ready(preparation, issue, receipt),
             name

      assert detail =~ "expected #{receipt.issue_branch}@#{receipt.head_sha}", name
      assert {:ok, %{readiness_state: %{phase: :unverified}}} = Workspace.prepare_for_issue(issue)
    end)
  end

  test "SSH workspace state uses the same durable state machine across preparations and removal" do
    test_root = temporary_root!("ssh-state")
    bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(bin_dir, "ssh")
    workspace_root = Path.join(test_root, "remote-workspaces")
    issue = issue("ARO-305", "codex/aro-305")
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)
    File.mkdir_p!(bin_dir)

    File.write!(fake_ssh, """
    #!/bin/sh
    remote_command=''
    for argument in "$@"; do
      remote_command="$argument"
    done
    exec /bin/sh -c "$remote_command"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      worker_ssh_hosts: ["worker-state"]
    )

    assert {:ok,
            %{
              path: workspace,
              created_now: true,
              readiness_state:
                %{
                  provenance: :created,
                  phase: :unverified
                } = initial_state
            } = preparation} = Workspace.prepare_for_issue(issue, "worker-state")

    assert {:ok,
            %{
              path: ^workspace,
              created_now: false,
              readiness_state: ^initial_state
            }} = Workspace.prepare_for_issue(issue, "worker-state")

    assert :ok =
             Workspace.mark_readiness_ready(
               preparation,
               issue,
               readiness_receipt(issue),
               "worker-state",
               command_runner: readiness_checkout_runner(issue)
             )

    assert {:ok,
            %{
              path: workspace,
              readiness_state: %{
                provenance: :created,
                phase: :ready,
                verified_head_sha: @sha
              }
            }} = Workspace.prepare_for_issue(issue, "worker-state")

    state_path = Workspace.readiness_state_path(workspace)
    assert File.regular?(state_path)
    assert {:ok, []} = Workspace.remove(workspace, "worker-state")
    refute File.exists?(workspace)
    refute File.exists?(state_path)
  end

  defp issue(identifier, branch_name) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Workspace state for #{identifier}",
      description: "Exercise durable readiness state",
      state: "In Progress",
      branch_name: branch_name,
      readiness_base: :canonical,
      labels: []
    }
  end

  defp readiness_receipt(issue) do
    canonical = %GitReceipt{
      source: :canonical_default,
      ref: "refs/heads/main",
      branch: "main",
      advertised_sha: @sha,
      fetched_sha: @sha
    }

    %Receipt{
      classification: :independent_new,
      issue_branch: issue.branch_name,
      head_sha: @sha,
      canonical: canonical,
      upstream: nil
    }
  end

  defp readiness_checkout_runner(issue) do
    fn
      ["branch", "--show-current"] -> {:ok, issue.branch_name <> "\n"}
      ["check-ref-format", "--branch", branch] -> {:ok, branch <> "\n"}
      ["rev-parse", "--verify", "HEAD^{commit}"] -> {:ok, @sha <> "\n"}
    end
  end

  defp temporary_root!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-readiness-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp git_fixture!(suffix) do
    root = temporary_root!(suffix)
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

    %{root: root, remote: remote, seed: seed, workspace_root: workspace_root}
  end

  defp push_branch!(fixture, branch, contents) do
    git!(fixture.seed, ["switch", "-c", branch])
    filename = String.replace(branch, "/", "-") <> ".txt"
    File.write!(Path.join(fixture.seed, filename), contents)
    git!(fixture.seed, ["add", filename])
    git!(fixture.seed, ["commit", "-m", "add #{branch}"])
    git!(fixture.seed, ["push", "origin", branch])
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
end
