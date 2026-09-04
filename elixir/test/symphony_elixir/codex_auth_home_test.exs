defmodule SymphonyElixir.CodexAuthHomeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CodexAuthHome, ProjectExecutionContext}

  setup do
    root = Path.expand(Path.join(System.tmp_dir!(), "codex-auth-#{System.os_time(:nanosecond)}"))
    auth_root = Path.join(root, "auth")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join([workspace_root, "central-brain", "ARO-286"])
    home = Path.join(auth_root, "central-brain")
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(home)
    old_root = Application.get_env(:symphony_elixir, :codex_auth_home_root)
    Application.put_env(:symphony_elixir, :codex_auth_home_root, auth_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    on_exit(fn ->
      if old_root,
        do: Application.put_env(:symphony_elixir, :codex_auth_home_root, old_root),
        else: Application.delete_env(:symphony_elixir, :codex_auth_home_root)

      File.rm_rf!(root)
    end)

    context = %ProjectExecutionContext{
      profile_key: "central-brain",
      linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      repository: "aroakpm-svg/aroak-central-brain",
      canonical_branch: "main",
      workspace_namespace: "central-brain",
      credential_ref: "github-central-brain",
      environment: "local_non_production",
      issue_id: "issue-auth",
      issue_identifier: "ARO-286",
      routing_revision: 1
    }

    assert {:ok, ^workspace} = Workspace.create_for_issue("ARO-286", nil, context)
    {:ok, root: root, auth_root: auth_root, home: home, workspace: workspace, context: context}
  end

  test "resolves only the dedicated selected-profile home without reading authentication", ctx do
    File.write!(Path.join(ctx.home, "auth.json"), "synthetic unreadable-to-parser credential fixture")
    assert {:ok, ctx.home} == CodexAuthHome.resolve(ctx.context)
    assert {:ok, nil} == CodexAuthHome.resolve(nil)
    assert {:error, :codex_auth_home_invalid} == CodexAuthHome.resolve(%{ctx.context | profile_key: "../other"})
  end

  test "missing, relative, workspace-contained and redirected homes fail closed", ctx do
    for root <- [nil, 42, "relative", "bad\0path", ctx.root, Path.dirname(Path.dirname(ctx.workspace)), Path.join(ctx.root, "missing")] do
      Application.put_env(:symphony_elixir, :codex_auth_home_root, root)
      assert {:error, reason} = CodexAuthHome.resolve(ctx.context)
      assert reason in [:codex_auth_home_unconfigured, :codex_auth_home_invalid]
    end

    Application.put_env(:symphony_elixir, :codex_auth_home_root, ctx.auth_root)
    other = Path.join(ctx.auth_root, "project-management")
    File.rename!(ctx.home, other)
    create_directory_link!(other, ctx.home)
    assert {:error, :codex_auth_home_invalid} == CodexAuthHome.resolve(ctx.context)
  end

  test "an auth file redirect cannot borrow credentials from another profile", ctx do
    File.mkdir_p!(Path.join(ctx.home, "auth.json"))
    assert {:error, :codex_auth_home_invalid} == CodexAuthHome.resolve(ctx.context)
  end

  test "unconfigured profile never launches a Codex process", ctx do
    Application.delete_env(:symphony_elixir, :codex_auth_home_root)

    assert {:error, :codex_auth_home_unconfigured} ==
             AppServer.start_session(ctx.workspace,
               execution_context: ctx.context,
               port_opener: fn _, _ -> flunk("must not open Codex without an explicit home") end
             )
  end

  for account <- [~s({"type":"apiKey"}), "null"] do
    test "supports provisioned API-key and no-auth providers: #{account}", ctx do
      required = unquote(account) != "null"
      reply = Jason.encode!(%{"id" => 4, "result" => %{"account" => Jason.decode!(unquote(account)), "requiresOpenaiAuth" => required}})
      script = protocol!(ctx, reply)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(Path.dirname(ctx.workspace)),
        codex_command: "sh '#{shell_path(script)}'"
      )

      assert {:ok, session} = AppServer.start_session(ctx.workspace, execution_context: ctx.context)
      AppServer.stop_session(session)
    end
  end

  test "unrelated auth notifications do not extend the deadline or leak details", ctx do
    notification = ~s({"method":"account/updated","params":{"detail":"SECRET_AUTH_DETAIL"}})
    script = protocol!(ctx, notification)
    body = File.read!(script)

    File.write!(script, String.replace(body, "printf '%s\\n' '#{notification}'", "i=0; while [ $i -lt 100 ]; do printf '%s\\n' '#{notification}'; sleep 0.1; i=$((i + 1)); done"))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(Path.dirname(ctx.workspace)),
      codex_command: "sh '#{shell_path(script)}'",
      codex_read_timeout_ms: 2_000
    )

    started = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        assert {:error, :codex_authentication_unavailable} ==
                 AppServer.start_session(ctx.workspace, execution_context: ctx.context)
      end)

    assert System.monotonic_time(:millisecond) - started < 8_000
    refute log =~ "SECRET_AUTH_DETAIL"
    refute File.read!(Path.join(ctx.root, "requests")) =~ "thread/start"
  end

  test "profiled Codex uses its own home and checks ChatGPT auth before creating a thread", ctx do
    script = protocol!(ctx, ~s({"id":4,"result":{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"plus"},"requiresOpenaiAuth":true}}))
    parent = self()

    opener = fn target, options ->
      send(parent, {:port_environment, options[:env]})
      Port.open(target, options)
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(Path.dirname(ctx.workspace)),
      codex_command: "sh '#{shell_path(script)}'"
    )

    assert {:ok, session} = AppServer.start_session(ctx.workspace, execution_context: ctx.context, port_opener: opener)
    AppServer.stop_session(session)
    assert_receive {:port_environment, environment}
    assert {~c"CODEX_HOME", String.to_charlist(ctx.home)} in environment
    refute inspect(session) =~ ctx.home
    assert File.read!(Path.join(ctx.root, "requests")) =~ "account/read"
    requests = File.read!(Path.join(ctx.root, "requests")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    thread = Enum.find(requests, &(&1["method"] == "thread/start"))
    expected_child_home = SymphonyElixir.SubprocessEnvironment.private_home_paths(ctx.context).codex
    assert thread["params"]["config"]["shell_environment_policy.set"]["CODEX_HOME"] == expected_child_home
    refute File.exists?(Path.join(ctx.home, "auth.json"))
  end

  for {label, reply, expected} <- [
        {"logged out", ~s({"id":4,"result":{"account":null,"requiresOpenaiAuth":true}}), :codex_authentication_required},
        {"RPC error", ~s({"id":4,"error":{"message":"SECRET_AUTH_DETAIL"}}), :codex_authentication_unavailable},
        {"malformed response", ~s({"id":4,"result":{"account":{}}}), :codex_authentication_unavailable}
      ] do
    test "#{label} blocks before thread creation without leaking account details", ctx do
      script = protocol!(ctx, unquote(reply))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(Path.dirname(ctx.workspace)),
        codex_command: "sh '#{shell_path(script)}'"
      )

      log =
        capture_log(fn ->
          assert {:error, unquote(expected)} == AppServer.start_session(ctx.workspace, execution_context: ctx.context)
        end)

      refute log =~ "SECRET_AUTH_DETAIL"
      refute File.read!(Path.join(ctx.root, "requests")) =~ "thread/start"
    end
  end

  defp protocol!(ctx, reply) do
    script = Path.join(ctx.root, "codex.sh")

    File.write!(script, """
    #!/bin/bash
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '#{shell_path(Path.join(ctx.root, "requests"))}'
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"account/read"'*) printf '%s\\n' '#{reply}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"auth-thread"}}}' ;;
      esac
    done
    """)

    script
  end
end
