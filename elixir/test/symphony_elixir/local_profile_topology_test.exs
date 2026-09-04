defmodule SymphonyElixir.LocalProfileTopologyTest do
  use SymphonyElixir.TestSupport

  @central %{
    "key" => "central-brain",
    "linear_project_id" => "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
    "repository" => "aroakpm-svg/aroak-central-brain",
    "canonical_branch" => "main",
    "workspace_namespace" => "central-brain",
    "credential_ref" => "github-central-brain",
    "environment" => "local_non_production"
  }
  @management %{
    "key" => "project-management",
    "linear_project_id" => "708053e0-f42c-4e93-bec4-7abbb37e74af",
    "repository" => "aroakpm-svg/aroak-project-management",
    "canonical_branch" => "main",
    "workspace_namespace" => "project-management",
    "credential_ref" => "github-project-management",
    "environment" => "local_non_production"
  }
  @profiles %{"version" => 1, "profiles" => [@central, @management]}
  @reason :profiled_ssh_topology_unsupported

  setup do
    for filename <- [".env.local", ".env.local.txt"] do
      refute File.exists?(Path.join(Path.dirname(Workflow.workflow_file_path()), filename))
    end

    parent = self()
    previous = Application.get_env(:symphony_elixir, :ssh_command_runner)

    Application.put_env(:symphony_elixir, :ssh_command_runner, fn _, _, _ ->
      send(parent, :synthetic_ssh_effect)
      {"synthetic transport stopped", 97}
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, parent)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :ssh_command_runner, previous),
        else: Application.delete_env(:symphony_elixir, :ssh_command_runner)
    end)

    :ok
  end

  test "settings and validation accept absent, null and empty SSH lists for local profiles" do
    for worker <- [%{}, %{"ssh_hosts" => nil}, %{"ssh_hosts" => []}] do
      configure(@profiles, worker)
      assert {:ok, settings} = Config.settings()
      assert settings.worker.ssh_hosts == []
      assert settings.project_profiles.profiles["central-brain"].repository == @central["repository"]
      assert :ok = Config.validate!()
    end
  end

  test "admission rejects profiled SSH while lifecycle settings remain readable" do
    for hosts <- [["synthetic-ssh"], ["synthetic-han-wsl"], [""]] do
      configure(@profiles, %{"ssh_hosts" => hosts})
      assert settings_outcome() == :accepted
      assert {:error, @reason} = Config.validate!()
    end
  end

  test "legacy SSH settings remain valid without profiles" do
    configure(nil, %{"ssh_hosts" => ["synthetic-legacy"]})
    assert {:ok, settings} = Config.settings()
    assert settings.worker.ssh_hosts == ["synthetic-legacy"]
    assert :ok = Config.validate!()
  end

  test "startup rejects profiled SSH before identity validation or terminal cleanup" do
    configure(@profiles, %{"ssh_hosts" => ["synthetic-ssh"]})
    parent = self()

    assert {:stop, @reason} =
             Orchestrator.init(
               identity_validator: fn ->
                 send(parent, :identity_effect)
                 {:error, :linear_unauthorized}
               end
             )

    refute_received :identity_effect
    refute_received :synthetic_ssh_effect
  end

  test "local profiles and legacy SSH startup still reach the identity gate" do
    for {profiles, worker} <- [{@profiles, %{}}, {nil, %{"ssh_hosts" => ["synthetic-legacy"]}}] do
      configure(profiles, worker)
      parent = self()

      assert {:stop, :linear_unauthorized} =
               Orchestrator.init(
                 identity_validator: fn ->
                   send(parent, :identity_effect)
                   {:error, :linear_unauthorized}
                 end
               )

      assert_received :identity_effect
    end
  end

  test "reload blocks the real poll and queued profile retry before fetch, claim or dispatch" do
    configure(@profiles, %{})
    assert :ok = Config.validate!()
    token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 2,
      profile_retry_attempts: %{"central-brain" => %{retry_token: token}},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    configure(@profiles, %{"ssh_hosts" => ["synthetic-han-wsl"]})
    assert settings_outcome() == :accepted
    assert {:noreply, polled} = Orchestrator.handle_info(:run_poll_cycle, state)
    assert polled.running == %{}
    assert polled.claimed == MapSet.new()
    if is_reference(polled.tick_timer_ref), do: Process.cancel_timer(polled.tick_timer_ref)

    assert {:noreply, retried} = Orchestrator.handle_info({:retry_project_profile, "central-brain", token}, state)
    assert retried.running == %{}
    assert retried.claimed == MapSet.new()
    refute_received :synthetic_ssh_effect
  end

  test "profile retry cannot bypass topology admission with previously accepted profiles" do
    configure(@profiles, %{})
    {:ok, settings} = Config.settings()
    token = make_ref()
    state = %Orchestrator.State{profile_retry_attempts: %{"central-brain" => %{retry_token: token, attempt: 1}}}
    configure(@profiles, %{"ssh_hosts" => ["synthetic-ssh"]})
    parent = self()

    retried =
      Orchestrator.retry_project_profile_for_test(state, settings.project_profiles, "central-brain", token,
        fetcher: fn _ ->
          send(parent, :profile_fetch_effect)
          {:ok, []}
        end
      )

    assert retried.running == %{}
    refute_received :profile_fetch_effect
  end

  test "issue retry defers without fetching or releasing existing ownership on unsupported topology" do
    configure(@profiles, %{})
    {:ok, settings} = Config.settings()
    profile = settings.project_profiles.profiles["central-brain"]
    token = make_ref()

    state = %Orchestrator.State{
      claimed: MapSet.new(["retry-topology"]),
      retry_attempts: %{
        "retry-topology" => %{
          attempt: 1,
          retry_token: token,
          identifier: "ARO-196-RETRY",
          project_profile: profile,
          ownership: :retained_owner
        }
      }
    }

    configure(@profiles, %{"ssh_hosts" => ["synthetic-ssh"]})
    parent = self()

    retried =
      Orchestrator.fire_issue_retry_for_test(state, "retry-topology", token,
        retry_fetch_fun: fn _, _ ->
          send(parent, :issue_fetch_effect)
          {:ok, []}
        end
      )

    refute_received :issue_fetch_effect
    assert retried.claimed == state.claimed
    assert retried.retry_attempts["retry-topology"].error =~ "profiled_ssh_topology_unsupported"
    Process.cancel_timer(retried.retry_attempts["retry-topology"].timer_ref)
  end

  test "rejected reload preserves active local reconciliation, ownership and poll timing" do
    configure(@profiles, %{})
    {:ok, settings} = Config.settings()
    profile = settings.project_profiles.profiles["central-brain"]
    issue = %Issue{id: "active-local", identifier: "ARO-196-ACTIVE", state: "In Progress", title: "before", project_id: profile.linear_project_id, project_profile: profile}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | title: "refreshed"}])
    started_at = DateTime.utc_now()
    entry = %{issue: issue, pid: self(), started_at: started_at, worker_host: nil}
    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), poll_interval_ms: 30_000, max_concurrent_agents: 2}
    configure(@profiles, %{"ssh_hosts" => ["synthetic-ssh"]})
    assert {:error, @reason} = Config.validate!()
    refute SymphonyElixir.ClaimService.enabled?()
    assert {:noreply, polled} = Orchestrator.handle_info(:run_poll_cycle, state)
    assert polled.running[issue.id].issue.title == "refreshed"
    assert polled.running[issue.id].pid == self()
    assert polled.running[issue.id].started_at == started_at
    assert polled.running[issue.id].worker_host == nil
    assert polled.claimed == state.claimed
    assert polled.poll_interval_ms == 30_000
    assert is_reference(polled.tick_timer_ref)
    Process.cancel_timer(polled.tick_timer_ref)
  end

  test "new profile poll does not call its fetcher after unsupported reload" do
    configure(@profiles, %{})
    {:ok, settings} = Config.settings()
    configure(@profiles, %{"ssh_hosts" => ["synthetic-ssh"]})
    parent = self()
    state = %Orchestrator.State{max_concurrent_agents: 2}

    result =
      Orchestrator.multi_project_dispatch_for_test(state, settings.project_profiles,
        fetcher: fn _ ->
          send(parent, :new_poll_effect)
          {:ok, []}
        end
      )

    assert result.running == %{}
    refute_received :new_poll_effect
  end

  test "reload during profile polling blocks candidate refresh before credential and claim gates" do
    configure(@profiles, %{})
    {:ok, settings} = Config.settings()
    profile = settings.project_profiles.profiles["central-brain"]
    issue = %Issue{id: "pending-local", identifier: "ARO-196-PENDING", state: "In Progress", project_id: profile.linear_project_id, project_profile: profile, repository: profile.repository}
    parent = self()
    state = %Orchestrator.State{max_concurrent_agents: 2}

    result =
      Orchestrator.multi_project_dispatch_for_test(state, settings.project_profiles,
        fetcher: fn
          %{key: "central-brain"} ->
            configure(@profiles, %{"ssh_hosts" => ["synthetic-ssh"]})
            {:ok, [issue]}

          _ ->
            {:ok, []}
        end,
        refresh_fun: fn _ ->
          send(parent, :candidate_refresh_effect)
          {:ok, []}
        end
      )

    assert result.running == %{}
    refute_received :candidate_refresh_effect
  end

  test "explicit remote assignment is blocked in actual AgentRunner before any credential callback" do
    configure(@profiles, %{})
    parent = self()
    profile = Map.new(@central, fn {key, value} -> {String.to_existing_atom(key), value} end)

    issue = %Issue{
      id: "local-topology",
      identifier: "ARO-196-TOPOLOGY",
      title: "Synthetic topology test",
      state: "In Progress",
      project_id: @central["linear_project_id"],
      project_profile: profile,
      repository: @central["repository"],
      routing_revision: 1,
      labels: []
    }

    for host <- ["synthetic-ssh", "synthetic-han-wsl"] do
      source = fn _ ->
        send(parent, :credential_effect)
        {:error, :credential_source_missing}
      end

      request = fn _ ->
        send(parent, :http_effect)
        {:error, :timeout}
      end

      assert :ok =
               AgentRunner.run(issue, self(),
                 worker_host: host,
                 credential_source: source,
                 worker_credential_source: source,
                 request_fun: request,
                 worker_authority_request_fun: request,
                 repository_bootstrap_command_runner: fn _, _, _ ->
                   send(parent, :bootstrap_effect)
                   {:error, :blocked}
                 end,
                 git_checkout_command_runner: fn _, _, _ ->
                   send(parent, :checkout_effect)
                   {:error, :blocked}
                 end
               )

      assert_received {:agent_hard_blocker, "local-topology", %{kind: {:project_credential_unavailable, @reason}}}
      refute_received :credential_effect
      refute_received :http_effect
      refute_received :bootstrap_effect
      refute_received :checkout_effect
      refute_received :synthetic_ssh_effect
    end
  end

  test "actual legacy runner still reaches the selected SSH transport" do
    configure(nil, %{"ssh_hosts" => ["synthetic-legacy"]})
    issue = %Issue{id: "legacy-topology", identifier: "LEGACY-1", title: "Synthetic legacy", labels: []}
    assert_raise RuntimeError, fn -> AgentRunner.run(issue, nil, worker_host: "synthetic-legacy") end
    assert_received :synthetic_ssh_effect
  end

  defp configure(profiles, worker) do
    config = %{
      "tracker" => %{"kind" => "memory", "api_key" => "synthetic-tracker", "assignee" => "synthetic-assignee"},
      "claim" => %{
        "enabled" => false,
        "database_url" => "synthetic-database",
        "ca_cert_file" => "synthetic-ca",
        "node_id" => "synthetic-node",
        "node_instance_id" => "synthetic-instance"
      },
      "worker" => worker,
      "workspace" => %{"root" => Path.join(System.tmp_dir!(), "synthetic-topology-workspaces")}
    }

    config = if profiles, do: Map.put(config, "project_profiles", profiles), else: config
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic workflow")
    assert :ok = WorkflowStore.force_reload()
  end

  defp settings_outcome do
    case Config.settings() do
      {:ok, _settings} -> :accepted
      {:error, @reason} -> {:error, @reason}
      {:error, _other} -> :other_config_error
    end
  end
end
