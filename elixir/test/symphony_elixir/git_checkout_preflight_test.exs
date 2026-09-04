defmodule SymphonyElixir.GitCheckoutPreflightTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.GitCheckoutPreflight
  alias SymphonyElixir.GitHubCredentialResolver.Credential
  alias SymphonyElixir.ProjectExecutionContext

  @head String.duplicate("a", 40)
  @other_head String.duplicate("b", 40)
  @secret "github_pat_TASK4_SECRET_SENTINEL"

  test "all push destinations must match the selected repository" do
    canonical = "https://github.com/aroakpm-svg/aroak-central-brain.git"
    other = "https://github.com/aroakpm-svg/aroak-project-management.git"

    for urls <- [other, canonical <> "\n" <> other, "", "git@github.com:wrong/repo.git"] do
      {workspace, opts} = successful_seams(push_urls: urls)
      assert {:error, :git_remote_mismatch} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "all effective fetch and push URLs may identify the same canonical repository" do
    canonical = "https://github.com/aroakpm-svg/aroak-central-brain.git"
    other = "https://github.com/aroakpm-svg/aroak-project-management.git"
    {workspace, opts} = successful_seams(origin: canonical <> "\n" <> other)
    assert {:error, :git_remote_mismatch} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)

    for urls <- [canonical, canonical <> "\r\n" <> String.trim_trailing(canonical, ".git")] do
      {workspace, opts} = successful_seams(origin: urls, push_urls: urls)
      assert {:ok, _receipt} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "unreadable push destinations fail before remote probes without exposing errors" do
    runner = fn
      ["remote", "get-url", "--push", "--all", "origin"], _, _ -> {:error, @secret}
      ["ls-remote" | _], _, _ -> flunk("unverified push destinations reached a remote probe")
      args, _, _ -> command_result(args)
    end

    {workspace, opts} = successful_seams(command_runner: runner)
    assert {:error, :git_checkout_invalid} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
  end

  test "effective Git push URLs include multiple pushurl values and pushInsteadOf rewrites" do
    canonical = "https://github.com/aroakpm-svg/aroak-central-brain.git"
    other = "https://github.com/aroakpm-svg/aroak-project-management.git"

    for settings <- [
          [{"remote.origin.pushurl", other}],
          [{"remote.origin.pushurl", canonical}, {"remote.origin.pushurl", other}],
          [{"url.#{other}.pushInsteadOf", canonical}]
        ] do
      workspace = temporary_root!()
      root = workspace |> Path.dirname() |> Path.dirname()
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "-b", "main"], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", workspace, "remote", "add", "origin", canonical])

      Enum.each(settings, fn {key, value} ->
        {_, 0} = System.cmd("git", ["-C", workspace, "config", "--add", key, value])
      end)

      {:ok, environment} = SymphonyElixir.GitCredentialEnvironment.build(credential())

      runner = fn
        ["remote", "get-url" | _] = args, _, _ ->
          Workspace.run_git_command(workspace, args, nil, execution_context: context(), env: environment)

        args, _, _ ->
          command_result(args)
      end

      {_, opts} = successful_seams(workspace: workspace, workspace_root: root, command_runner: runner)
      assert {:error, :git_remote_mismatch} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "remote probe execution failures are retryable but invalid evidence remains permanent" do
    for failure <- [
          {:git_command_failed, "git ls-remote", 128, @secret},
          {:git_command_failed, "git ls-remote", @secret},
          {:workspace_hook_timeout, "git ls-remote", 100},
          :timeout
        ] do
      runner = fn
        ["ls-remote" | _], _, _ -> {:error, failure}
        args, _, _ -> command_result(args)
      end

      {workspace, opts} = successful_seams(command_runner: runner)
      assert {:error, :github_unavailable} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end

    invalid_results = [{:error, :invalid_credential_environment}, {:error, :subprocess_home_unavailable}]

    for result <- invalid_results ++ [{:ok, nil}, :invalid] do
      runner = fn
        ["ls-remote" | _], _, _ -> result
        args, _, _ -> command_result(args)
      end

      {workspace, opts} = successful_seams(command_runner: runner)
      assert {:error, :git_checkout_invalid} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "credential-bearing Git commands cannot inherit diagnostics or shell startup hooks" do
    workspace = temporary_root!()
    root = workspace |> Path.dirname() |> Path.dirname()
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    trace = Path.join(root, "trace.json")
    startup = Path.join(root, "startup.sh")
    marker = Path.join(root, "startup.marker")
    File.write!(startup, "printf started > '#{String.replace(marker, "\\", "/")}'\n")

    ambient = %{
      "GIT_TRACE2_EVENT" => trace,
      "GIT_TRACE2_ENV_VARS" => "GH_TOKEN",
      "GIT_TRACE" => Path.join(root, "git.trace"),
      "BASH_ENV" => startup,
      "ENV" => startup
    }

    previous = Map.new(ambient, fn {key, _} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env(ambient)
    {:ok, environment} = SymphonyElixir.GitCredentialEnvironment.build(credential())
    opts = [execution_context: context(), env: environment]
    assert {:ok, output} = Workspace.run_git_command(workspace, ["--version"], nil, opts)
    assert output =~ "git version"
    trace_output = if File.exists?(trace), do: File.read!(trace), else: ""
    leaked? = String.contains?(trace_output, @secret)
    refute leaked?, "Git diagnostics persisted the synthetic credential"
    refute File.exists?(trace)
    refute File.exists?(Path.join(root, "git.trace"))

    assert {:ok, _} = Workspace.run_git_command(workspace, ["-c", "alias.startup=!sh -c true", "startup"], nil, opts)
    refute File.exists?(marker)
  end

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

  test "rejects SSH origins before any network command can use ambient SSH keys" do
    for origin <- [
          "git@github.com:aroakpm-svg/aroak-central-brain.git\n",
          "ssh://git@github.com/aroakpm-svg/aroak-central-brain.git\n"
        ] do
      runner = fn
        ["remote", "get-url", "--all", "origin"], _, _ -> {:ok, origin}
        args, _, _ -> flunk("SSH origin reached another Git command: #{inspect(args)}")
      end

      {workspace, opts} = successful_seams(command_runner: runner)
      assert {:error, :git_remote_mismatch} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
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

  test "reused workspace accepts only the exact issue branch without binding local head to canonical" do
    {workspace, opts} = successful_seams(branch: "codex/aro-196\n", local_head: @other_head <> "\n")

    assert {:ok, %{branch: "codex/aro-196"}} =
             GitCheckoutPreflight.check(
               context(),
               workspace,
               credential(),
               opts
               |> Keyword.put(:created_now, false)
               |> Keyword.put(:expected_issue_branch, "codex/aro-196")
             )

    assert {:error, :git_branch_mismatch} =
             GitCheckoutPreflight.check(
               context(),
               workspace,
               credential(),
               opts
               |> Keyword.put(:created_now, false)
               |> Keyword.put(:expected_issue_branch, "codex/other")
             )
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

      overrides =
        if worker_host do
          [
            worker_host: worker_host,
            command_runner: runner,
            workspace_attestor: remote_attestor(),
            workspace_attestation: remote_attestation(),
            workspace_guard: remote_workspace_guard(),
            metadata_inspector: remote_metadata_inspector(),
            metadata_probe: remote_metadata_probe()
          ]
        else
          [worker_host: worker_host, command_runner: runner]
        end

      {workspace, opts} = successful_seams(overrides)
      assert {:ok, _receipt} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)

      for _ <- 1..5 do
        assert_receive {:ran, args, true, ^worker_host}
        refute inspect(args) =~ @secret
      end
    end
  end

  test "remote mode never falls back to controller workspace or metadata checks" do
    parent = self()

    runner = fn _args, _credential, _runtime ->
      send(parent, :command_ran)
      {:ok, "unexpected"}
    end

    {workspace, opts} =
      successful_seams(
        worker_host: "worker.example",
        command_runner: runner,
        metadata_inspector: nil,
        metadata_probe: nil
      )

    assert {:error, :git_checkout_mismatch} =
             GitCheckoutPreflight.check(context(), workspace, credential(), opts)

    refute_received :command_ran
  end

  test "remote mode freshly validates the selected worker attestation" do
    parent = self()

    attestor = fn identifier, worker_host, received_context ->
      send(parent, {:attested, identifier, worker_host, received_context})
      {:ok, remote_attestation()}
    end

    {workspace, opts} =
      successful_seams(
        worker_host: "wsl://Ubuntu",
        workspace_attestor: attestor,
        workspace_attestation: remote_attestation(),
        workspace_guard: remote_workspace_guard(),
        metadata_inspector: remote_metadata_inspector(),
        metadata_probe: remote_metadata_probe()
      )

    assert {:ok, _receipt} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    assert_receive {:attested, "ARO-196", "wsl://Ubuntu", %ProjectExecutionContext{} = received}
    assert received == context()

    changed_attestor = fn _identifier, _worker_host, _context ->
      {:ok, %{remote_attestation() | identity: "changed-worker-identity"}}
    end

    assert {:error, :git_checkout_mismatch} =
             GitCheckoutPreflight.check(
               context(),
               workspace,
               credential(),
               Keyword.put(opts, :workspace_attestor, changed_attestor)
             )
  end

  @tag :windows
  test "production metadata validation rejects a real Windows directory junction" do
    if match?({:win32, _}, :os.type()) do
      base = Path.join(System.tmp_dir!(), "task4-junction-#{System.unique_integer([:positive])}")
      target = Path.join(base, "target")
      junction = Path.join(base, "junction")
      File.mkdir_p!(target)

      on_exit(fn ->
        _ = File.rmdir(junction)
        _ = File.rm_rf(base)
      end)

      {_output, 0} =
        System.cmd(
          "cmd.exe",
          [
            "/d",
            "/c",
            "mklink",
            "/J",
            String.replace(junction, "/", "\\"),
            String.replace(target, "/", "\\")
          ],
          stderr_to_stdout: true
        )

      assert {:error, :unsafe_private_home_path} =
               Workspace.validate_non_reparse_directory_for_worker(junction)
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

  test "invalid boundary inputs and missing heads cannot start Git" do
    {workspace, opts} = successful_seams()
    assert {:error, :git_checkout_invalid} = GitCheckoutPreflight.check(nil, nil, nil, nil)

    for head <- [nil, "bad"] do
      assert {:error, :git_checkout_invalid} = GitCheckoutPreflight.check(context(), workspace, credential(), Keyword.put(opts, :expected_head_sha, head))
    end

    assert {:error, :git_checkout_mismatch} = GitCheckoutPreflight.check(context(), workspace, credential(), Keyword.put(opts, :worker_host, 42))

    for runner <- [nil, :invalid] do
      assert {:error, :git_checkout_invalid} = GitCheckoutPreflight.check(context(), workspace, credential(), Keyword.put(opts, :command_runner, runner))
    end
  end

  test "remote attestor and guard failures cannot fall back to local filesystem or commands" do
    for overrides <- [
          [workspace_attestor: :invalid],
          [workspace_guard: :invalid],
          [workspace_attestor: fn _, _, _ -> raise "synthetic-secret" end],
          [workspace_attestor: fn _, _, _ -> throw("synthetic-secret") end],
          [workspace_guard: fn _, _, _, _ -> raise "synthetic-secret" end],
          [workspace_guard: fn _, _, _, _ -> throw("synthetic-secret") end]
        ] do
      {workspace, opts} =
        successful_seams(
          [
            worker_host: "worker.example",
            workspace_attestation: remote_attestation(),
            workspace_attestor: remote_attestor(),
            workspace_guard: remote_workspace_guard(),
            metadata_inspector: remote_metadata_inspector(),
            metadata_probe: remote_metadata_probe()
          ]
          |> Keyword.merge(overrides)
        )

      assert {:error, reason} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
      assert reason in [:git_checkout_mismatch, :git_checkout_invalid]
    end

    {workspace, opts} =
      successful_seams(
        worker_host: "worker.example",
        workspace_attestation: remote_attestation(),
        workspace_attestor: remote_attestor(),
        workspace_guard: remote_workspace_guard(),
        command_runner: nil
      )

    assert {:error, :git_checkout_invalid} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
  end

  test "Git failures exceptions and non-text outputs cannot become checkout evidence" do
    for runner <- [
          fn _, _, _ -> {:error, "synthetic-secret"} end,
          fn _, _, _ -> raise "synthetic-secret" end,
          fn _, _, _ -> throw("synthetic-secret") end,
          fn _, _, _ -> {:ok, nil} end,
          fn
            ["remote", "get-url" | _], _, _ -> {:ok, "https://github.com/aroakpm-svg/aroak-central-brain.git"}
            _, _, _ -> {:ok, "two\nlines"}
          end
        ] do
      {workspace, opts} = successful_seams(command_runner: runner)
      assert {:error, :git_checkout_invalid} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end

    {workspace, opts} = successful_seams(remote_head: "invalid")
    assert {:error, :github_remote_head_changed} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
  end

  test "invalid metadata adapters and disappearing metadata fail closed without probe artifacts" do
    for overrides <- [
          [metadata_inspector: :invalid],
          [metadata_inspector: fn _ -> raise "synthetic-secret" end],
          [metadata_probe: :invalid],
          [metadata_probe: fn _ -> throw("synthetic-secret") end]
        ] do
      {workspace, opts} = successful_seams(overrides)
      assert {:error, :git_metadata_unwritable} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end

    {workspace, opts} = successful_seams(metadata_inspector: nil)
    assert {:error, :git_metadata_missing} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    {workspace, opts} = successful_seams(metadata_probe: nil)
    assert {:error, :git_metadata_missing} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
  end

  test "remote metadata probes require worker-local success and contain raised or thrown secrets" do
    for probe <- [nil, fn _, _ -> raise "synthetic-secret" end, fn _, _ -> throw("synthetic-secret") end] do
      {workspace, opts} =
        successful_seams(
          worker_host: "worker.example",
          workspace_attestation: remote_attestation(),
          workspace_attestor: remote_attestor(),
          workspace_guard: remote_workspace_guard(),
          metadata_inspector: remote_metadata_inspector(),
          metadata_probe: probe
        )

      assert {:error, :git_metadata_unwritable} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  test "real metadata inspection rejects a file in place of the Git directory" do
    root = temporary_root!()
    File.write!(Path.join(root, ".git"), "gitdir: outside")
    workspace_root = root |> Path.dirname() |> Path.dirname()
    {workspace, opts} = successful_seams(workspace: root, workspace_root: workspace_root, metadata_inspector: nil)
    assert {:error, :git_metadata_unsafe} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
  end

  test "checkout accepts the actual Workspace canonical path below a linked configured root" do
    {actual, linked} = linked_root_fixture!()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: linked)
    assert {:ok, preparation} = Workspace.prepare_for_issue("ARO-196", nil, context(), defer_after_create: true)
    assert {:ok, expected} = SymphonyElixir.PathSafety.canonicalize(Path.join([actual, "central-brain", "ARO-196"]))
    assert preparation.path == expected

    {workspace, opts} =
      successful_seams(
        workspace: preparation.path,
        workspace_root: linked,
        workspace_attestation: preparation.workspace_attestation
      )

    assert {:ok, _receipt} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)

    invalid_attestation_opts = Keyword.put(opts, :workspace_attestation, %{kind: :invalid})

    assert {:error, :git_checkout_mismatch} =
             GitCheckoutPreflight.check(context(), workspace, credential(), invalid_attestation_opts)

    replacement = Path.join(Path.dirname(actual), "replacement")
    File.mkdir_p!(Path.join([replacement, "central-brain", "ARO-196"]))
    if match?({:win32, _}, :os.type()), do: File.rmdir!(linked), else: File.rm!(linked)
    create_directory_link!(replacement, linked)
    assert {:error, :git_checkout_mismatch} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
  end

  test "canonical equality never authorizes redirected namespace or issue directories" do
    for redirected <- [:namespace, :issue] do
      {actual, linked} = linked_root_fixture!()
      outside = Path.join(Path.dirname(actual), "outside")
      File.mkdir_p!(outside)
      expected = Path.join([linked, "central-brain", "ARO-196"])

      if redirected == :namespace do
        File.mkdir_p!(Path.join(outside, "ARO-196"))
        create_directory_link!(outside, Path.join(actual, "central-brain"))
      else
        File.mkdir_p!(Path.join(actual, "central-brain"))
        create_directory_link!(outside, Path.join([actual, "central-brain", "ARO-196"]))
      end

      {workspace, opts} = successful_seams(workspace: expected, workspace_root: linked)
      assert {:error, :git_checkout_mismatch} = GitCheckoutPreflight.check(context(), workspace, credential(), opts)
    end
  end

  defp linked_root_fixture! do
    base = Path.join(System.tmp_dir!(), "checkout-link-#{System.unique_integer([:positive])}")
    actual = Path.join(base, "actual")
    linked = Path.join(base, "linked")
    File.mkdir_p!(actual)
    create_directory_link!(actual, linked)
    on_exit(fn -> File.rm_rf(base) end)
    {actual, linked}
  end

  defp successful_seams(overrides \\ []) do
    workspace = Keyword.get(overrides, :workspace, "/runtime/workspaces/central-brain/ARO-196")

    runner =
      Keyword.get(overrides, :command_runner, fn args, _credential, _runtime ->
        command_result(args, overrides)
      end)

    opts = [
      expected_head_sha: @head,
      created_now: Keyword.get(overrides, :created_now, true),
      expected_issue_branch: Keyword.get(overrides, :expected_issue_branch, "codex/aro-196"),
      workspace_root: Keyword.get(overrides, :workspace_root, "/runtime/workspaces"),
      worker_host: Keyword.get(overrides, :worker_host),
      command_runner: runner,
      workspace_attestor: Keyword.get(overrides, :workspace_attestor),
      workspace_attestation: Keyword.get(overrides, :workspace_attestation),
      workspace_guard: Keyword.get(overrides, :workspace_guard),
      metadata_inspector: Keyword.get(overrides, :metadata_inspector, fn _ -> Keyword.get(overrides, :metadata_result, {:ok, :directory}) end),
      metadata_probe: Keyword.get(overrides, :metadata_probe, fn _ -> :ok end)
    ]

    {workspace, opts}
  end

  defp command_result(args, overrides \\ []) do
    case args do
      ["remote", "get-url", "--all", "origin"] -> {:ok, Keyword.get(overrides, :origin, "https://github.com/aroakpm-svg/aroak-central-brain.git\n")}
      ["remote", "get-url", "--push", "--all", "origin"] -> {:ok, Keyword.get(overrides, :push_urls, "https://github.com/aroakpm-svg/aroak-central-brain.git\n")}
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

  defp remote_attestation do
    %{
      kind: :remote,
      lexical_path: "/runtime/workspaces/central-brain/ARO-196",
      physical_path: "/runtime/workspaces/central-brain/ARO-196",
      identity: "worker-device-and-inode"
    }
  end

  defp remote_attestor do
    fn _identifier, _worker_host, _context -> {:ok, remote_attestation()} end
  end

  defp remote_workspace_guard do
    fn workspace, worker_host, received_context, attestation ->
      if workspace == "/runtime/workspaces/central-brain/ARO-196" and worker_host != nil and
           received_context == context() and attestation == remote_attestation(),
         do: :ok,
         else: {:error, :wrong_boundary}
    end
  end

  defp remote_metadata_inspector do
    fn _path, runtime ->
      if runtime[:worker_host], do: {:ok, :directory}, else: {:error, :wrong_boundary}
    end
  end

  defp remote_metadata_probe do
    fn _path, runtime ->
      if runtime[:worker_host], do: :ok, else: {:error, :wrong_boundary}
    end
  end

  defp temporary_root! do
    base = Path.join(System.tmp_dir!(), "task4-workspaces-#{System.unique_integer([:positive])}")
    root = Path.join([base, "central-brain", "ARO-196"])
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(base) end)
    root
  end
end
