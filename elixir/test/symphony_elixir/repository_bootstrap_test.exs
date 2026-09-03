defmodule SymphonyElixir.RepositoryBootstrapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubCredentialResolver.Credential
  alias SymphonyElixir.{ProjectExecutionContext, RepositoryBootstrap}

  @head String.duplicate("a", 40)
  @secret "bootstrap-secret-sentinel"

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
