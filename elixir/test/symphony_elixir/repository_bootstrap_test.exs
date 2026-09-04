defmodule SymphonyElixir.RepositoryBootstrapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubCredentialResolver.Credential
  alias SymphonyElixir.{ProjectExecutionContext, RepositoryBootstrap}

  @head String.duplicate("a", 40)
  @secret "bootstrap-secret-sentinel"

  test "failed or malformed cleanup cannot authorize a transport retry" do
    for result <- [{:error, :eacces, @secret}, {:error, @secret}, :invalid] do
      assert {:error, :repository_rollback_failed} =
               RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(),
                 command_runner: fn args, _, _ ->
                   if "fetch" in args, do: {:error, :timeout}, else: {:ok, ""}
                 end,
                 cleanup: fn _, _, _, _ -> result end
               )
    end
  end

  test "new workspace is bootstrapped at the verified canonical head without token arguments" do
    parent = self()

    runner = fn args, credential, runtime ->
      send(parent, {:bootstrap, args, credential.token, runtime[:worker_host]})
      {:ok, ""}
    end

    assert :ok =
             RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(), command_runner: runner)

    assert_receive {:bootstrap, ["init", "--initial-branch", "main"], @secret, nil}
    assert_receive {:bootstrap, ["remote", "add", "origin", "https://github.com/aroakpm-svg/aroak-central-brain.git"], @secret, nil}
    assert_receive {:bootstrap, ["-c", "http.followRedirects=false", "fetch", "--no-tags", "--prune", "origin", "refs/heads/main:refs/remotes/origin/main"], @secret, nil}
    assert_receive {:bootstrap, ["config", "--local", "core.autocrlf", "false"], @secret, nil}
    assert_receive {:bootstrap, ["checkout", "-B", "main", @head], @secret, nil}
  end

  test "reused workspace is not bootstrapped" do
    runner = fn _args, _credential, _runtime -> flunk("reused checkout must not bootstrap") end
    assert :ok = RepositoryBootstrap.ensure(context(), preparation(false), credential(), authority(), command_runner: runner)
  end

  test "fetch transport failures and timeouts are transient after exact cleanup" do
    for failure <- [
          {:git_command_failed, "git fetch", 128, "connection reset " <> @secret},
          {:git_command_failed, "git fetch", "connection lost " <> @secret},
          {:workspace_hook_timeout, "git fetch", 100},
          :timeout
        ] do
      runner = fn args, _, _ ->
        if "fetch" in args, do: {:error, failure}, else: {:ok, ""}
      end

      result =
        RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(),
          command_runner: runner,
          cleanup: fn path, host, _, attestation ->
            send(self(), {:cleaned, path, host, attestation})
            :ok
          end
        )

      assert result == {:error, :repository_bootstrap_unavailable}
      refute inspect(result) =~ @secret
      assert_receive {:cleaned, "/workers/central-brain/ARO-196", nil, %{id: "workspace"}}
      refute_received {:cleaned, _, _, _}
    end
  end

  test "local command failures remain permanent" do
    for failed_command <- ["init", "remote", "config", "checkout"] do
      assert {:error, :repository_bootstrap_failed} =
               RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(),
                 command_runner: fn args, _, _ ->
                   failure = {:error, {:git_command_failed, failed_command, 128, @secret}}
                   if hd(args) == failed_command, do: failure, else: {:ok, ""}
                 end,
                 cleanup: fn _, _, _, _ -> :ok end
               )
    end
  end

  test "invalid fetch results and credential failures remain permanent" do
    for failure <- [{:error, :invalid_credential_environment}, {:error, :subprocess_home_unavailable}, :invalid] do
      assert {:error, :repository_bootstrap_failed} =
               RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(),
                 command_runner: fn args, _, _ -> if "fetch" in args, do: failure, else: {:ok, ""} end,
                 cleanup: fn _, _, _, _ -> :ok end
               )
    end
  end

  test "Orchestrator forwards the selected remote bootstrap boundary through to materialization" do
    runner = fn args, credential, runtime ->
      assert credential.token == @secret
      refute inspect(args) =~ @secret
      assert runtime[:worker_host] == "han-wsl"
      send(self(), {:remote_command, hd(args)})
      {:ok, ""}
    end

    options =
      SymphonyElixir.Orchestrator.agent_runner_options_for_test(
        [repository_bootstrap_command_runner: runner],
        worker_host: "han-wsl"
      )

    assert :ok =
             RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(),
               worker_host: options[:worker_host],
               command_runner: options[:repository_bootstrap_command_runner],
               cleanup: fn _, _, _, _ -> :ok end
             )

    assert_receive {:remote_command, "checkout"}
  end

  test "remote bootstrap requires worker runner and failed bootstrap invokes bounded cleanup" do
    parent = self()

    cleanup = fn workspace, worker_host, received_context, attestation ->
      send(parent, {:cleanup, workspace, worker_host, received_context, attestation})
      :ok
    end

    assert {:error, :repository_bootstrap_failed} =
             RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(),
               worker_host: "han-wsl",
               cleanup: cleanup
             )

    assert_receive {:cleanup, "/workers/central-brain/ARO-196", "han-wsl", %ProjectExecutionContext{}, %{id: "workspace"}}
  end

  test "failed commands stop bootstrap and clean exactly the attested fresh workspace" do
    for result <- [:error, :raise, :throw] do
      runner = fn _, _, _ ->
        case result do
          :error -> {:error, @secret}
          :raise -> raise @secret
          :throw -> throw(@secret)
        end
      end

      assert {:error, :repository_bootstrap_failed} =
               RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(),
                 command_runner: runner,
                 cleanup: fn path, host, received, attestation ->
                   send(self(), {:failed_cleanup, path, host, received == context(), attestation})
                   :ok
                 end
               )

      assert_receive {:failed_cleanup, "/workers/central-brain/ARO-196", nil, true, %{id: "workspace"}}
      refute_received {:failed_cleanup, _, _, _, _}
    end
  end

  test "malformed authority and input cannot start bootstrap and cleanup failures stay contained" do
    for authority <- [%{}, %{default_branch: "other", head_sha: @head}, %{default_branch: "main", head_sha: "bad"}] do
      assert {:error, :repository_rollback_failed} =
               RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority, command_runner: fn _, _, _ -> flunk("invalid authority reached Git") end, cleanup: :invalid)
    end

    assert {:error, :repository_bootstrap_failed} = RepositoryBootstrap.ensure(nil, nil, nil, nil, nil)
  end

  test "native bootstrap refuses a workspace without matching ownership before issuing Git commands" do
    assert {:error, :repository_rollback_failed} = RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(), [])
  end

  test "a cleanup callback crash is bounded and must not cause a second deletion attempt" do
    for failure <- [:raise, :throw] do
      assert {:error, :repository_rollback_failed} =
               RepositoryBootstrap.ensure(context(), preparation(true), credential(), authority(),
                 command_runner: fn _, _, _ -> {:error, :failed} end,
                 cleanup: fn _, _, _, _ ->
                   send(self(), :cleanup_attempt)
                   if failure == :raise, do: raise(@secret), else: throw(@secret)
                 end
               )

      assert_receive :cleanup_attempt
      refute_received :cleanup_attempt
    end
  end

  defp preparation(created?) do
    %{
      path: "/workers/central-brain/ARO-196",
      created_now: created?,
      workspace_attestation: %{id: "workspace"},
      private_home_capability: nil
    }
  end

  defp authority, do: %{head_sha: @head, default_branch: "main"}
  defp credential, do: %Credential{credential_ref: "github-central-brain", token: @secret}

  defp context do
    %ProjectExecutionContext{
      issue_id: "issue-196",
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
end
