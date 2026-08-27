defmodule SymphonyElixir.MultiProjectDispatchTest do
  use SymphonyElixir.TestSupport

  @central_profile %{
    key: "central-brain",
    linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
    repository: "aroakpm-svg/aroak-central-brain",
    canonical_branch: "main",
    workspace_namespace: "central-brain",
    credential_ref: "github-central-brain",
    environment: "local_non_production"
  }
  @project_management_profile %{
    key: "project-management",
    linear_project_id: "708053e0-f42c-4e93-bec4-7abbb37e74af",
    repository: "aroakpm-svg/aroak-project-management",
    canonical_branch: "main",
    workspace_namespace: "project-management",
    credential_ref: "github-project-management",
    environment: "local_non_production"
  }
  @profiles %{
    version: 1,
    profiles: %{
      "central-brain" => @central_profile,
      "project-management" => @project_management_profile
    }
  }

  test "Amy, Matt, and Han each dispatch eligible candidates from both approved projects" do
    for node <- ~w(Amy Matt Han) do
      {:ok, events} = Agent.start_link(fn -> [] end)
      central = issue("#{node}-central", @central_profile, 1)
      project_management = issue("#{node}-pm", @project_management_profile, 2)

      state =
        run_cycle(
          [central, project_management],
          %{central.id => central, project_management.id => project_management},
          events,
          route_reader: fn refreshed ->
            record(events, {:route, node, refreshed.id})
            {:ok, %{routing_revision: 7}}
          end
        )

      assert Map.keys(state.running) |> Enum.sort() == Enum.sort([central.id, project_management.id])

      assert for({:claim, id} <- Agent.get(events, & &1), do: id) == [central.id, project_management.id]

      assert for({:dispatch, id, repository} <- Agent.get(events, & &1), do: {id, repository}) == [
               {central.id, @central_profile.repository},
               {project_management.id, @project_management_profile.repository}
             ]

      assert Agent.get(events, & &1) == [
               {:refresh, [central.id]},
               {:route, node, central.id},
               {:preflight, "central-brain"},
               {:claim, central.id},
               {:dispatch, central.id, @central_profile.repository},
               {:refresh, [project_management.id]},
               {:route, node, project_management.id},
               {:preflight, "project-management"},
               {:claim, project_management.id},
               {:dispatch, project_management.id, @project_management_profile.repository}
             ]
    end
  end

  test "wrong-node candidate does not block a later eligible candidate" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    first = issue("first-wrong-node", @central_profile, 1)
    later = issue("later-eligible", @project_management_profile, 2)

    state =
      run_cycle(
        [first, later],
        %{first.id => first, later.id => later},
        events,
        route_reader: fn
          %{id: "first-wrong-node"} -> {:ineligible, :wrong_node}
          %{id: "later-eligible"} -> {:ok, %{routing_revision: 8}}
        end
      )

    dispatched_ids = for {:dispatch, id, _repository} <- Agent.get(events, & &1), do: id
    claim_calls = for {:claim, id} <- Agent.get(events, & &1), do: id

    assert dispatched_ids == ["later-eligible"]
    assert claim_calls == ["later-eligible"]
    assert Map.has_key?(state.running, "later-eligible")
  end

  test "one profile timeout schedules only that profile for retry and dispatches the other" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    later = issue("pm-after-central-timeout", @project_management_profile, 1)

    fetcher = fn
      %{key: "central-brain"} ->
        Process.sleep(50)
        {:ok, []}

      %{key: "project-management"} ->
        {:ok, [later]}
    end

    state =
      Orchestrator.multi_project_dispatch_for_test(
        base_state(),
        @profiles,
        dispatch_opts(fetcher, %{later.id => later}, events, poll_timeout: 5)
      )

    assert for({:claim, id} <- Agent.get(events, & &1), do: id) == [later.id]
    assert %{attempt: 1, reason: :poll_timeout} = state.profile_retry_attempts["central-brain"]
    refute Map.has_key?(state.profile_retry_attempts, "project-management")
  end

  test "duplicate Linear UUID across projects produces zero claims" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    central = issue("duplicate-id", @central_profile, 1)
    project_management = issue("duplicate-id", @project_management_profile, 1)

    state =
      run_cycle(
        [central, project_management],
        %{},
        events,
        refresh_fun: fn _ids -> flunk("ambiguous candidates must not be refreshed") end
      )

    assert state.running == %{}
    assert for({:claim, id} <- Agent.get(events, & &1), do: id) == []
  end

  test "stale refresh produces zero claims and stops before routing" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    candidate = issue("stale-after-refresh", @central_profile, 1)
    stale = %{candidate | state: "Done"}

    state =
      run_cycle(
        [candidate],
        %{candidate.id => stale},
        events,
        route_reader: fn _issue -> flunk("stale issues must not read routing") end
      )

    assert state.running == %{}
    assert for({:claim, id} <- Agent.get(events, & &1), do: id) == []
  end

  test "repository preflight blocker produces zero claims" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    candidate = issue("wrong-repository", @central_profile, 1)

    state =
      run_cycle(
        [candidate],
        %{candidate.id => candidate},
        events,
        preflight_fun: fn profile ->
          record(events, {:preflight, profile.key})
          {:blocked, %{code: :repository_mismatch}}
        end
      )

    assert state.running == %{}
    assert {:preflight, "central-brain"} in Agent.get(events, & &1)
    assert for({:claim, id} <- Agent.get(events, & &1), do: id) == []
  end

  test "multi-project mode fails closed when the claim service is disabled" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    candidate = issue("claim-service-required", @central_profile, 1)

    opts =
      fn profile ->
        {:ok, if(profile.key == "central-brain", do: [candidate], else: [])}
      end
      |> dispatch_opts(%{candidate.id => candidate}, events, [])
      |> Keyword.delete(:route_reader)
      |> Keyword.put(:preflight_fun, fn _profile ->
        flunk("preflight must not run without exclusive claim-service routing")
      end)
      |> Keyword.put(:claim_fun, fn _issue, _owner ->
        flunk("claim must not run without exclusive claim-service routing")
      end)

    state = Orchestrator.multi_project_dispatch_for_test(base_state(), @profiles, opts)

    assert state.running == %{}
    assert %{reason: :routing_unavailable} = state.profile_retry_attempts["central-brain"]
  end

  test "authorized candidates still use the existing node-wide capacity check before claim" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    candidate = issue("capacity-waits", @central_profile, 1)

    full_state = %{
      base_state()
      | max_concurrent_agents: 1,
        running: %{"already-running" => %{issue: issue("already-running", @central_profile, 1)}}
    }

    fetcher = fn profile ->
      {:ok, if(profile.key == "central-brain", do: [candidate], else: [])}
    end

    state =
      Orchestrator.multi_project_dispatch_for_test(
        full_state,
        @profiles,
        dispatch_opts(fetcher, %{candidate.id => candidate}, events, [])
      )

    assert Map.keys(state.running) == ["already-running"]

    assert Agent.get(events, & &1) == [
             {:refresh, [candidate.id]},
             {:route, candidate.id},
             {:preflight, "central-brain"}
           ]
  end

  test "transient Linear and routing failures recover on profile timers without process exit" do
    for failure <- [:linear, :routing] do
      {:ok, events} = Agent.start_link(fn -> [] end)
      {:ok, fetch_attempts} = Agent.start_link(fn -> 0 end)
      {:ok, route_attempts} = Agent.start_link(fn -> 0 end)
      candidate = issue("#{failure}-recovery", @central_profile, 1)
      parent = self()

      process =
        spawn(fn ->
          fetcher = fn
            %{key: "central-brain"} ->
              attempt = Agent.get_and_update(fetch_attempts, &{&1 + 1, &1 + 1})

              if failure == :linear and attempt == 1,
                do: {:error, :temporary_linear_failure},
                else: {:ok, [candidate]}

            %{key: "project-management"} ->
              {:ok, []}
          end

          route_reader = fn _issue ->
            attempt = Agent.get_and_update(route_attempts, &{&1 + 1, &1 + 1})

            if failure == :routing and attempt == 1,
              do: {:error, :claim_service_unavailable},
              else: {:ok, %{routing_revision: 9}}
          end

          opts = dispatch_opts(fetcher, %{candidate.id => candidate}, events, route_reader: route_reader)
          failed_state = Orchestrator.multi_project_dispatch_for_test(base_state(), @profiles, opts)
          send(parent, {:failed_round, self(), failed_state})

          receive do
            {:retry, retry_token} ->
              recovered_state =
                Orchestrator.retry_project_profile_for_test(
                  failed_state,
                  @profiles,
                  "central-brain",
                  retry_token,
                  opts
                )

              send(parent, {:recovered_round, self(), recovered_state})
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:failed_round, ^process, failed_state}, 1_000
      assert Process.alive?(process)
      retry = failed_state.profile_retry_attempts["central-brain"]
      assert %{attempt: 1, retry_token: retry_token} = retry

      send(process, {:retry, retry_token})
      assert_receive {:recovered_round, ^process, recovered_state}, 1_000
      assert Process.alive?(process)
      assert Map.has_key?(recovered_state.running, candidate.id)
      assert for({:claim, id} <- Agent.get(events, & &1), do: id) == [candidate.id]
      refute Map.has_key?(recovered_state.profile_retry_attempts, "central-brain")

      send(process, :stop)
    end
  end

  test "profile retry delay is bounded exponential backoff with jitter" do
    first_delay = Orchestrator.profile_retry_delay_for_test(1)
    second_delay = Orchestrator.profile_retry_delay_for_test(2)

    assert first_delay in 750..1_000
    assert second_delay in 1_500..2_000

    write_workflow_file!(Workflow.workflow_file_path(), max_retry_backoff_ms: 1_200)
    bounded_delay = Orchestrator.profile_retry_delay_for_test(20)
    assert bounded_delay in 900..1_200
  end

  defp run_cycle(candidates, refreshed_by_id, events, overrides) do
    fetcher = fn profile ->
      {:ok, Enum.filter(candidates, &(&1.project_id == profile.linear_project_id))}
    end

    Orchestrator.multi_project_dispatch_for_test(
      base_state(),
      @profiles,
      dispatch_opts(fetcher, refreshed_by_id, events, overrides)
    )
  end

  defp dispatch_opts(fetcher, refreshed_by_id, events, overrides) do
    defaults = [
      fetcher: fetcher,
      refresh_fun: fn issue_ids ->
        record(events, {:refresh, issue_ids})
        {:ok, Enum.map(issue_ids, &Map.fetch!(refreshed_by_id, &1))}
      end,
      route_reader: fn issue ->
        record(events, {:route, issue.id})
        {:ok, %{routing_revision: 7}}
      end,
      preflight_fun: fn profile ->
        record(events, {:preflight, profile.key})
        {:ok, %{repository: profile.repository}}
      end,
      claim_fun: fn issue, owner ->
        assert owner == self()
        record(events, {:claim, issue.id})
        {:ok, %{claim_id: "claim-#{issue.id}", generation: 1}}
      end,
      dispatch_fun: fn state, issue, _attempt, _recipient, _worker_host, _claim ->
        record(events, {:dispatch, issue.id, issue.repository})

        running_entry = %{
          issue: issue,
          identifier: issue.identifier,
          pid: self(),
          ref: make_ref(),
          started_at: DateTime.utc_now()
        }

        %{state | running: Map.put(state.running, issue.id, running_entry)}
      end,
      timer_fun: fn message, delay_ms ->
        record(events, {:timer, message, delay_ms})
        make_ref()
      end,
      retry_delay_fun: fn _attempt -> 25 end,
      poll_timeout: 25
    ]

    Keyword.merge(defaults, overrides)
  end

  defp base_state do
    %Orchestrator.State{
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp issue(id, profile, priority) do
    %Issue{
      id: id,
      identifier: String.upcase(id),
      title: "Dispatch #{id}",
      priority: priority,
      state: "In Progress",
      labels: ["symphony-worker"],
      assigned_to_worker: true,
      project_id: profile.linear_project_id,
      project_slug: profile.key,
      project_profile: nil,
      repository: nil,
      blocked_by: [],
      created_at: DateTime.from_unix!(priority)
    }
  end

  defp record(agent, event), do: Agent.update(agent, &(&1 ++ [event]))
end
