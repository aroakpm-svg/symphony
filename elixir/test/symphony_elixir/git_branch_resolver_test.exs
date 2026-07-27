defmodule SymphonyElixir.GitBranchResolverTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitBranchResolver
  alias SymphonyElixir.GitBranchResolver.{Failure, Receipt}

  @sha String.duplicate("a", 40)
  @moved_sha String.duplicate("b", 40)
  @sha64 String.duplicate("C", 64)

  test "default public APIs use the local Git seam for canonical and explicit heads" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)
    main_sha = fixture.main_sha
    feature_sha = fixture.feature_sha

    assert {:ok,
            %Receipt{
              source: :canonical_default,
              branch: "main",
              fetched_sha: ^main_sha
            }} = GitBranchResolver.resolve(fixture.workspace)

    assert {:ok,
            %Receipt{
              source: :explicit_branch,
              branch: "feature/existing",
              fetched_sha: ^feature_sha
            }} = GitBranchResolver.lookup_branch(fixture.workspace, "feature/existing")
  end

  test "public branch validation rejects every unsafe name shape and non-string input" do
    Enum.each(["main", "release/2026-q3", "codex/ARO_123-fix", "@"], fn branch ->
      assert GitBranchResolver.valid_branch?(branch)
    end)

    Enum.each(
      [
        "",
        "-leading",
        ".hidden",
        "/rooted",
        "trailing/",
        "trailing.",
        "name.lock",
        "@{-1}",
        "bad..name",
        "bad@{name",
        "bad//name",
        "bad\\name",
        "bad name",
        "bad~name",
        "bad^name",
        "bad:name",
        "bad?name",
        "bad*name",
        "bad[name",
        "part/.hidden",
        "part/name.lock/more",
        nil,
        42
      ],
      fn branch -> refute GitBranchResolver.valid_branch?(branch) end
    )

    runner = fn _args -> flunk("invalid branch must fail before invoking Git") end

    assert {:error, %Failure{code: :branch_ref_invalid, command: nil}} =
             GitBranchResolver.lookup_branch("/workspace", "bad..name", command_runner: runner)
  end

  test "public branch validation delegates to Git without evaluating branch text as a shell" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-branch-validation-#{System.unique_integer([:positive])}"
      )

    side_effect = Path.join(test_root, "must-not-exist")
    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    refute GitBranchResolver.valid_branch?("valid; touch #{side_effect}")
    refute File.exists?(side_effect)
  end

  test "public branch validation fails closed when the Git executable is unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-branch-validation-no-git-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    File.mkdir_p!(test_root)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    System.put_env("PATH", test_root)

    refute GitBranchResolver.valid_branch?("main")
  end

  test "resolves a slash-containing non-main default ref and verifies the fetched SHA" do
    test_pid = self()

    runner = fn args ->
      send(test_pid, {:git_command, args})

      case args do
        ["ls-remote", "--symref", "origin", "HEAD"] ->
          {:ok, "ref: refs/heads/release/2026-q3\tHEAD\n#{@sha}\tHEAD\n"}

        ["fetch", "--no-tags", "origin", "refs/heads/release/2026-q3"] ->
          {:ok, ""}

        ["rev-parse", "--verify", "FETCH_HEAD^{commit}"] ->
          {:ok, @sha <> "\n"}
      end
    end

    assert {:ok,
            %Receipt{
              source: :canonical_default,
              ref: "refs/heads/release/2026-q3",
              branch: "release/2026-q3",
              advertised_sha: @sha,
              fetched_sha: @sha
            }} = GitBranchResolver.resolve("/workspace", command_runner: runner)

    assert_receive {:git_command, ["ls-remote", "--symref", "origin", "HEAD"]}
    assert_receive {:git_command, ["fetch", "--no-tags", "origin", "refs/heads/release/2026-q3"]}
    assert_receive {:git_command, ["rev-parse", "--verify", "FETCH_HEAD^{commit}"]}
  end

  test "fails closed for missing, duplicate, or malformed canonical symref evidence" do
    cases = [
      {"#{@sha}\tHEAD\n", :canonical_symref_missing},
      {"ref: refs/heads/main\tHEAD\nref: refs/heads/release\tHEAD\n#{@sha}\tHEAD\n", :canonical_symref_ambiguous},
      {"ref: refs/heads/main\n#{@sha}\tHEAD\n", :canonical_ref_invalid},
      {"ref: refs/tags/v1\tHEAD\n#{@sha}\tHEAD\n", :canonical_ref_invalid},
      {"ref: refs/heads/bad..name\tHEAD\n#{@sha}\tHEAD\n", :canonical_ref_invalid},
      {"ref: refs/heads/main\tHEAD\n", :canonical_head_invalid},
      {"ref: refs/heads/main\tHEAD\n#{@sha}\tHEAD\n#{@moved_sha}\tHEAD\n", :canonical_head_ambiguous},
      {"ref: refs/heads/main\tHEAD\nnot-a-sha\tHEAD\n", :canonical_head_invalid},
      {"ref: refs/heads/main\tHEAD\n#{@sha}\textra\tHEAD\n", :canonical_head_invalid},
      {"unexpected banner\nref: refs/heads/main\tHEAD\n#{@sha}\tHEAD\n", :canonical_evidence_malformed}
    ]

    Enum.each(cases, fn {output, expected_code} ->
      runner = fn ["ls-remote", "--symref", "origin", "HEAD"] -> {:ok, output} end

      assert {:error, %Failure{code: ^expected_code, operator_action: action}} =
               GitBranchResolver.resolve("/workspace", command_runner: runner)

      assert is_binary(action) and action != ""
    end)
  end

  test "blocks when the canonical ref moves between advertisement and fetch" do
    runner = fn
      ["ls-remote", "--symref", "origin", "HEAD"] ->
        {:ok, "ref: refs/heads/main\tHEAD\n#{@sha}\tHEAD\n"}

      ["fetch", "--no-tags", "origin", "refs/heads/main"] ->
        {:ok, ""}

      ["rev-parse", "--verify", "FETCH_HEAD^{commit}"] ->
        {:ok, @moved_sha <> "\n"}
    end

    assert {:error,
            %Failure{
              code: :canonical_head_moved,
              detail: detail,
              operator_action: action
            }} = GitBranchResolver.resolve("/workspace", command_runner: runner)

    assert detail =~ @sha
    assert detail =~ @moved_sha
    assert String.downcase(action) =~ "retry"
  end

  test "maps timeout and auth failures to redacted typed failures" do
    secret = "resolver-secret-token"

    timeout_runner = fn ["ls-remote", "--symref", "origin", "HEAD"] ->
      {:error, {:workspace_hook_timeout, "git ls-remote --symref origin HEAD", 25}}
    end

    assert {:error, %Failure{code: :command_timeout, detail: timeout_detail}} =
             GitBranchResolver.resolve("/workspace", command_runner: timeout_runner)

    assert timeout_detail =~ "25ms"

    auth_runner = fn ["ls-remote", "--symref", "origin", "HEAD"] ->
      {:error, {:git_command_failed, "git ls-remote --symref origin HEAD", 128, "fatal: unable to access https://user:#{secret}@github.com/example/private.git"}}
    end

    assert {:error, %Failure{code: :command_failed, detail: auth_detail}} =
             GitBranchResolver.resolve("/workspace", command_runner: auth_runner)

    refute auth_detail =~ secret
    assert auth_detail =~ "https://[redacted]@github.com/example/private.git"
  end

  test "maps every remaining command runner failure shape to a typed public failure" do
    cases = [
      {"detail tuple", fn -> {:error, {:git_command_failed, "git custom", "transport down"}} end, "transport down", "git custom"},
      {"term detail", fn -> {:error, {:git_command_failed, "git custom", %{reason: :transport_down}}} end, "transport_down", "git custom"},
      {"generic error", fn -> {:error, :network_down} end, "network_down", "git ls-remote --symref origin HEAD"},
      {"unexpected result", fn -> :unexpected_result end, "unexpected command result", "git ls-remote --symref origin HEAD"},
      {"raised runner", fn -> raise "runner exploded" end, "runner exploded", "git ls-remote --symref origin HEAD"},
      {"thrown runner", fn -> throw(:runner_threw) end, "runner_threw", "git ls-remote --symref origin HEAD"}
    ]

    Enum.each(cases, fn {name, result, detail_fragment, expected_command} ->
      runner = fn ["ls-remote", "--symref", "origin", "HEAD"] -> result.() end

      assert {:error,
              %Failure{
                code: :command_failed,
                command: ^expected_command,
                detail: detail
              }} = GitBranchResolver.resolve("/workspace", command_runner: runner),
             name

      assert detail =~ detail_fragment, name
    end)
  end

  test "accepts and normalizes a full 64-character SHA" do
    normalized_sha = String.downcase(@sha64)

    runner = fn
      ["ls-remote", "--symref", "origin", "HEAD"] ->
        {:ok, "ref: refs/heads/main\tHEAD\n#{@sha64}\tHEAD\n"}

      ["fetch", "--no-tags", "origin", "refs/heads/main"] ->
        {:ok, ""}

      ["rev-parse", "--verify", "FETCH_HEAD^{commit}"] ->
        {:ok, @sha64 <> "\n"}
    end

    assert {:ok,
            %Receipt{
              advertised_sha: ^normalized_sha,
              fetched_sha: ^normalized_sha
            }} = GitBranchResolver.resolve("/workspace", command_runner: runner)
  end

  test "looks up and fetches one exact explicit remote branch" do
    runner = fn
      ["ls-remote", "--heads", "origin", "refs/heads/stack/base"] ->
        {:ok, "#{@sha}\trefs/heads/stack/base\n"}

      ["fetch", "--no-tags", "origin", "refs/heads/stack/base"] ->
        {:ok, ""}

      ["rev-parse", "--verify", "FETCH_HEAD^{commit}"] ->
        {:ok, @sha <> "\n"}
    end

    assert {:ok,
            %Receipt{
              source: :explicit_branch,
              branch: "stack/base",
              advertised_sha: @sha,
              fetched_sha: @sha
            }} = GitBranchResolver.lookup_branch("/workspace", "stack/base", command_runner: runner)
  end

  test "explicit remote branch lookup distinguishes missing and ambiguous evidence" do
    missing_runner = fn ["ls-remote", "--heads", "origin", "refs/heads/missing"] ->
      {:ok, ""}
    end

    assert {:ok, :missing} =
             GitBranchResolver.lookup_branch("/workspace", "missing", command_runner: missing_runner)

    ambiguous_runner = fn ["ls-remote", "--heads", "origin", "refs/heads/duplicate"] ->
      {:ok, "#{@sha}\trefs/heads/duplicate\n#{@moved_sha}\trefs/heads/duplicate\n"}
    end

    assert {:error, %Failure{code: :branch_head_ambiguous}} =
             GitBranchResolver.lookup_branch("/workspace", "duplicate", command_runner: ambiguous_runner)
  end

  test "explicit lookup blocks malformed, unfetched, and moved branch evidence" do
    ref = "refs/heads/target"

    cases = [
      {"wrong ref", "#{@sha}\trefs/heads/wrong\n", nil, :branch_head_invalid},
      {"missing fetched head", "#{@sha}\t#{ref}\n", "", :fetched_head_invalid},
      {"moved head", "#{@sha}\t#{ref}\n", @moved_sha <> "\n", :branch_head_moved}
    ]

    Enum.each(cases, fn {name, advertised_output, fetched_output, expected_code} ->
      runner = fn
        ["ls-remote", "--heads", "origin", ^ref] ->
          {:ok, advertised_output}

        ["fetch", "--no-tags", "origin", ^ref] ->
          {:ok, ""}

        ["rev-parse", "--verify", "FETCH_HEAD^{commit}"] ->
          {:ok, fetched_output}
      end

      assert {:error, %Failure{code: ^expected_code}} =
               GitBranchResolver.lookup_branch("/workspace", "target", command_runner: runner),
             name
    end)
  end

  test "uses the same SSH command seam without leaking URL credentials" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-git-resolver-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      printf '%s\n' "$*" >> "$SYMP_TEST_SSH_TRACE"
      case "$*" in
        *"ls-remote"*"--symref"*"origin"*"HEAD"*)
          printf '%s\n' 'ref: refs/heads/release/ssh\tHEAD' '#{@sha}\tHEAD'
          ;;
        *"fetch"*"refs/heads/release/ssh"*)
          ;;
        *"rev-parse"*"FETCH_HEAD^{commit}"*)
          printf '%s\n' '#{@sha}'
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      assert {:ok, %Receipt{branch: "release/ssh", fetched_sha: @sha}} =
               GitBranchResolver.resolve("/remote/workspace", worker_host: "worker-01")

      trace = File.read!(trace_file)
      assert trace =~ "worker-01"
      assert trace =~ "/remote/workspace"
      assert trace =~ "ls-remote"
      assert trace =~ "--symref"
      assert trace =~ "origin"
      assert trace =~ "HEAD"
      refute trace =~ "http://"
      refute trace =~ "https://"
    after
      File.rm_rf(test_root)
    end
  end

  defp git_fixture! do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-git-resolver-local-#{System.unique_integer([:positive])}"
      )

    remote = Path.join(root, "origin.git")
    seed = Path.join(root, "seed")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(root)
    cmd!("git", ["init", "--bare", remote])
    cmd!("git", ["init", "-b", "main", seed])
    git!(seed, ["config", "user.name", "Symphony Test"])
    git!(seed, ["config", "user.email", "symphony@example.com"])
    File.write!(Path.join(seed, "README.md"), "initial\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-m", "initial"])
    main_sha = git!(seed, ["rev-parse", "HEAD"])
    git!(seed, ["remote", "add", "origin", remote])
    git!(seed, ["push", "-u", "origin", "main"])
    git!(seed, ["switch", "-c", "feature/existing"])
    File.write!(Path.join(seed, "feature.txt"), "feature\n")
    git!(seed, ["add", "feature.txt"])
    git!(seed, ["commit", "-m", "feature"])
    feature_sha = git!(seed, ["rev-parse", "HEAD"])
    git!(seed, ["push", "origin", "feature/existing"])
    cmd!("git", ["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/main"])
    cmd!("git", ["clone", remote, workspace])

    %{root: root, workspace: workspace, main_sha: main_sha, feature_sha: feature_sha}
  end

  defp git!(repo, args), do: cmd!("git", ["-C", repo | args])

  defp cmd!(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("command failed status=#{status}: #{executable} #{Enum.join(args, " ")}\n#{output}")
    end
  end
end
