defmodule SymphonyElixir.GitBranchResolverTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitBranchResolver
  alias SymphonyElixir.GitBranchResolver.{Failure, Receipt}

  @sha String.duplicate("a", 40)
  @moved_sha String.duplicate("b", 40)

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
      {"ref: refs/tags/v1\tHEAD\n#{@sha}\tHEAD\n", :canonical_ref_invalid},
      {"ref: refs/heads/bad..name\tHEAD\n#{@sha}\tHEAD\n", :canonical_ref_invalid},
      {"ref: refs/heads/main\tHEAD\n#{@sha}\tHEAD\n#{@moved_sha}\tHEAD\n", :canonical_head_ambiguous},
      {"ref: refs/heads/main\tHEAD\nnot-a-sha\tHEAD\n", :canonical_head_invalid},
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
end
