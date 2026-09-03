defmodule SymphonyElixir.GitCheckoutPreflightTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.GitCheckoutPreflight
  alias SymphonyElixir.GitHubCredentialResolver.Credential
  alias SymphonyElixir.ProjectExecutionContext

  @head String.duplicate("a", 40)
  @other_head String.duplicate("b", 40)
  @secret "github_pat_TASK4_SECRET_SENTINEL"

  test "accepts an exact HTTPS checkout and returns only repository branch and head" do
    {workspace, opts} = successful_seams()

    assert {:ok,
            %{
              repository: "aroakpm-svg/aroak-central-brain",
              branch: "main",
              head: @head
            } = receipt} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)

    assert Map.keys(receipt) |> Enum.sort() == [:branch, :head, :repository]
    refute inspect(receipt) =~ @secret
  end

  test "canonicalizes GitHub SSH origins" do
    for origin <- [
          "git@github.com:aroakpm-svg/aroak-central-brain.git\n",
          "ssh://git@github.com/aroakpm-svg/aroak-central-brain.git\n"
        ] do
      {workspace, opts} = successful_seams(origin: origin)
      assert {:ok, _receipt} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "rejects wrong non-GitHub and malformed origins" do
    for origin <- [
          "https://github.com/aroakpm-svg/aroak-project-management.git\n",
          "https://example.com/aroakpm-svg/aroak-central-brain.git\n",
          "not a remote\n"
        ] do
      {workspace, opts} = successful_seams(origin: origin)

      assert {:error, :git_remote_mismatch} =
               GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "rejects wrong branch, local head, and changed remote head" do
    cases = [
      {[branch: "release\n"], :git_branch_mismatch},
      {[local_head: @other_head <> "\n"], :git_checkout_mismatch},
      {[remote_head: @other_head <> "\trefs/heads/main\n"], :github_remote_head_changed}
    ]

    for {overrides, expected} <- cases do
      {workspace, opts} = successful_seams(overrides)
      assert {:error, ^expected} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "rejects a workspace other than the exact namespaced issue checkout" do
    {_workspace, opts} = successful_seams()

    assert {:error, :git_checkout_mismatch} =
             GitCheckoutPreflight.check(context(), "/unexpected/workspace", credential(), opts)
  end

  test "fails closed for missing unsafe and unwritable Git metadata" do
    for {metadata_result, expected} <- [
          {{:error, :enoent}, :git_metadata_missing},
          {{:ok, :symlink}, :git_metadata_unsafe},
          {{:ok, :reparse}, :git_metadata_unsafe},
          {{:ok, :directory}, :git_metadata_unwritable}
        ] do
      probe = if expected == :git_metadata_unwritable, do: fn _path -> {:error, :eacces} end, else: fn _ -> :ok end
      {workspace, opts} = successful_seams(metadata_result: metadata_result, metadata_probe: probe)
      assert {:error, ^expected} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "selects the actual local WSL or SSH worker runner and never puts credential in arguments" do
    for worker_host <- [nil, "wsl://Ubuntu", "worker.example"] do
      parent = self()

      runner = fn args, %Credential{token: token}, runtime ->
        send(parent, {:ran, args, token == @secret, runtime[:worker_host]})
        command_result(args)
      end

      {workspace, opts} = successful_seams(worker_host: worker_host, command_runner: runner)
      assert {:ok, _receipt} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)

      for _ <- 1..4 do
        assert_receive {:ran, args, true, ^worker_host}
        refute inspect(args) =~ @secret
      end
    end
  end

  test "the real metadata probe removes its bounded artifact on success" do
    root = temporary_root!()
    git_dir = Path.join(root, ".git")
    File.mkdir_p!(git_dir)
    workspace_root = root |> Path.dirname() |> Path.dirname()

    {workspace, opts} =
      successful_seams(
        workspace: root,
        workspace_root: workspace_root,
        metadata_inspector: nil,
        metadata_probe: nil
      )

    assert {:ok, _receipt} = GitCheckoutPreflight.check(context_for_workspace(root), workspace, credential(), opts)
    assert File.ls!(git_dir) == []
  end

  test "probe cleanup runs when the injected probe raises and failures never expose secrets" do
    root = temporary_root!()
    File.mkdir_p!(Path.join(root, ".git"))
    workspace_root = root |> Path.dirname() |> Path.dirname()
    parent = self()

    probe = fn path ->
      File.write!(path, "")
      send(parent, {:probe_path, path})
      raise @secret
    end

    {workspace, opts} =
      successful_seams(
        workspace: root,
        workspace_root: workspace_root,
        metadata_inspector: nil,
        metadata_probe: probe
      )

    log =
      capture_log(fn ->
        assert {:error, :git_metadata_unwritable} =
                 GitCheckoutPreflight.check(context(), workspace, credential(), opts)
      end)

    assert_receive {:probe_path, probe_path}
    refute File.exists?(probe_path)
    refute log =~ @secret
  end

  test "rejects a credential bound to another profile without exposing it" do
    {workspace, opts} = successful_seams()
    other = %Credential{credential_ref: "github-project-management", token: @secret}

    assert {:error, :git_checkout_invalid} =
             GitCheckoutPreflight.check(context(), workspace, other, opts)
  end

  defp successful_seams(overrides \\ []) do
    workspace = Keyword.get(overrides, :workspace, "/runtime/workspaces/central-brain/ARO-196")

    runner =
      Keyword.get(overrides, :command_runner, fn args, _credential, _runtime ->
        command_result(args, overrides)
      end)

    opts = [
      expected_head_sha: @head,
      workspace_root: Keyword.get(overrides, :workspace_root, "/runtime/workspaces"),
      worker_host: Keyword.get(overrides, :worker_host),
      command_runner: runner,
      metadata_inspector: Keyword.get(overrides, :metadata_inspector, fn _ -> Keyword.get(overrides, :metadata_result, {:ok, :directory}) end),
      metadata_probe: Keyword.get(overrides, :metadata_probe, fn _ -> :ok end)
    ]

    {workspace, opts}
  end

  defp command_result(args, overrides \\ []) do
    case args do
      ["remote", "get-url", "origin"] -> {:ok, Keyword.get(overrides, :origin, "https://github.com/aroakpm-svg/aroak-central-brain.git\n")}
      ["branch", "--show-current"] -> {:ok, Keyword.get(overrides, :branch, "main\n")}
      ["rev-parse", "--verify", "HEAD^{commit}"] -> {:ok, Keyword.get(overrides, :local_head, @head <> "\n")}
      ["ls-remote", "--heads", "origin", "refs/heads/main"] -> {:ok, Keyword.get(overrides, :remote_head, @head <> "\trefs/heads/main\n")}
    end
  end

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

  defp context_for_workspace(root) do
    root
    |> Path.basename()
    |> then(fn issue_identifier ->
      %{
        context()
        | issue_identifier: issue_identifier,
          workspace_namespace: Path.basename(Path.dirname(root))
      }
    end)
  end

  defp credential, do: %Credential{credential_ref: "github-central-brain", token: @secret}

  defp temporary_root! do
    base = Path.join(System.tmp_dir!(), "task4-workspaces-#{System.unique_integer([:positive])}")
    root = Path.join([base, "central-brain", "ARO-196"])
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(base) end)
    root
  end
end
