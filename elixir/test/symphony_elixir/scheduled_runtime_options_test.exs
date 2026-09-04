defmodule SymphonyElixir.ScheduledRuntimeOptionsTest do
  use SymphonyElixir.TestSupport

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
      assert_receive {:authority, ^server}, 2_000
      assert_receive :claimed, 2_000
      assert_receive {:authority, worker}, 5_000
      refute worker == server
      assert_received {:resolved, ^server}
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

    [
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
            exception -> send(parent, {:runner_exception, exception.__struct__})
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
