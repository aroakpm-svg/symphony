defmodule SymphonyElixir.ScheduledRuntimeOptionsTest do
  use SymphonyElixir.TestSupport

  defmodule Callbacks do
    def resolve(ref), do: credential_source(ref)
    # Only this short-lived test fixture owns callback data; schedulers retain external handles.
    for {key, arity} <- [
          credential_source: 1,
          request_fun: 1,
          fetcher: 1,
          refresh_fun: 1,
          profile_refresh_fun: 1,
          retry_fetch_fun: 2,
          route_reader: 1,
          claim_fun: 2,
          task_start_fun: 1,
          repository_bootstrap_command_runner: 3,
          git_checkout_command_runner: 3
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(key)(unquote_splicing(args)) do
        callback = Agent.get(__MODULE__, &Keyword.fetch!(&1, unquote(key)))
        callback.(unquote_splicing(args))
      end
    end
  end

  @profile %{
    key: "central-brain",
    linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
    repository: "aroakpm-svg/aroak-central-brain",
    canonical_branch: "main",
    workspace_namespace: "central-brain",
    credential_ref: "github-central-brain",
    environment: "local_non_production"
  }
  @other %{
    key: "project-management",
    linear_project_id: "708053e0-f42c-4e93-bec4-7abbb37e74af",
    repository: "aroakpm-svg/aroak-project-management",
    canonical_branch: "main",
    workspace_namespace: "project-management",
    credential_ref: "github-project-management",
    environment: "local_non_production"
  }

  setup do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")

    config = %{
      tracker: %{kind: "memory", api_key: "synthetic-tracker", assignee: "synthetic-assignee"},
      claim: %{
        enabled: false,
        database_url: "synthetic-database",
        ca_cert_file: "synthetic-ca",
        node_id: "synthetic-node",
        node_instance_id: "synthetic-instance"
      },
      polling: %{interval_ms: 3_600_000},
      workspace: %{root: root},
      project_profiles: %{version: 1, profiles: [@profile, @other]}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic")
    :ok = WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    previous = Application.get_env(:symphony_elixir, :orchestrator_opts)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :orchestrator_opts, previous),
        else: Application.delete_env(:symphony_elixir, :orchestrator_opts)
    end)

    :ok
  end

  for entry <- [:poll, :issue_retry, :profile_retry] do
    test "started scheduler retains authority through #{entry}" do
      entry = unquote(entry)
      parent = self()
      {:ok, ready} = Agent.start_link(fn -> false end)
      issue = candidate()
      opts = options(parent, ready, issue, "synthetic-instance[bot]")
      Application.put_env(:symphony_elixir, :orchestrator_opts, opts)
      {:ok, server} = Orchestrator.start_link(name: nil)
      on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
      assert_receive {:fetched, "central-brain"}, 2_000
      assert_receive {:fetched, "project-management"}, 2_000
      :sys.get_state(server)
      Application.put_env(:symphony_elixir, :orchestrator_opts, expected_actor: "changed[bot]")
      Agent.update(ready, fn _ -> true end)
      trigger(server, entry, issue)
      assert_receive {:authority, preflight}, 2_000
      refute preflight == server
      assert_receive :claimed, 2_000
      assert_receive {:authority, worker}, 5_000
      refute worker == server
      assert_received {:resolved, ^preflight}
      assert_received {:resolved, ^worker}
      assert_receive :runner_finished, 30_000
      refute_received {:runner_exception, _kind}
      assert_received :bootstrap_after_authority
      safe_status = inspect(:sys.get_status(server))
      safe_state = inspect(:sys.get_state(server))
      snapshot = inspect(GenServer.call(server, :snapshot))

      for surface <- [safe_status, safe_state, snapshot] do
        refute String.contains?(surface, "unknown-sentinel")
        refute String.contains?(surface, "synthetic-instance[bot]")
        refute String.contains?(surface, "#Function")
      end

      unknown_retained? =
        server |> :sys.get_state() |> Map.get(:runtime_options, []) |> Keyword.has_key?(:unknown_option)

      refute unknown_retained?

      resolved_token_retained? =
        server |> :sys.get_state() |> :erlang.term_to_binary() |> :binary.match("synthetic-only-token")

      assert resolved_token_retained? == :nomatch

      for {_key, value} <- :sys.get_state(server).runtime_options, is_function(value) do
        assert :erlang.fun_info(value, :env) == {:env, []}
      end
    end
  end

  test "explicit init actor overrides configured defaults without changing an existing instance" do
    parent = self()
    {:ok, ready} = Agent.start_link(fn -> false end)
    issue = candidate()
    opts = options(parent, ready, issue, "explicit[bot]")
    Application.put_env(:symphony_elixir, :orchestrator_opts, Keyword.put(opts, :expected_actor, "wrong[bot]"))
    {:ok, server} = Orchestrator.start_link(name: nil, expected_actor: "explicit[bot]")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert_receive {:fetched, "central-brain"}, 2_000
    assert_receive {:fetched, "project-management"}, 2_000
    Agent.update(ready, fn _ -> true end)
    send(server, :run_poll_cycle)
    assert_receive :bootstrap_after_authority, 30_000
    assert_receive :runner_finished, 30_000
    refute_received {:runner_exception, _kind}
  end

  test "rejects captured credentials before starting a scheduler" do
    secret = Enum.join(["captured", "token", "private/path"], "-")

    for key <- [:credential_source, :worker_credential_source, :request_fun, :dispatch_fun],
        origin <- [:explicit, :application] do
      callback = fn _ -> secret end
      opts = [{key, callback}]
      Application.put_env(:symphony_elixir, :orchestrator_opts, if(origin == :application, do: opts, else: []))
      explicit = if origin == :explicit, do: opts, else: []
      result = Orchestrator.start_link([name: nil] ++ explicit)
      if match?({:ok, _}, result), do: GenServer.stop(elem(result, 1))
      assert result == {:error, {:unsafe_runtime_option, key}}
      refute :erlang.term_to_binary(result) =~ secret
      assert {:stop, {:unsafe_runtime_option, ^key}} = Orchestrator.init(opts)
    end
  end

  test "startup rejects captured application sources before identity validation" do
    previous = Application.get_env(:symphony_elixir, :github_credential_source)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_credential_source, previous),
        else: Application.delete_env(:symphony_elixir, :github_credential_source)
    end)

    secret = Enum.join(["application", "credential", "path"], "-")
    Application.put_env(:symphony_elixir, :github_credential_source, fn _ -> secret end)
    parent = self()

    opts = [
      name: nil,
      identity_validator: fn ->
        send(parent, :identity_called)
        {:ok, %{viewer_id: "synthetic"}}
      end
    ]

    result = Orchestrator.start_link(opts)
    if match?({:ok, _}, result), do: GenServer.stop(elem(result, 1))
    assert result == {:error, :credential_resolver_failed}
    assert {:stop, :credential_resolver_failed} = Orchestrator.init(opts)
    refute_received :identity_called
  end

  test "a timed out scheduled preflight releases the scheduler and retries without claiming" do
    parent = self()
    {:ok, ready} = Agent.start_link(fn -> false end)
    issue = candidate()
    opts = options(parent, ready, issue, "synthetic-instance[bot]")
    original_source = Agent.get(Callbacks, &Keyword.fetch!(&1, :credential_source))

    Agent.update(Callbacks, fn callbacks ->
      Keyword.put(callbacks, :credential_source, fn _ ->
        send(parent, {:hung_source, self()})
        Process.sleep(:infinity)
      end)
    end)

    {:ok, server} = Orchestrator.start_link([name: nil, preflight_timeout: 25] ++ opts)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert_receive {:fetched, "project-management"}, 2_000
    Agent.update(ready, fn _ -> true end)
    send(server, :run_poll_cycle)
    assert_receive {:hung_source, source}, 2_000
    GenServer.call(server, :snapshot, 500)
    refute Process.alive?(source)
    refute_received :claimed
    state = :sys.get_state(server)
    assert state.running == %{}
    assert state.profile_retry_attempts[@profile.key]
    assert state.profile_retry_attempts[@profile.key].reason == {:preflight_blocked, :github_unavailable}

    Agent.update(Callbacks, &Keyword.put(&1, :credential_source, original_source))
    retry = state.profile_retry_attempts[@profile.key]
    send(server, {:retry_project_profile, @profile.key, retry.retry_token})
    assert_receive :claimed, 2_000
    assert_receive :bootstrap_after_authority, 10_000
    assert_receive :runner_finished, 10_000
  end

  test "scheduled polling rejects a captured application source installed after startup" do
    previous = Application.get_env(:symphony_elixir, :github_credential_source)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_credential_source, previous),
        else: Application.delete_env(:symphony_elixir, :github_credential_source)
    end)

    parent = self()
    {:ok, ready} = Agent.start_link(fn -> false end)
    opts = options(parent, ready, candidate(), "synthetic-instance[bot]") |> Keyword.delete(:credential_source)
    Application.put_env(:symphony_elixir, :github_credential_source, Callbacks)
    {:ok, server} = Orchestrator.start_link([name: nil] ++ opts)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert_receive {:fetched, "project-management"}, 2_000
    :sys.get_state(server)

    Application.put_env(:symphony_elixir, :github_credential_source, fn _ ->
      send(parent, :unsafe_source_invoked)
      {:error, :missing}
    end)

    Agent.update(ready, fn _ -> true end)
    send(server, :run_poll_cycle)
    :sys.get_state(server)
    refute_received :unsafe_source_invoked
    refute_received :claimed
    assert :sys.get_state(server).profile_retry_attempts == %{}
    Application.put_env(:symphony_elixir, :github_credential_source, &Callbacks.resolve/1)
    send(server, :run_poll_cycle)
    assert_receive :claimed, 2_000
    assert_receive :runner_finished, 15_000
  end

  for interruption <- [:none, :fetch, :remote_head] do
    @tag timeout: 90_000, interruption: interruption
    test "scheduled pickup completes and reports with #{interruption} interruption", %{interruption: interruption} do
      parent = self()
      {:ok, ready} = Agent.start_link(fn -> false end)
      {:ok, failure_budget} = Agent.start_link(fn -> if interruption == :none, do: 0, else: 1 end)
      issue = candidate()
      opts = options(parent, ready, issue, "synthetic-instance[bot]")
      root = Path.dirname(Workflow.workflow_file_path())
      seed = Path.join(root, "seed")
      File.mkdir_p!(seed)
      git!(seed, ["init", "-b", "main"])
      git!(seed, ["config", "user.name", "Synthetic Test"])
      git!(seed, ["config", "user.email", "synthetic@example.invalid"])
      File.write!(Path.join(seed, "README.md"), "Synthetic local acceptance fixture\n")
      git!(seed, ["add", "."])
      git!(seed, ["commit", "-m", "fixture"])
      head = git!(seed, ["rev-parse", "HEAD"])
      workspace = Path.join([root, "workspaces", @profile.key, issue.identifier])
      fake_codex = Path.join(root, "fake-codex")

      File.write!(fake_codex, """
      #!/bin/sh
      printf launched > codex-ran.marker
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-scheduled"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-scheduled"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0 ;;
        esac
      done
      """)

      File.chmod!(fake_codex, 0o755)

      [_, frontmatter, _] = String.split(File.read!(Workflow.workflow_file_path()), "---", parts: 3)
      config = Jason.decode!(frontmatter)
      config = Map.put(config, "codex", %{"command" => shell_quote(shell_path(fake_codex)) <> " app-server"})
      rewrite = "url.#{shell_path(seed)}.insteadOf"
      config = Map.put(config, "hooks", %{"after_create" => "git config " <> shell_quote(rewrite) <> " https://github.com/aroakpm-svg/aroak-central-brain.git"})
      File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic")
      :ok = WorkflowStore.force_reload()

      Agent.update(Callbacks, fn callbacks ->
        original_request = Keyword.fetch!(callbacks, :request_fun)

        callbacks
        |> Keyword.put(:request_fun, fn request ->
          if String.contains?(request[:url], "/git/ref/") do
            {:ok, %{status: 200, body: %{"ref" => "refs/heads/main", "object" => %{"sha" => head}}}}
          else
            original_request.(request)
          end
        end)
        |> Keyword.put(:repository_bootstrap_command_runner, fn args, _credential, _runtime ->
          bootstrap_with_interruption(args, workspace, seed, failure_budget, interruption)
        end)
        |> Keyword.put(:git_checkout_command_runner, fn args, _credential, _runtime ->
          checkout_with_interruption(args, workspace, seed, failure_budget, interruption)
        end)
      end)

      opts =
        opts
        |> Keyword.put(:name, nil)
        |> Keyword.put(:effect_ledger_ready?, fn -> true end)
        |> Keyword.put(:git_checkout_command_runner, &Callbacks.git_checkout_command_runner/3)

      {:ok, server} = Orchestrator.start_link(opts)
      on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
      assert_receive {:fetched, "project-management"}, 2_000
      Agent.update(ready, fn _ -> true end)
      send(server, :run_poll_cycle)
      assert_receive :claimed, 2_000

      if interruption != :none do
        assert_receive :runner_finished, 20_000
        state = await_retry(server, issue.id, 100)
        assert state.blocked == %{}
        refute MapSet.member?(state.claimed, issue.id)
        assert state.retry_attempts[issue.id].ownership == :unowned_backoff
        reason = if interruption == :fetch, do: "repository_bootstrap_unavailable", else: "github_unavailable"
        assert state.retry_attempts[issue.id].error =~ reason
        refute File.exists?(workspace)
        retry = state.retry_attempts[issue.id]
        send(server, {:retry_issue, issue.id, retry.retry_token})
        assert_receive :claimed, 2_000
      end

      assert_receive :runner_finished, 30_000
      refute_received {:runner_exception, _}
      assert File.read!(Path.join(workspace, "codex-ran.marker")) == "launched"
      assert git!(workspace, ["branch", "--show-current"]) == issue.branch_name
      assert git!(workspace, ["rev-parse", "HEAD"]) == head
      state = await_completed(server, issue.id, 100)
      assert state.blocked == %{}
      assert state.running == %{}
      refute :erlang.term_to_binary(state) =~ "synthetic-only-token"
      snapshot = GenServer.call(server, :snapshot)
      assert snapshot.running == []
      assert snapshot.blocked == []
      assert Enum.any?(snapshot.retrying, &(&1.issue_id == issue.id and is_nil(&1.error)))
    end
  end

  defp bootstrap_with_interruption(args, workspace, seed, failure_budget, interruption) do
    fail? = interruption == :fetch and "fetch" in args and consume_failure(failure_budget)

    if fail? do
      {:error, {:git_command_failed, "git fetch", 128, "connection reset synthetic-only-token"}}
    else
      {:ok, git!(workspace, fixture_fetch_args(args, seed))}
    end
  end

  defp checkout_with_interruption(args, workspace, seed, failure_budget, interruption) do
    fail? = interruption == :remote_head and "ls-remote" in args and consume_failure(failure_budget)

    if fail? do
      {:error, {:workspace_hook_timeout, "git ls-remote", 100}}
    else
      args =
        case args do
          ["ls-remote", "--heads", "origin", ref] -> ["ls-remote", "--heads", seed, ref]
          other -> other
        end

      {:ok, git!(workspace, args)}
    end
  end

  defp consume_failure(budget), do: Agent.get_and_update(budget, &{&1 > 0, max(&1 - 1, 0)})

  defp fixture_fetch_args(args, seed) do
    if "fetch" in args, do: Enum.map(args, &if(&1 == "origin", do: seed, else: &1)), else: args
  end

  defp await_retry(server, issue_id, attempts) do
    state = :sys.get_state(server)

    if Map.has_key?(state.retry_attempts, issue_id) and state.running == %{} do
      state
    else
      assert attempts > 0, "scheduler never recorded a retry"
      Process.sleep(10)
      await_retry(server, issue_id, attempts - 1)
    end
  end

  defp await_completed(server, issue_id, attempts) do
    state = :sys.get_state(server)

    if MapSet.member?(state.completed, issue_id) do
      state
    else
      assert attempts > 0, "scheduler never recorded completion"
      Process.sleep(10)
      await_completed(server, issue_id, attempts - 1)
    end
  end

  defp git!(directory, args) do
    {output, status} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp options(parent, ready, issue, actor) do
    request = fn request ->
      body =
        cond do
          String.ends_with?(request[:url], "/graphql") ->
            send(parent, {:authority, self()})
            %{"data" => %{"viewer" => %{"login" => actor}}}

          String.contains?(request[:url], "/contents/") ->
            %{"scripts" => %{"typecheck" => "tsc", "build" => "build", "test" => "test"}}

          String.contains?(request[:url], "/git/ref/") ->
            %{"ref" => "refs/heads/main", "object" => %{"sha" => String.duplicate("a", 40)}}

          true ->
            %{
              "full_name" => @profile.repository,
              "default_branch" => "main",
              "permissions" => %{"pull" => true, "push" => true}
            }
        end

      {:ok, %{status: 200, body: body}}
    end

    opts = [
      identity_validator: fn -> {:ok, %{viewer_id: "synthetic-viewer"}} end,
      unknown_option: "unknown-sentinel",
      expected_actor: actor,
      credential_source: fn ref ->
        send(parent, {:resolved, self()})
        {:ok, %{credential_ref: ref, token: "synthetic-only-token", expires_at: nil}}
      end,
      request_fun: request,
      fetcher: fn profile ->
        send(parent, {:fetched, profile.key})
        {:ok, if(profile.key == @profile.key and Agent.get(ready, & &1), do: [issue], else: [])}
      end,
      refresh_fun: fn _ -> {:ok, [issue]} end,
      profile_refresh_fun: fn _ -> {:ok, [issue]} end,
      retry_fetch_fun: fn _, _ -> {:ok, [issue]} end,
      route_reader: fn _ -> {:ok, %{routing_revision: 1}} end,
      claim_fun: fn _, _ ->
        send(parent, :claimed)
        {:ok, %{claim_id: "synthetic-claim", generation: 1}}
      end,
      bind_worker_fun: fn _, _ -> :ok end,
      task_start_fun: fn task ->
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          try do
            task.()
          rescue
            exception -> send(parent, {:runner_exception, {exception.__struct__, Exception.message(exception)}})
          after
            send(parent, :runner_finished)
          end
        end)
      end,
      finalize_claim_fun: fn _, _ -> :ok end,
      repository_bootstrap_command_runner: fn _, _, _ ->
        send(parent, :bootstrap_after_authority)
        {:error, :synthetic_stop}
      end
    ]

    start_supervised!(%{id: Callbacks, start: {Agent, :start_link, [fn -> opts end, [name: Callbacks]]}})

    external_callbacks(opts)
  end

  defp external_callbacks(opts) do
    Enum.map(opts, fn {key, value} ->
      if is_function(value) and :erlang.fun_info(value, :env) != {:env, []} do
        {:arity, arity} = :erlang.fun_info(value, :arity)
        {key, if(key == :credential_source, do: Callbacks, else: Function.capture(Callbacks, key, arity))}
      else
        {key, value}
      end
    end)
  end

  defp trigger(server, :poll, _issue), do: send(server, :run_poll_cycle)

  defp trigger(server, :profile_retry, _issue) do
    token = make_ref()

    :sys.replace_state(server, fn state ->
      %{state | profile_retry_attempts: %{@profile.key => %{attempt: 1, retry_token: token}}}
    end)

    send(server, {:retry_project_profile, @profile.key, token})
  end

  defp trigger(server, :issue_retry, issue) do
    token = make_ref()

    :sys.replace_state(server, fn state ->
      %{
        state
        | claimed: MapSet.new([issue.id]),
          retry_attempts: %{
            issue.id => %{attempt: 1, retry_token: token, project_profile: @profile, identifier: issue.identifier}
          }
      }
    end)

    send(server, {:retry_issue, issue.id, token})
  end

  defp candidate do
    %Issue{
      id: "synthetic-scheduled",
      identifier: "ARO-196-SCHEDULED",
      title: "Synthetic",
      state: "In Progress",
      branch_name: "codex/synthetic-scheduled",
      labels: ["symphony-worker"],
      project_id: @profile.linear_project_id,
      project_profile: @profile,
      repository: @profile.repository,
      routing_revision: 1
    }
  end
end
