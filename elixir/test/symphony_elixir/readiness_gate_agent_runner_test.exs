defmodule SymphonyElixir.ReadinessGateAgentRunnerTest do
  use SymphonyElixir.TestSupport

  @central_project_id "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec"

  test "post-claim gate freshly verifies authority before checkout and only then returns child env" do
    root = Path.join(System.tmp_dir!(), "aro196-worker-gate-#{System.unique_integer([:positive])}")
    workspace = Path.join([root, "central-brain", "ARO-196"])
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    token = "fresh-worker-#{System.unique_integer([:positive, :monotonic])}"
    preclaim_token = "discarded-preclaim-#{System.unique_integer([:positive, :monotonic])}"
    head = String.duplicate("a", 40)
    context = aro196_context()
    Process.put(:aro196_resolution_count, 1)
    Process.put(:aro196_preclaim_token, preclaim_token)

    source = fn "github-central-brain" ->
      Process.put(:aro196_resolution_count, Process.get(:aro196_resolution_count) + 1)
      Process.put(:aro196_resolved, true)
      {:ok, %{credential_ref: "github-central-brain", token: token, expires_at: nil}}
    end

    request = fn request ->
      assert Process.get(:aro196_resolved)
      assert {"authorization", "Bearer " <> token} in request[:headers]

      response =
        case request[:url] do
          "https://api.github.com/graphql" ->
            %{"data" => %{"viewer" => %{"login" => "aroak-automation[bot]"}}}

          "https://api.github.com/repos/aroakpm-svg/aroak-central-brain" ->
            %{"full_name" => context.repository, "default_branch" => "main", "permissions" => %{"pull" => true, "push" => true}}

          "https://api.github.com/repos/aroakpm-svg/aroak-central-brain/git/ref/heads/main" ->
            Process.put(:aro196_authority_verified, true)
            %{"ref" => "refs/heads/main", "object" => %{"sha" => head}}
        end

      {:ok, %{status: 200, body: response}}
    end

    runner = fn args, credential, _runtime ->
      assert Process.get(:aro196_authority_verified)
      assert credential.token == token

      case args do
        ["remote", "get-url", "origin"] -> {:ok, "https://github.com/aroakpm-svg/aroak-central-brain.git\n"}
        ["branch", "--show-current"] -> {:ok, "main\n"}
        ["rev-parse", "--verify", "HEAD^{commit}"] -> {:ok, head <> "\n"}
        ["ls-remote", "--heads", "origin", "refs/heads/main"] -> {:ok, head <> "\trefs/heads/main\n"}
      end
    end

    assert {:ok, %{"GH_TOKEN" => ^token} = child_environment} =
             AgentRunner.post_claim_gate_for_test(context, workspace,
               credential_source: source,
               expected_actor: "aroak-automation[bot]",
               request_fun: request,
               workspace_root: root,
               git_checkout_command_runner: runner,
               metadata_inspector: fn _path -> {:ok, :directory} end,
               metadata_probe: fn _path -> :ok end
             )

    assert Process.get(:aro196_resolution_count) == 2
    refute token == Process.get(:aro196_preclaim_token)
    assert_validated_child_git_protocol(context, child_environment, root, token)
  end

  test "post-claim remote checkout uses only the selected worker seams" do
    previous_source = Application.get_env(:symphony_elixir, :github_credential_source)
    Application.put_env(:symphony_elixir, :github_credential_source, fn _ -> flunk("controller source ran on worker") end)

    on_exit(fn ->
      if previous_source,
        do: Application.put_env(:symphony_elixir, :github_credential_source, previous_source),
        else: Application.delete_env(:symphony_elixir, :github_credential_source)
    end)

    token = "remote-worker-#{System.unique_integer([:positive, :monotonic])}"
    head = String.duplicate("b", 40)
    context = aro196_context()
    workspace = "/workers/central-brain/ARO-196"
    attestation = %{kind: :remote, path: workspace, identity: "worker-id"}
    gate_opts = canonical_gate_options(token, head)
    controller_request = fn _request -> flunk("controller authority request must not run") end

    runner = fn args, credential, runtime ->
      assert credential.token == token
      assert runtime[:worker_host] == "han-wsl"
      assert runtime[:workspace_attestation] == attestation

      case args do
        ["remote", "get-url", "origin"] -> {:ok, "https://github.com/aroakpm-svg/aroak-central-brain.git\n"}
        ["branch", "--show-current"] -> {:ok, "main\n"}
        ["rev-parse", "--verify", "HEAD^{commit}"] -> {:ok, head <> "\n"}
        ["ls-remote", "--heads", "origin", "refs/heads/main"] -> {:ok, head <> "\trefs/heads/main\n"}
      end
    end

    assert {:ok, %{"GH_TOKEN" => ^token}} =
             AgentRunner.post_claim_gate_for_test(
               context,
               workspace,
               Orchestrator.agent_runner_options_for_test(
                 [
                   worker_credential_source: gate_opts[:credential_source],
                   expected_actor: gate_opts[:expected_actor],
                   request_fun: controller_request,
                   worker_authority_request_fun: gate_opts[:request_fun],
                   workspace_attestor: fn "ARO-196", "han-wsl", ^context -> {:ok, attestation} end,
                   workspace_guard: fn ^workspace, "han-wsl", ^context, ^attestation -> :ok end,
                   git_checkout_command_runner: runner,
                   metadata_inspector: fn _path, runtime ->
                     assert runtime[:worker_host] == "han-wsl"
                     {:ok, :directory}
                   end,
                   metadata_probe: fn _path, runtime ->
                     assert runtime[:worker_host] == "han-wsl"
                     :ok
                   end
                 ],
                 worker_host: "han-wsl",
                 workspace_root: "/workers",
                 workspace_attestation: attestation
               )
             )
  end

  test "post-claim authority failures are bounded and stop before worker checkout" do
    secret = "authority-body-secret-#{System.unique_integer([:positive, :monotonic])}"
    source = fn ref -> {:ok, %{credential_ref: ref, token: secret, expires_at: nil}} end
    request = fn _request -> {:ok, %{status: 403, body: secret}} end
    runner = fn _args, _credential, _runtime -> flunk("checkout must not run") end

    assert {:error, :github_forbidden} =
             AgentRunner.post_claim_gate_for_test(aro196_context(), "unused",
               credential_source: source,
               expected_actor: "aroak-automation[bot]",
               request_fun: request,
               git_checkout_command_runner: runner
             )

    refute inspect(:github_forbidden) =~ secret
  end

  test "remote authority fails closed without a worker request seam and never uses controller HTTP" do
    token = "remote-authority-#{System.unique_integer([:positive, :monotonic])}"
    source = fn ref -> {:ok, %{credential_ref: ref, token: token, expires_at: nil}} end
    controller_request = fn _request -> flunk("controller authority request must not run") end

    assert {:error, :github_authority_invalid} =
             AgentRunner.post_claim_gate_for_test(aro196_context(), "/workers/central-brain/ARO-196",
               worker_host: "han-wsl",
               worker_credential_source: source,
               expected_actor: "aroak-automation[bot]",
               request_fun: controller_request
             )
  end

  test "checkout failure suppresses after_create and finalizes the private home capability" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)
    issue = profiled_issue("ARO-196-CLEAN", "codex/aro-196-clean", "aroakpm-svg/aroak-central-brain")
    marker = Path.join(fixture.root, "after-create-must-not-run.marker")
    private_home = Path.join([fixture.workspace_root, "central-brain", ".symphony-subprocess", "ARO-196-CLEAN-r1"])
    secret = "ghs_postclaim_sentinel_#{System.unique_integer([:positive, :monotonic])}"
    gate_opts = canonical_gate_options(secret, fixture.initial_sha)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      hook_after_create: "printf ran > #{shell_escape(shell_path(marker))}"
    )

    checkout_runner = fn
      ["remote", "get-url", "origin"], _credential, _runtime -> {:ok, "https://github.com/wrong/repository.git\n"}
    end

    assert :ok =
             AgentRunner.run(issue, self(),
               credential_source: gate_opts[:credential_source],
               expected_actor: gate_opts[:expected_actor],
               request_fun: gate_opts[:request_fun],
               repository_bootstrap_command_runner: fn _args, _credential, _runtime -> {:ok, ""} end,
               git_checkout_command_runner: checkout_runner,
               metadata_inspector: fn _path -> {:ok, :directory} end,
               metadata_probe: fn _path -> :ok end
             )

    assert_receive {:agent_hard_blocker, "issue-ARO-196-CLEAN", blocker}
    assert blocker.error == "project credential unavailable reason=git_remote_mismatch"
    assert blocker.kind == {:project_credential_unavailable, :git_remote_mismatch}
    refute inspect(blocker) =~ secret

    {:noreply, blocked_state} =
      Orchestrator.handle_info(
        {:agent_hard_blocker, issue.id, blocker},
        running_orchestrator_state(issue)
      )

    assert blocked_state.blocked[issue.id].error ==
             "project credential unavailable reason=git_remote_mismatch"

    refute inspect(blocked_state) =~ secret
    assert :binary.match(:erlang.term_to_binary(blocked_state), secret) == :nomatch
    refute File.exists?(marker)
    refute File.exists?(private_home)
    refute File.exists?(Path.join([fixture.workspace_root, "central-brain", "ARO-196-CLEAN"]))
  end

  test "an actual transient post-claim credential failure releases into secret-free retry" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)
    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)
    System.put_env("SOURCE_REPO_URL", shell_path(fixture.remote))

    issue =
      profiled_issue(
        "ARO-196-RETRY",
        "codex/aro-196-retry",
        "aroakpm-svg/aroak-central-brain"
      )

    issue_id = issue.id
    secret = "ghs_postclaim_retry_#{System.unique_integer([:positive, :monotonic])}"

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: fixture.workspace_root)

    source = fn ref -> {:ok, %{credential_ref: ref, token: secret, expires_at: nil}} end

    request_fun = fn request ->
      assert {"authorization", "Bearer " <> ^secret} = List.keyfind(request[:headers], "authorization", 0)
      {:error, :timeout}
    end

    log =
      capture_log(fn ->
        assert :ok =
                 AgentRunner.run(issue, self(),
                   credential_source: source,
                   expected_actor: "aroak-automation[bot]",
                   request_fun: request_fun
                 )

        assert_receive {:agent_hard_blocker, ^issue_id, blocker}
        send(self(), {:actual_transient_blocker, blocker})

        {:noreply, retried} =
          Orchestrator.handle_info(
            {:agent_hard_blocker, issue.id, blocker},
            running_orchestrator_state(issue)
          )

        send(self(), {:actual_secret_free_retry, retried})
      end)

    assert_receive {:actual_transient_blocker, blocker}
    assert blocker.kind == {:project_credential_unavailable, :github_unavailable}
    assert blocker.error == "project credential unavailable reason=github_unavailable"
    refute inspect(blocker) =~ secret

    assert_receive {:actual_secret_free_retry, retried}
    refute Map.has_key?(retried.running, issue.id)
    refute Map.has_key?(retried.blocked, issue.id)
    refute MapSet.member?(retried.claimed, issue.id)
    assert retried.retry_attempts[issue.id].ownership == :unowned_backoff
    refute inspect(retried) =~ secret
    assert :binary.match(:erlang.term_to_binary(retried), secret) == :nomatch
    refute log =~ secret
  end

  test "404 post-claim authority blockers do not enter an automatic retry loop" do
    issue = profiled_issue("ARO-196-HIDDEN", "codex/aro-196-hidden", "aroakpm-svg/aroak-central-brain")
    opts = canonical_gate_options("synthetic-404-token", String.duplicate("a", 40))
    opts = Keyword.put(opts, :request_fun, fn _ -> {:ok, %{status: 404, body: "synthetic-404-token"}} end)
    assert :ok = AgentRunner.run(issue, self(), opts)
    assert_receive {:agent_hard_blocker, _, blocker}
    assert blocker.kind == {:project_credential_unavailable, :github_repository_not_allowed}
    {:noreply, state} = Orchestrator.handle_info({:agent_hard_blocker, issue.id, blocker}, running_orchestrator_state(issue))
    assert Map.has_key?(state.blocked, issue.id)
    refute Map.has_key?(state.retry_attempts, issue.id)
    refute inspect(state) =~ "synthetic-404-token"
  end

  test "head drift rolls back a fresh checkout so retry bootstraps again while existing homes and reused work survive" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)
    issue = profiled_issue("ARO-196-DRIFT", "codex/aro-196-drift", "aroakpm-svg/aroak-central-brain")
    workspace = Path.join([fixture.workspace_root, "central-brain", issue.identifier])
    marker = Path.join(fixture.root, "effects.marker")
    token = "synthetic-drift-token"

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      hook_after_create: "printf ran > #{shell_escape(shell_path(marker))}; exit 42"
    )

    assert {:ok, context} = SymphonyElixir.ProjectExecutionContext.from_issue(issue)
    assert {:ok, environment} = SymphonyElixir.SubprocessEnvironment.build(%{}, context)
    paths = SymphonyElixir.SubprocessEnvironment.private_home_paths(context)
    preparation_opts = [env: environment, subprocess_home_paths: paths, defer_after_create: true]
    assert {:ok, preparation} = Workspace.prepare_for_issue(issue, nil, context, preparation_opts)
    assert :ok = Workspace.finalize_private_home_capability(preparation.private_home_capability)
    assert :ok = Workspace.rollback_failed_repository_bootstrap(context, nil, preparation.workspace_attestation)
    assert File.dir?(paths.home)

    bootstrap = real_bootstrap_runner(workspace, fixture.remote, token)
    checkout = real_checkout_runner(workspace, fixture.remote, token)

    drift = fn
      ["ls-remote", "--heads", "origin", "refs/heads/main"], _, _ -> {:ok, String.duplicate("b", 40) <> "\trefs/heads/main\n"}
      args, credential, runtime -> checkout.(args, credential, runtime)
    end

    opts =
      canonical_gate_options(token, fixture.initial_sha) ++
        [
          repository_bootstrap_command_runner: fn args, credential, runtime ->
            if hd(args) == "init", do: send(self(), :fresh_bootstrap)
            bootstrap.(args, credential, runtime)
          end,
          git_checkout_command_runner: drift
        ]

    assert :ok = AgentRunner.run(issue, self(), Orchestrator.agent_runner_options_for_test(opts, []))
    assert_receive :fresh_bootstrap
    assert_receive {:agent_hard_blocker, _, %{kind: {:project_credential_unavailable, :github_remote_head_changed}}}
    refute File.exists?(workspace)
    refute File.exists?(marker)
    assert File.dir?(paths.home)

    retry_opts = Keyword.put(opts, :git_checkout_command_runner, checkout)

    assert_raise RuntimeError, fn ->
      AgentRunner.run(issue, self(), Orchestrator.agent_runner_options_for_test(retry_opts, []))
    end

    assert_receive :fresh_bootstrap
    assert File.read!(marker) == "ran"
    assert File.dir?(Path.join(workspace, ".git"))
    assert File.dir?(paths.home)

    File.write!(Path.join(workspace, "user-work.txt"), "preserve")
    assert :ok = AgentRunner.run(issue, self(), opts)
    assert_receive {:agent_hard_blocker, _, %{kind: {:project_credential_unavailable, :github_remote_head_changed}}}
    refute_received :fresh_bootstrap
    assert File.read!(Path.join(workspace, "user-work.txt")) == "preserve"
    assert File.dir?(paths.home)
  end

  test "credential values emitted by a hook are redacted from failures before truncation" do
    root = Path.join(System.tmp_dir!(), "aro286-hook-redaction-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "ARO-286-REDACT")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    env_key = "ARO286_REDACT_#{System.unique_integer([:positive])}"
    secret_prefix = "opaque-hook-secret-#{System.unique_integer([:positive, :monotonic])}"
    secret = secret_prefix <> "-longer"

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_before_run: "printf '%s' \"$#{env_key}\"; exit 41"
    )

    assert {:error, reason} =
             Workspace.run_before_run_hook(workspace, "ARO-286-REDACT", nil,
               env: %{env_key => secret},
               sensitive_env_values: [secret_prefix, secret]
             )

    assert inspect(reason) =~ "[redacted]"
    refute inspect(reason) =~ secret
    refute inspect(reason) =~ "-longer"
  end

  test "credential-bearing context-aware remote execution fails before SSH" do
    secret = "opaque-remote-secret-#{System.unique_integer([:positive, :monotonic])}"
    issue = profiled_issue("ARO-286-REMOTE", "codex/aro-286-remote", "owner/repository")
    assert {:ok, context} = SymphonyElixir.ProjectExecutionContext.from_issue(issue)

    opts = [
      env: %{"GH_TOKEN" => secret},
      sensitive_env_values: [],
      execution_context: context
    ]

    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :ssh_command_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :ssh_command_runner)
      end
    end)

    test_pid = self()

    Application.put_env(:symphony_elixir, :ssh_command_runner, fn _executable, _args, _command_opts ->
      send(test_pid, :ssh_called)
      {"must not run", 99}
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/workspaces",
      hook_before_run: "echo before",
      hook_after_run: "echo after"
    )

    assert {:error, :remote_credential_environment_unsupported} =
             Workspace.prepare_for_issue(issue, "worker-credential", context, opts)

    assert {:error, :remote_credential_environment_unsupported} =
             Workspace.preflight("/remote/workspaces/ARO-286-REMOTE", issue, "worker-credential", opts)

    assert {:error, :remote_credential_environment_unsupported} =
             Workspace.run_before_run_hook(
               "/remote/workspaces/ARO-286-REMOTE",
               issue,
               "worker-credential",
               opts
             )

    assert {:error, :remote_credential_environment_unsupported} =
             Workspace.run_git_command(
               "/remote/workspaces/ARO-286-REMOTE",
               ["status", "--short"],
               "worker-credential",
               opts
             )

    readiness_state = %Workspace.ReadinessState{
      version: 1,
      provenance: :created,
      phase: :unverified,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_branch: issue.branch_name,
      profile_key: context.profile_key,
      linear_project_id: context.linear_project_id,
      repository: context.repository,
      canonical_branch: context.canonical_branch,
      workspace_namespace: context.workspace_namespace,
      credential_ref: context.credential_ref,
      workspace_path: "/remote/workspaces/ARO-286-REMOTE",
      verified_head_sha: nil
    }

    assert {:error, :remote_credential_environment_unsupported} =
             Workspace.mark_readiness_ready(
               %{path: readiness_state.workspace_path, readiness_state: readiness_state},
               issue,
               %{issue_branch: issue.branch_name, head_sha: String.duplicate("a", 40)},
               "worker-credential",
               opts
             )

    assert :ok =
             Workspace.run_after_run_hook(
               "/remote/workspaces/ARO-286-REMOTE",
               issue,
               "worker-credential",
               opts
             )

    refute_received :ssh_called
  end

  test "unsupported profiled remote topology fails before authority, SSH or local private home" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-remote-private-home-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "remote-shaped-workspaces")
    private_root = Path.join([workspace_root, "central-brain", ".symphony-subprocess"])
    issue = profiled_issue("ARO-286-REMOTE-HOME", "codex/aro-286-remote-home", "aroakpm-svg/aroak-central-brain")
    secret = "opaque-remote-home-#{System.unique_integer([:positive, :monotonic])}"
    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :ssh_command_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :ssh_command_runner)
      end

      File.rm_rf(test_root)
    end)

    test_pid = self()

    Application.put_env(:symphony_elixir, :ssh_command_runner, fn _executable, _args, _command_opts ->
      send(test_pid, :remote_home_ssh_called)
      {"must not run", 99}
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    gate_opts = canonical_gate_options(secret, String.duplicate("a", 40))

    assert_raise RuntimeError, ~r/profiled_ssh_topology_unsupported/, fn ->
      AgentRunner.run(issue, nil,
        worker_host: "worker-credential",
        worker_credential_source: gate_opts[:credential_source],
        expected_actor: gate_opts[:expected_actor],
        request_fun: gate_opts[:request_fun]
      )
    end

    refute File.exists?(workspace_root)
    refute File.exists?(private_root)
    refute_received :remote_home_ssh_called
  end

  test "safe Git defaults ignore ambient helpers and canonical credentials cannot select one" do
    root = Path.join(System.tmp_dir!(), "aro286-git-helper-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    ambient_marker = Path.join(root, "ambient.marker")
    local_marker = Path.join(root, "local.marker")
    selected_marker = Path.join(root, "selected.marker")
    credential_input = Path.join(root, "credential.input")
    credential_output = Path.join(root, "credential.output")
    ambient_config = Path.join(root, "ambient.gitconfig")
    selected_helper = Path.join(root, "selected-helper")
    local_helper = Path.join(root, "local-helper")
    selected_secret = "selected-#{System.unique_integer([:positive, :monotonic])}"
    previous_global_config = System.get_env("GIT_CONFIG_GLOBAL")

    on_exit(fn ->
      restore_env("GIT_CONFIG_GLOBAL", previous_global_config)
      File.rm_rf(root)
    end)

    File.mkdir_p!(workspace)
    cmd!("git", ["init", workspace])
    File.write!(credential_input, "protocol=https\nhost=example.test\n\n")

    File.write!(ambient_config, """
    [credential]
      helper = "!echo ambient > '#{shell_path(ambient_marker)}'; echo username=ambient; echo password=ambient"
    """)

    File.write!(selected_helper, """
    #!/bin/sh
    printf selected > #{shell_escape(shell_path(selected_marker))}
    printf '%s\n' username=selected password=#{selected_secret}
    """)

    File.write!(local_helper, """
    #!/bin/sh
    printf local > #{shell_escape(shell_path(local_marker))}
    printf '%s\n' username=local password=local
    """)

    File.chmod!(selected_helper, 0o755)
    File.chmod!(local_helper, 0o755)
    git!(workspace, ["config", "credential.helper", "!#{shell_path(local_helper)}"])
    System.put_env("GIT_CONFIG_GLOBAL", ambient_config)

    safe_env = %{
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_PARAMETERS" => "'credential.helper='",
      "GIT_CONFIG_GLOBAL" => git_null_device(),
      "GIT_CONFIG_COUNT" => "0",
      "GIT_CONFIG_SYSTEM" => git_null_device(),
      "GIT_TERMINAL_PROMPT" => "0",
      "GCM_INTERACTIVE" => "Never"
    }

    probe =
      "git credential fill < #{shell_escape(shell_path(credential_input))} > #{shell_escape(shell_path(credential_output))}"

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_before_run: probe
    )

    assert {:error, _reason} =
             Workspace.run_before_run_hook(workspace, "ARO-286-GIT-SAFE", nil, env: safe_env)

    refute File.exists?(ambient_marker)
    refute File.exists?(local_marker)
    refute File.exists?(selected_marker)

    refute File.exists?(ambient_marker)
    refute File.exists?(local_marker)
    refute File.exists?(selected_marker)
  end

  test "profile context and its environment reach workspace hooks and Codex runtime settings only" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)
    System.put_env("SOURCE_REPO_URL", shell_path(fixture.remote))

    env_key = "GH_TOKEN"
    env_value = "opaque-#{System.unique_integer([:positive, :monotonic])}"
    previous_gh_token = System.get_env(env_key)
    on_exit(fn -> restore_env(env_key, previous_gh_token) end)
    System.delete_env(env_key)

    ambient_environment = %{
      "GITHUB_TOKEN" => "ambient-github-secret",
      "LINEAR_API_KEY" => "linear-node-secret",
      "NPM_TOKEN" => "npm-node-secret",
      "NODE_AUTH_TOKEN" => "node-auth-secret",
      "NODE_OPTIONS" => "--require=malicious-profile.js",
      "SSH_AUTH_SOCK" => "ambient-agent.sock",
      "SSH_AGENT_PID" => "4242",
      "GIT_SSH_COMMAND" => "ambient-ssh-command",
      "GH_CONFIG_DIR" => "ambient-gh-config"
    }

    previous_environment =
      Map.new(ambient_environment, fn {key, _value} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous_environment, fn {key, value} -> restore_env(key, value) end)
    end)

    Enum.each(ambient_environment, fn {key, value} -> System.put_env(key, value) end)

    issue = %{profiled_issue("ARO-286", "codex/aro-286", "aroakpm-svg/aroak-central-brain") | labels: ["model:gpt-5.5"]}
    after_create_marker = shell_path(Path.join(fixture.root, "profile-after-create.marker"))
    before_run_marker = shell_path(Path.join(fixture.root, "profile-before-run.marker"))
    after_run_marker = shell_path(Path.join(fixture.root, "profile-after-run.marker"))
    ambient_marker = shell_path(Path.join(fixture.root, "profile-ambient.marker"))
    home_marker = shell_path(Path.join(fixture.root, "profile-home.marker"))
    profile_marker = shell_path(Path.join(fixture.root, "malicious-profile.marker"))
    malicious_profile = shell_path(Path.join(fixture.root, "malicious-profile.sh"))
    test_pid = self()

    File.write!(malicious_profile, "printf profile-ran > #{shell_escape(profile_marker)}\n")
    previous_bash_env = System.get_env("BASH_ENV")
    previous_env = System.get_env("ENV")

    on_exit(fn ->
      restore_env("BASH_ENV", previous_bash_env)
      restore_env("ENV", previous_env)
    end)

    System.put_env("BASH_ENV", malicious_profile)
    System.put_env("ENV", malicious_profile)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      codex_executable: "/opt/trusted/codex",
      codex_default_model: "gpt-5.4-mini",
      hook_after_create:
        "git config url.#{shell_escape(shell_path(fixture.remote))}.insteadOf https://github.com/aroakpm-svg/aroak-central-brain.git && " <>
          "printf '%s' \"$#{env_key}\" > #{shell_escape(after_create_marker)}",
      hook_before_run:
        "printf '%s' \"$#{env_key}\" > #{shell_escape(before_run_marker)} && " <>
          ~s/printf '%s|%s|%s|%s|%s|%s|%s|%s' "$GITHUB_TOKEN" "$LINEAR_API_KEY" "$NPM_TOKEN" "$NODE_AUTH_TOKEN" "$SSH_AUTH_SOCK" "$SSH_AGENT_PID" "$GIT_SSH_COMMAND" "$OPENAI_API_KEY" > #{shell_escape(ambient_marker)} && / <>
          "printf '%s' \"$HOME\" > #{shell_escape(home_marker)}",
      hook_after_run: "printf '%s' \"$#{env_key}\" > #{shell_escape(after_run_marker)}"
    )

    gate_opts = canonical_gate_options(env_value, fixture.initial_sha)
    workspace = Path.join([fixture.workspace_root, "central-brain", "ARO-286"])
    bootstrap_runner = real_bootstrap_runner(workspace, fixture.remote, env_value)

    guarded_bootstrap_runner = fn args, credential, runtime ->
      refute File.exists?(after_create_marker)
      bootstrap_runner.(args, credential, runtime)
    end

    codex_session_starter = fn workspace, runtime_opts ->
      send(test_pid, {:codex_runtime_settings, workspace, runtime_opts})
      {:error, :captured_runtime_settings}
    end

    assert_raise RuntimeError, ~r/captured_runtime_settings/, fn ->
      AgentRunner.run(issue, self(),
        credential_source: gate_opts[:credential_source],
        expected_actor: gate_opts[:expected_actor],
        request_fun: gate_opts[:request_fun],
        repository_bootstrap_command_runner: guarded_bootstrap_runner,
        git_checkout_command_runner: real_checkout_runner(workspace, fixture.remote, env_value),
        codex_session_starter: codex_session_starter
      )
    end

    assert_receive {:worker_runtime_info, "issue-ARO-286", %{workspace_path: workspace}}

    assert normalized_path(workspace) ==
             normalized_path(Path.join([fixture.workspace_root, "central-brain", "ARO-286"]))

    assert File.read!(after_create_marker) == env_value
    assert File.read!(before_run_marker) == env_value
    assert File.read!(after_run_marker) == env_value
    assert File.read!(ambient_marker) == "|||||||"
    refute File.exists?(profile_marker)

    private_home = File.read!(home_marker)
    assert private_home != System.user_home!()

    assert normalized_path(private_home) =~
             "/workspaces/central-brain/.symphony-subprocess/aro-286-r1"

    assert_receive {:codex_runtime_settings, ^workspace, runtime_opts}
    capability = runtime_opts[:private_home_capability]
    assert capability
    refute Workspace.private_home_capability_active_for_test?(capability)
    assert runtime_opts[:env][env_key] == env_value
    assert runtime_opts[:env]["OPENAI_API_KEY"] == nil
    assert runtime_opts[:env]["GITHUB_TOKEN"] == false
    assert runtime_opts[:env]["LINEAR_API_KEY"] == false
    assert runtime_opts[:env]["NPM_TOKEN"] == false
    assert runtime_opts[:env]["NODE_AUTH_TOKEN"] == false
    assert runtime_opts[:env]["NODE_OPTIONS"] == false
    assert runtime_opts[:env]["SSH_AUTH_SOCK"] == false
    assert runtime_opts[:env]["SSH_AGENT_PID"] == false
    assert runtime_opts[:env]["GIT_SSH_COMMAND"] == false
    assert runtime_opts[:env]["BASH_ENV"] == false
    assert runtime_opts[:env]["ENV"] == false
    assert runtime_opts[:env]["CODEX_BIN"] == "/opt/trusted/codex"
    assert runtime_opts[:env]["CODEX_DEFAULT_MODEL"] == "gpt-5.5"
    assert runtime_opts[:env]["SYMPHONY_CODEX_MODEL_SOURCE"] == "Linear label model:gpt-5.5"
    assert runtime_opts[:env]["GIT_CONFIG_NOSYSTEM"] == "1"
    assert runtime_opts[:env]["GIT_CONFIG_COUNT"] == "0"
    assert {:ok, context} = SymphonyElixir.ProjectExecutionContext.from_issue(issue)
    assert_validated_child_git_protocol(context, runtime_opts[:env], fixture.root, env_value)
    assert runtime_opts[:env]["GIT_CONFIG_SYSTEM"] == git_null_device()
    assert runtime_opts[:env]["GIT_CONFIG_GLOBAL"] == git_null_device()

    assert normalized_path(runtime_opts[:env]["HOME"]) =~
             "/workspaces/central-brain/.symphony-subprocess/aro-286-r1"

    assert runtime_opts[:env]["GH_CONFIG_DIR"] ==
             Path.join(runtime_opts[:env]["HOME"], "gh")

    assert runtime_opts[:execution_context].profile_key == "central-brain"
    assert runtime_opts[:execution_context].credential_ref == "github-central-brain"
    assert System.get_env(env_key) == nil
    refute inspect(Application.get_all_env(:symphony_elixir)) =~ env_value
  end

  test "credential provider failure reports a sanitized hard blocker before hooks or Codex" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    issue = profiled_issue("ARO-286-BLOCK", "codex/aro-286-block", fixture.remote)
    hook_marker = Path.join(fixture.root, "blocked-hook.marker")
    codex_marker = Path.join(fixture.root, "blocked-codex.marker")
    secret = "opaque-error-#{System.unique_integer([:positive, :monotonic])}"

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      hook_after_create: "printf hook > #{shell_escape(hook_marker)}"
    )

    credential_source = fn "github-central-brain" ->
      raise secret
    end

    codex_session_starter = fn _workspace, _opts ->
      File.write!(codex_marker, "started")
      {:error, :must_not_start}
    end

    assert :ok =
             AgentRunner.run(issue, self(),
               credential_source: credential_source,
               codex_session_starter: codex_session_starter,
               distributed_claim: %{claim_id: "claim-286", generation: 1}
             )

    assert_receive {:agent_hard_blocker, "issue-ARO-286-BLOCK", blocker}
    assert blocker.error == "project credential unavailable reason=credential_resolver_failed"
    refute blocker.error =~ secret
    refute File.exists?(hook_marker)
    refute File.exists?(codex_marker)
  end

  test "multiple model labels report a typed recoverable blocker before credentials or effects" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    issue = %{
      profiled_issue("ARO-286-MODEL", "codex/aro-286-model", fixture.remote)
      | labels: ["model:gpt-5.4", "model:gpt-5.5"]
    }

    assert :ok = AgentRunner.run(issue, self())

    assert_receive {:agent_hard_blocker, "issue-ARO-286-MODEL", blocker}
    assert blocker.kind == {:codex_model_label_conflict, ["model:gpt-5.4", "model:gpt-5.5"]}
    refute File.exists?(Path.join([fixture.workspace_root, "central-brain", "ARO-286-MODEL"]))
  end

  test "stale branch in a fresh workspace hard-blocks before before_run and AppServer" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)
    System.put_env("SOURCE_REPO_URL", shell_path(fixture.remote))

    issue = issue("ARO-201", "codex/aro-201")
    stale_sha = fixture.initial_sha
    live_sha = advance_default!(fixture, "live default advanced\n")
    refute stale_sha == live_sha

    before_run_marker = shell_path(Path.join(fixture.root, "before-run.marker"))
    app_server_marker = shell_path(Path.join(fixture.root, "app-server.marker"))
    after_run_marker = Path.join(fixture.root, "after-run.marker")
    fake_codex = shell_path(Path.join(fixture.root, "fake-codex"))

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

    # A process restart reuses the directory (`created_now: false`). Durable
    # provenance must keep the blocked workspace in the fresh/unverified state.
    assert :ok = AgentRunner.run(issue, self())

    assert_receive {:agent_hard_blocker, "issue-ARO-201", restarted_blocker}
    assert restarted_blocker.error =~ "workspace readiness failed"
    assert restarted_blocker.error =~ "new_issue_branch_already_exists"
    refute File.exists?(before_run_marker)
    refute File.exists?(app_server_marker)
    assert restarted_blocker.workspace_path == blocker.workspace_path
    assert git!(restarted_blocker.workspace_path, ["rev-parse", "HEAD"]) == stale_sha
  end

  test "canonical default as tracker issue branch hard-blocks before before_run and AppServer" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    on_exit(fn -> restore_env("SOURCE_REPO_URL", previous_source_repo_url) end)
    System.put_env("SOURCE_REPO_URL", shell_path(fixture.remote))

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
      hook_after_create: "git clone #{shell_escape(shell_path(fixture.remote))} .",
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
    System.put_env("SOURCE_REPO_URL", shell_path(fixture.remote))

    issue = issue("ARO-202", "codex/aro-202")
    before_run_marker = Path.join(fixture.root, "before-run.marker")
    app_server_marker = Path.join(fixture.root, "app-server.marker")
    previous_before_marker = System.get_env("SYMP_TEST_READINESS_BEFORE_MARKER")
    previous_app_marker = System.get_env("SYMP_TEST_READINESS_APP_MARKER")

    on_exit(fn ->
      restore_env("SYMP_TEST_READINESS_BEFORE_MARKER", previous_before_marker)
      restore_env("SYMP_TEST_READINESS_APP_MARKER", previous_app_marker)
    end)

    System.put_env("SYMP_TEST_READINESS_BEFORE_MARKER", before_run_marker)
    System.put_env("SYMP_TEST_READINESS_APP_MARKER", app_server_marker)
    fake_codex = shell_path(Path.join(fixture.root, "fake-codex"))

    File.write!(fake_codex, """
    #!/bin/sh
    printf launched > "$SYMP_TEST_READINESS_APP_MARKER"
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
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(fake_codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      hook_after_create: "git clone #{shell_escape(shell_path(fixture.remote))} .",
      hook_before_run: ~s(printf before > "$SYMP_TEST_READINESS_BEFORE_MARKER"),
      codex_command: "#{fake_codex} app-server"
    )

    assert {:ok, %{path: workspace, readiness_state: readiness_state} = preparation} =
             Workspace.prepare_for_issue(issue)

    configure_identity!(workspace)

    assert {:ok, readiness_receipt} =
             SymphonyElixir.ReadinessGate.check(workspace, issue, workspace_readiness_state: readiness_state)

    assert :ok = Workspace.mark_readiness_ready(preparation, issue, readiness_receipt)

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

  defp profiled_issue(identifier, branch_name, repository) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Agent readiness for #{identifier}",
      description: "Exercise profile credential isolation",
      state: "In Progress",
      branch_name: branch_name,
      project_id: @central_project_id,
      project_profile: %{
        key: "central-brain",
        linear_project_id: @central_project_id,
        repository: shell_path(repository),
        canonical_branch: "main",
        workspace_namespace: "central-brain",
        credential_ref: "github-central-brain",
        environment: "local_non_production"
      },
      repository: shell_path(repository),
      routing_revision: 1,
      readiness_base: :canonical,
      labels: []
    }
  end

  defp aro196_context do
    %SymphonyElixir.ProjectExecutionContext{
      issue_id: "issue-ARO-196",
      issue_identifier: "ARO-196",
      profile_key: "central-brain",
      linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      repository: "aroakpm-svg/aroak-central-brain",
      canonical_branch: "main",
      workspace_namespace: "central-brain",
      credential_ref: "github-central-brain",
      environment: "local_non_production",
      routing_revision: 1
    }
  end

  defp canonical_gate_options(token, head) do
    source = fn ref -> {:ok, %{credential_ref: ref, token: token, expires_at: nil}} end

    request = fn request ->
      body =
        case request[:url] do
          "https://api.github.com/graphql" ->
            %{"data" => %{"viewer" => %{"login" => "aroak-automation[bot]"}}}

          "https://api.github.com/repos/aroakpm-svg/aroak-central-brain" ->
            %{
              "full_name" => "aroakpm-svg/aroak-central-brain",
              "default_branch" => "main",
              "permissions" => %{"pull" => true, "push" => true}
            }

          "https://api.github.com/repos/aroakpm-svg/aroak-central-brain/git/ref/heads/main" ->
            %{"ref" => "refs/heads/main", "object" => %{"sha" => head}}
        end

      {:ok, %{status: 200, body: body}}
    end

    [credential_source: source, expected_actor: "aroak-automation[bot]", request_fun: request]
  end

  defp running_orchestrator_state(issue) do
    %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: self(),
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          started_at: DateTime.utc_now(),
          retry_attempt: 0,
          distributed_claim: nil
        }
      },
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp assert_validated_child_git_protocol(context, provider_environment, root, token) do
    assert {:ok, child} = SymphonyElixir.SubprocessEnvironment.build(provider_environment, context)
    refute child["HOME"] == System.user_home!()
    marker = Path.join(root, "ambient-helper.marker")
    fake_config = Path.join(root, "synthetic.gitconfig")
    File.write!(fake_config, "[credential]\n\thelper = !printf ambient > '#{shell_path(marker)}'\n")

    safe_child =
      child
      |> Map.put("GIT_CONFIG_GLOBAL", fake_config)
      |> Map.put("GIT_CONFIG_NOSYSTEM", "1")
      |> Map.put("GIT_TERMINAL_PROMPT", "0")
      |> Map.put("GIT_ASKPASS", false)
      |> Map.put("SSH_ASKPASS", false)
      |> Map.put("ENV", false)
      |> Map.put("BASH_ENV", false)

    for {host, accepted?} <- [{"github.com", true}, {"example.com", false}] do
      input = Base.encode64("protocol=https\nhost=#{host}\n\n")

      {output, status} =
        System.cmd("sh", ["-c", "printf '%s' '#{input}' | base64 -d | git credential fill"],
          cd: root,
          env:
            Enum.map(safe_child, fn
              {key, false} -> {key, nil}
              pair -> pair
            end),
          stderr_to_stdout: true
        )

      assert status == 0 == accepted?
      canonical? = String.contains?(output, "password=" <> token)
      assert canonical? == accepted?
    end

    refute File.exists?(marker)
    refute File.exists?(Path.join(child["HOME"], ".git-credentials"))
  end

  defp real_bootstrap_runner(workspace, fixture_remote, expected_token) do
    fn args, credential, _runtime ->
      assert credential.token == expected_token
      refute Enum.any?(args, &String.contains?(&1, expected_token))

      args = bootstrap_fixture_args(args, fixture_remote)

      case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {_output, _status} -> {:error, :git_failed}
      end
    end
  end

  defp bootstrap_fixture_args(args, fixture_remote) do
    if "fetch" in args,
      do: Enum.map(args, &if(&1 == "origin", do: fixture_remote, else: &1)),
      else: args
  end

  defp real_checkout_runner(workspace, fixture_remote, expected_token) do
    fn args, credential, _runtime ->
      assert credential.token == expected_token
      refute Enum.any?(args, &String.contains?(&1, expected_token))

      args =
        case args do
          ["ls-remote", "--heads", "origin", ref] ->
            ["ls-remote", "--heads", fixture_remote, ref]

          other ->
            other
        end

      case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {_output, _status} -> {:error, :git_failed}
      end
    end
  end

  defp git_null_device do
    if match?({:win32, _}, :os.type()), do: "NUL", else: "/dev/null"
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

  defp normalized_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.downcase()
  end
end
