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

  for stage <- [:refresh, :route, :preflight, :claim], failure <- [:raise, :throw, :exit] do
    test "isolates #{failure} from the first candidate's #{stage} callback" do
      stage = unquote(stage)
      failure = unquote(failure)
      {:ok, events} = Agent.start_link(fn -> [] end)
      first = issue("first-#{stage}-#{failure}", @central_profile, 1)
      later = issue("later-#{stage}-#{failure}", @project_management_profile, 2)
      refreshed_by_id = %{first.id => first, later.id => later}

      overrides = callback_failure_overrides(stage, failure, first, refreshed_by_id, events)
      state = run_cycle([first, later], refreshed_by_id, events, overrides)

      assert for({:dispatch, id, _repository} <- Agent.get(events, & &1), do: id) == [later.id]
      assert Map.has_key?(state.running, later.id)

      assert %{attempt: 1, reason: :candidate_failure} =
               state.profile_retry_attempts["central-brain"]
    end
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

  test "production multi-project entry performs authorization gates at full capacity before skipping claim" do
    configure_multi_project_memory_tracker!()
    {:ok, events} = Agent.start_link(fn -> [] end)
    running_issue = issue("already-running-production", @central_profile, 1)
    candidate = issue("capacity-waits-production", @project_management_profile, 2)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [running_issue])

    full_state = %{
      base_state()
      | max_concurrent_agents: 1,
        running: %{
          running_issue.id => %{
            issue: running_issue,
            identifier: running_issue.identifier,
            pid: self(),
            ref: make_ref(),
            started_at: DateTime.utc_now()
          }
        }
    }

    fetcher = fn profile ->
      record(events, {:fetch, profile.key})
      {:ok, if(profile.key == "project-management", do: [candidate], else: [])}
    end

    state =
      Orchestrator.maybe_dispatch_for_test(
        full_state,
        dispatch_opts(fetcher, %{candidate.id => candidate}, events, [])
      )

    assert Map.keys(state.running) == [running_issue.id]

    assert for({:fetch, profile} <- Agent.get(events, & &1), do: profile) |> Enum.sort() == [
             "central-brain",
             "project-management"
           ]

    assert Enum.reject(Agent.get(events, & &1), &match?({:fetch, _profile}, &1)) == [
             {:refresh, [candidate.id]},
             {:route, candidate.id},
             {:preflight, "project-management"}
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

  test "normal and abnormal issue retry tokens re-enter the full pipeline exactly once" do
    for {kind, attempt, profile} <- [
          {:normal, 1, @central_profile},
          {:abnormal, 3, @project_management_profile}
        ] do
      {:ok, events} = Agent.start_link(fn -> [] end)
      candidate = %{issue("#{kind}-token", profile, attempt) | project_profile: profile}
      {state, token} = issue_retry_state(candidate, attempt)

      opts =
        dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => candidate}, events,
          project_profiles: @profiles,
          retry_fetch_fun: fn issue_id, metadata ->
            record(events, {:retry_fetch, issue_id, metadata.project_profile.key})
            {:ok, [candidate]}
          end,
          profile_refresh_fun: fn [issue_id] ->
            record(events, {:profile_refresh, issue_id, profile.key})
            {:ok, [candidate]}
          end
        )

      before_token =
        Orchestrator.multi_project_dispatch_for_test(
          state,
          @profiles,
          dispatch_opts(
            fn profile_arg ->
              {:ok, if(profile_arg.key == profile.key, do: [candidate], else: [])}
            end,
            %{candidate.id => candidate},
            events,
            []
          )
        )

      assert before_token.retry_attempts == state.retry_attempts
      assert before_token.running == %{}
      refute Enum.any?(Agent.get(events, & &1), &match?({:claim, _id}, &1))

      dispatched = Orchestrator.fire_issue_retry_for_test(before_token, candidate.id, token, opts)
      duplicate = Orchestrator.fire_issue_retry_for_test(dispatched, candidate.id, token, opts)

      assert Map.has_key?(dispatched.running, candidate.id), inspect(Agent.get(events, & &1))
      assert duplicate == dispatched
      assert for({:claim, id} <- Agent.get(events, & &1), do: id) == [candidate.id]
      assert {:retry_fetch, candidate.id, profile.key} in Agent.get(events, & &1)
      assert {:profile_refresh, candidate.id, profile.key} in Agent.get(events, & &1)
    end
  end

  test "capacity backoff after a fired issue retry schedules a new token" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    candidate = %{issue("capacity-token", @central_profile, 1) | project_profile: @central_profile}
    blocker = issue("capacity-blocker", @project_management_profile, 1)
    {state, token} = issue_retry_state(candidate, 1)

    state = %{
      state
      | max_concurrent_agents: 1,
        running: %{
          blocker.id => %{
            issue: blocker,
            identifier: blocker.identifier,
            pid: self(),
            ref: make_ref(),
            started_at: DateTime.utc_now()
          }
        }
    }

    opts =
      dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => candidate}, events,
        project_profiles: @profiles,
        retry_fetch_fun: fn _issue_id, _metadata -> {:ok, [candidate]} end,
        profile_refresh_fun: fn _ids -> {:ok, [candidate]} end
      )

    backed_off = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)

    assert %{attempt: 2, retry_token: next_token} = backed_off.retry_attempts[candidate.id],
           inspect(Agent.get(events, & &1))

    assert is_reference(next_token) and next_token != token
    refute Map.has_key?(backed_off.running, candidate.id)
    refute Enum.any?(Agent.get(events, & &1), &match?({:claim, _id}, &1))
  end

  test "unowned retry preserves its pending backoff across every capacity boundary" do
    for capacity <- [:global, :state, :worker] do
      workflow_overrides =
        case capacity do
          :global -> [max_concurrent_agents: 1]
          :state -> [max_concurrent_agents: 2, max_concurrent_agents_by_state: %{"in progress" => 1}]
          :worker -> [max_concurrent_agents: 2, worker_ssh_hosts: ["host-a"], worker_max_concurrent_agents_per_host: 1]
        end

      write_workflow_file!(Workflow.workflow_file_path(), workflow_overrides)
      assert :ok = WorkflowStore.force_reload()

      {:ok, events} = Agent.start_link(fn -> [] end)
      candidate = %{issue("unowned-capacity-#{capacity}", @central_profile, 1) | project_profile: @central_profile}
      blocker = issue("unowned-blocker-#{capacity}", @project_management_profile, 2)
      {owned_state, token} = issue_retry_state(candidate, 1)

      retry_entry =
        owned_state.retry_attempts[candidate.id]
        |> Map.put(:ownership, :unowned_backoff)
        |> Map.put(:worker_host, if(capacity == :worker, do: "host-a"))

      state = %{
        owned_state
        | claimed: MapSet.new(),
          retry_attempts: %{candidate.id => retry_entry},
          running: %{
            blocker.id => %{
              issue: blocker,
              identifier: blocker.identifier,
              pid: self(),
              ref: make_ref(),
              worker_host: if(capacity == :worker, do: "host-a"),
              started_at: DateTime.utc_now()
            }
          }
      }

      opts =
        dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => candidate}, events,
          project_profiles: @profiles,
          retry_fetch_fun: fn _issue_id, _metadata -> {:ok, [candidate]} end,
          profile_refresh_fun: fn _ids -> {:ok, [candidate]} end,
          task_start_fun: fn _task_fun -> {:ok, self()} end,
          bind_worker_fun: fn _issue_id, _pid -> :ok end,
          claim_fun: fn _issue, _owner -> flunk("capacity-blocked unowned retry must not claim") end
        )
        |> Keyword.delete(:dispatch_fun)

      backed_off = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)

      assert %{attempt: 2, ownership: :unowned_backoff, retry_token: next_token} =
               backed_off.retry_attempts[candidate.id]

      refute MapSet.member?(backed_off.claimed, candidate.id)
      refute Orchestrator.should_dispatch_issue_for_test(candidate, backed_off)

      recovered_opts =
        Keyword.put(opts, :claim_fun, fn _issue, _owner ->
          record(events, {:fresh_claim, capacity})
          {:ok, %{claim_id: "fresh", generation: 2}}
        end)

      recovered =
        backed_off
        |> Map.put(:running, %{})
        |> Orchestrator.fire_issue_retry_for_test(candidate.id, next_token, recovered_opts)

      assert Map.has_key?(recovered.running, candidate.id), inspect({capacity, recovered, Agent.get(events, & &1)})
      assert MapSet.member?(recovered.claimed, candidate.id), inspect({capacity, recovered, Agent.get(events, & &1)})
      assert Agent.get(events, & &1) |> Enum.count(&match?({:fresh_claim, ^capacity}, &1)) == 1
    end
  end

  test "current profile drift on a fired retry fails closed before dispatch" do
    {:ok, events} = Agent.start_link(fn -> [] end)

    candidate = %{
      issue("profile-drift-token", @central_profile, 1)
      | project_profile: @central_profile
    }

    {state, token} = issue_retry_state(candidate, 1)

    drifted = %{
      issue("profile-drift-token", @project_management_profile, 2)
      | project_profile: @project_management_profile
    }

    opts =
      dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => drifted}, events,
        project_profiles: @profiles,
        retry_fetch_fun: fn _issue_id, _metadata -> {:ok, [candidate]} end,
        profile_refresh_fun: fn _ids -> {:ok, [drifted]} end,
        claim_release_fun: fn state_arg, issue_id ->
          record(events, {:release, issue_id})
          %{state_arg | claimed: MapSet.delete(state_arg.claimed, issue_id)}
        end
      )

    result = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)

    refute Map.has_key?(result.running, candidate.id)
    refute Map.has_key?(result.retry_attempts, candidate.id)
    refute Enum.any?(Agent.get(events, & &1), &match?({:claim, _id}, &1))
    refute MapSet.member?(result.claimed, candidate.id), inspect(Agent.get(events, & &1))
    assert {:release, candidate.id} in Agent.get(events, & &1)
  end

  test "post-pop transient retry outcomes retain ownership and schedule a new token" do
    for transient <- [:initial_fetch, :refresh, :route, :preflight_unavailable, :preflight_blocked] do
      {:ok, events} = Agent.start_link(fn -> [] end)

      candidate = %{
        issue("#{transient}-pending", @central_profile, 1)
        | project_profile: @central_profile
      }

      {state, token} = issue_retry_state(candidate, 1)

      overrides =
        [
          project_profiles: @profiles,
          retry_fetch_fun: fn _issue_id, _metadata ->
            if transient == :initial_fetch, do: {:error, :transport}, else: {:ok, [candidate]}
          end,
          profile_refresh_fun: fn _ids ->
            if transient == :refresh, do: {:error, :transport}, else: {:ok, [candidate]}
          end,
          route_reader: fn _issue ->
            if transient == :route,
              do: {:error, :claim_service_unavailable},
              else: {:ok, %{routing_revision: 7}}
          end,
          preflight_fun: fn _profile ->
            case transient do
              :preflight_unavailable -> {:error, :transport}
              :preflight_blocked -> {:blocked, %{code: :repository_unavailable}}
              _ -> {:ok, %{repository: @central_profile.repository}}
            end
          end,
          claim_release_fun: fn _state_arg, _issue_id -> flunk("transient retry released ownership") end
        ]

      opts = dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => candidate}, events, overrides)
      result = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)

      assert %{attempt: 2, ownership: :retained_owner, retry_token: next_token} =
               result.retry_attempts[candidate.id]

      assert is_reference(next_token) and next_token != token
      assert MapSet.member?(result.claimed, candidate.id)
      refute Map.has_key?(result.running, candidate.id)
    end
  end

  test "permanent and unknown preflight blockers release ownership without rescheduling" do
    blockers = [
      :project_mapping_missing,
      :repository_mismatch,
      :default_branch_mismatch,
      :required_check_contract_invalid,
      :required_check_contract_missing,
      :unknown_preflight_blocker
    ]

    for blocker <- blockers do
      {:ok, events} = Agent.start_link(fn -> [] end)
      candidate = %{issue("#{blocker}-pending", @central_profile, 1) | project_profile: @central_profile}
      {state, token} = issue_retry_state(candidate, 1)

      opts =
        dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => candidate}, events,
          project_profiles: @profiles,
          retry_fetch_fun: fn _issue_id, _metadata -> {:ok, [candidate]} end,
          profile_refresh_fun: fn _ids -> {:ok, [candidate]} end,
          preflight_fun: fn _profile -> {:blocked, %{code: blocker}} end,
          claim_release_fun: fn state_arg, issue_id ->
            record(events, {:release, issue_id})
            %{state_arg | claimed: MapSet.delete(state_arg.claimed, issue_id)}
          end
        )

      result = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)

      refute MapSet.member?(result.claimed, candidate.id)
      refute Map.has_key?(result.retry_attempts, candidate.id)
      assert {:release, candidate.id} in Agent.get(events, & &1)
    end
  end

  test "real preflight failures retain only transient retries and release permanent blockers" do
    source = fn ref -> {:ok, %{credential_ref: ref, token: "pr48-synthetic-token", expires_at: nil}} end

    expired_source = fn ref ->
      {:ok, %{credential_ref: ref, token: "synthetic", expires_at: ~U[2000-01-01 00:00:00Z]}}
    end

    repository = %{"full_name" => @central_profile.repository, "default_branch" => "main"}
    no_pull = Map.put(repository, "permissions", %{"pull" => false, "push" => true})
    no_push = Map.put(repository, "permissions", %{"pull" => true, "push" => false})
    human_actor = preflight_contract_request(:actor, %{"data" => %{"viewer" => %{"login" => "human"}}})

    cases = [
      {[profile: %{}], :project_mapping_missing, :permanent},
      {[credential_source: nil], :credential_source_unconfigured, :permanent},
      {[credential_source: fn _ -> {:error, :missing} end], :credential_source_missing, :permanent},
      {[credential_source: fn _ -> {:error, :conflict} end], :credential_source_conflict, :permanent},
      {[credential_source: fn _ -> {:ok, %{credential_ref: "github-project-management"}} end], :credential_reference_mismatch, :permanent},
      {[credential_source: expired_source], :credential_expired, :permanent},
      {[credential_source: fn _ -> {:ok, %{}} end], :credential_resolver_failed, :permanent},
      {[expected_actor: nil], :github_authority_invalid, :permanent},
      {[request_fun: preflight_contract_request(:repository, no_pull)], :github_pull_authority_missing, :permanent},
      {[request_fun: preflight_contract_request(:repository, no_push)], :github_push_authority_missing, :permanent},
      {[request_fun: preflight_contract_request(:package, "not-json")], :required_check_contract_invalid, :permanent},
      {[request_fun: preflight_contract_request(:package, %{"scripts" => %{}})], :required_check_contract_missing, :permanent},
      {[request_fun: preflight_contract_request(:package, nil, 404)], :required_check_contract_unreadable, :transient},
      {[request_fun: fn _ -> {:ok, %{status: 401}} end], :github_unauthorized, :permanent},
      {[request_fun: fn _ -> {:ok, %{status: 403}} end], :github_forbidden, :permanent},
      {[request_fun: fn _ -> {:ok, %{status: 404}} end], :github_repository_not_allowed, :permanent},
      {[request_fun: fn _ -> {:ok, %{status: 500}} end], :github_unavailable, :transient},
      {[request_fun: fn _ -> {:error, :timeout} end], :github_unavailable, :transient},
      {[request_fun: fn _ -> {:ok, %{status: 200, body: %{}}} end], :github_response_invalid, :permanent},
      {[request_fun: human_actor], :github_unexpected_actor, :permanent}
    ]

    for {overrides, code, classification} <- cases do
      producer_opts = Keyword.merge([credential_source: source, expected_actor: "automation[bot]"], overrides)
      profile = Keyword.get(overrides, :profile, @central_profile)
      assert {:blocked, %{code: ^code} = blocker} = SymphonyElixir.ProjectRepoPreflight.check(profile, producer_opts)
      assert Orchestrator.preflight_blocker_classification_for_test(code) == classification

      {:ok, events} = Agent.start_link(fn -> [] end)
      candidate = %{issue("producer-#{code}", @central_profile, 1) | project_profile: @central_profile}
      {state, token} = issue_retry_state(candidate, 1)

      opts =
        dispatch_opts(fn _ -> {:ok, []} end, %{candidate.id => candidate}, events,
          project_profiles: @profiles,
          retry_fetch_fun: fn _, _ -> {:ok, [candidate]} end,
          profile_refresh_fun: fn _ -> {:ok, [candidate]} end,
          preflight_fun: fn _ -> {:blocked, blocker} end,
          claim_release_fun: fn state, id -> %{state | claimed: MapSet.delete(state.claimed, id)} end
        )

      result = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)
      assert Map.has_key?(result.retry_attempts, candidate.id) == (classification == :transient)
      assert MapSet.member?(result.claimed, candidate.id) == (classification == :transient)
      refute Map.has_key?(result.running, candidate.id)
    end
  end

  test "claim loss retires a pending retry so its stale token cannot fetch or reschedule" do
    candidate = %{
      issue("lost-pending", @central_profile, 1)
      | project_profile: @central_profile,
        repository: @central_profile.repository,
        routing_revision: 1
    }

    assert {:ok, execution_context} = SymphonyElixir.ProjectExecutionContext.from_issue(candidate)

    assert {:ok, %{path: workspace_path, workspace_attestation: workspace_attestation}} =
             Workspace.prepare_for_issue(candidate, nil, execution_context)

    {state, token} = issue_retry_state(candidate, 1)

    state =
      put_in(
        state.retry_attempts[candidate.id],
        Map.merge(state.retry_attempts[candidate.id], %{
          execution_context: execution_context,
          workspace_attestation: workspace_attestation,
          worker_host: nil
        })
      )

    retired = Orchestrator.retire_lost_claim_for_test(state, candidate.id)

    refute MapSet.member?(retired.claimed, candidate.id)
    refute Map.has_key?(retired.retry_attempts, candidate.id)
    refute File.exists?(workspace_path)

    assert retired ==
             Orchestrator.fire_issue_retry_for_test(retired, candidate.id, token,
               retry_fetch_fun: fn _issue_id, _metadata ->
                 flunk("stale claim-loss retry fetched and could reschedule")
               end
             )
  end

  test "authorized retry failure schedulers preserve the approved profile context" do
    for failure <- [:spawn, :bind] do
      {:ok, events} = Agent.start_link(fn -> [] end)
      candidate = %{issue("#{failure}-context", @central_profile, 1) | project_profile: @central_profile}
      {state, token} = issue_retry_state(candidate, 1)

      overrides =
        [
          project_profiles: @profiles,
          retry_fetch_fun: fn _id, _metadata -> {:ok, [candidate]} end,
          profile_refresh_fun: fn _ids -> {:ok, [candidate]} end,
          dispatch_fun: nil,
          claim_fun: fn _issue, _owner -> {:ok, %{claim_id: "claim", generation: 1}} end,
          task_start_fun: fn _fun ->
            if failure == :spawn,
              do: {:error, :spawn_failed},
              else: {:ok, spawn(fn -> Process.sleep(:infinity) end)}
          end,
          bind_worker_fun: fn _issue_id, _pid -> if failure == :bind, do: {:error, :bind_failed}, else: :ok end,
          terminate_task_fun: fn _pid -> :ok end,
          finalize_claim_fun: fn _issue_id, _action -> :ok end
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      opts =
        dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => candidate}, events, overrides)
        |> Keyword.delete(:dispatch_fun)

      result = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)

      assert %{
               project_profile: %{key: "central-brain"},
               ownership: :unowned_backoff,
               retry_token: next_token
             } =
               result.retry_attempts[candidate.id]

      refute MapSet.member?(result.claimed, candidate.id)
      refute Orchestrator.should_dispatch_issue_for_test(candidate, result)

      retried =
        opts
        |> Keyword.put(:retry_fetch_fun, fn _id, metadata ->
          assert %{project_profile: %{key: "central-brain"}, ownership: :unowned_backoff} = metadata
          {:ok, [candidate]}
        end)
        |> Keyword.put(:task_start_fun, fn _fun -> {:ok, self()} end)
        |> Keyword.put(:bind_worker_fun, fn _issue_id, _pid -> :ok end)
        |> Keyword.put(:claim_fun, fn _issue, _owner ->
          record(events, {:fresh_claim, failure})
          {:ok, %{claim_id: "fresh", generation: 2}}
        end)
        |> then(&Orchestrator.fire_issue_retry_for_test(result, candidate.id, next_token, &1))

      assert Map.has_key?(retried.running, candidate.id)
      assert MapSet.member?(retried.claimed, candidate.id)
      assert {:fresh_claim, failure} in Agent.get(events, & &1)
    end
  end

  test "claim rejection ends owned retry and ordinary poll can freshly authorize and claim" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    candidate = %{issue("claim-reacquire", @central_profile, 1) | project_profile: @central_profile}
    {state, token} = issue_retry_state(candidate, 1)

    rejected_opts =
      dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => candidate}, events,
        project_profiles: @profiles,
        retry_fetch_fun: fn _id, _metadata -> {:ok, [candidate]} end,
        profile_refresh_fun: fn _ids -> {:ok, [candidate]} end,
        claim_fun: fn _issue, _owner -> {:error, :claim_timeout} end,
        claim_release_fun: fn state_arg, issue_id ->
          record(events, {:release, issue_id})
          %{state_arg | claimed: MapSet.delete(state_arg.claimed, issue_id)}
        end
      )

    rejected = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, rejected_opts)
    refute MapSet.member?(rejected.claimed, candidate.id)
    refute Map.has_key?(rejected.retry_attempts, candidate.id)

    recovered =
      Orchestrator.multi_project_dispatch_for_test(
        rejected,
        @profiles,
        dispatch_opts(
          fn profile -> {:ok, if(profile.key == "central-brain", do: [candidate], else: [])} end,
          %{candidate.id => candidate},
          events,
          []
        )
      )

    assert Map.has_key?(recovered.running, candidate.id)
    assert {:release, candidate.id} in Agent.get(events, & &1)
    assert Enum.count(Agent.get(events, & &1), &match?({:claim, "claim-reacquire"}, &1)) == 1
  end

  test "initial spawn and bind failures back off unowned then fire through a fresh atomic claim" do
    for failure <- [:spawn, :bind] do
      {:ok, events} = Agent.start_link(fn -> [] end)
      candidate = %{issue("initial-#{failure}", @central_profile, 1) | project_profile: @central_profile}

      opts =
        dispatch_opts(
          fn profile -> {:ok, if(profile.key == "central-brain", do: [candidate], else: [])} end,
          %{candidate.id => candidate},
          events,
          project_profiles: @profiles,
          task_start_fun: fn _fun ->
            if failure == :spawn,
              do: {:error, :spawn_failed},
              else: {:ok, spawn(fn -> Process.sleep(:infinity) end)}
          end,
          bind_worker_fun: fn _id, _pid -> if failure == :bind, do: {:error, :bind_failed}, else: :ok end,
          terminate_task_fun: fn _pid -> :ok end,
          finalize_claim_fun: fn _id, _action -> :ok end
        )
        |> Keyword.delete(:dispatch_fun)

      failed = Orchestrator.multi_project_dispatch_for_test(base_state(), @profiles, opts)

      assert %{ownership: :unowned_backoff, retry_token: token} = failed.retry_attempts[candidate.id]
      refute MapSet.member?(failed.claimed, candidate.id)

      recovered_opts =
        opts
        |> Keyword.put(:retry_fetch_fun, fn _id, _metadata -> {:ok, [candidate]} end)
        |> Keyword.put(:profile_refresh_fun, fn _ids -> {:ok, [candidate]} end)
        |> Keyword.put(:task_start_fun, fn _fun -> {:ok, self()} end)
        |> Keyword.put(:bind_worker_fun, fn _id, _pid -> :ok end)
        |> Keyword.put(:claim_fun, fn _issue, _owner ->
          record(events, {:fresh_claim, failure})
          {:ok, %{claim_id: "fresh", generation: 2}}
        end)

      recovered = Orchestrator.fire_issue_retry_for_test(failed, candidate.id, token, recovered_opts)
      assert Map.has_key?(recovered.running, candidate.id), inspect({recovered, Agent.get(events, & &1)})
      assert MapSet.member?(recovered.claimed, candidate.id)
      assert {:fresh_claim, failure} in Agent.get(events, & &1)
    end
  end

  test "post-acquisition dispatch raise, exit, and throw release then retry through a fresh claim" do
    for failure <- [:raise, :exit, :throw] do
      {:ok, events} = Agent.start_link(fn -> [] end)
      candidate = %{issue("post-claim-#{failure}", @central_profile, 1) | project_profile: @central_profile}

      opts =
        dispatch_opts(
          fn profile -> {:ok, if(profile.key == "central-brain", do: [candidate], else: [])} end,
          %{candidate.id => candidate},
          events,
          project_profiles: @profiles,
          finalize_claim_fun: fn issue_id, action ->
            record(events, {:finalize, issue_id, action})
            :ok
          end,
          dispatch_fun: fn _state, _issue, _attempt, _recipient, _host, _claim ->
            case failure do
              :raise -> raise "dispatch failed"
              :exit -> exit(:dispatch_failed)
              :throw -> throw(:dispatch_failed)
            end
          end
        )

      failed = Orchestrator.multi_project_dispatch_for_test(base_state(), @profiles, opts)

      assert {:finalize, candidate.id, :release} in Agent.get(events, & &1)
      assert Enum.count(Agent.get(events, & &1), &match?({:finalize, _, :release}, &1)) == 1
      assert %{ownership: :unowned_backoff, retry_token: token} = failed.retry_attempts[candidate.id]
      refute MapSet.member?(failed.claimed, candidate.id)

      recovered_opts =
        opts
        |> Keyword.delete(:dispatch_fun)
        |> Keyword.put(:retry_fetch_fun, fn _id, _metadata -> {:ok, [candidate]} end)
        |> Keyword.put(:profile_refresh_fun, fn _ids -> {:ok, [candidate]} end)
        |> Keyword.put(:task_start_fun, fn _fun -> {:ok, self()} end)
        |> Keyword.put(:bind_worker_fun, fn _id, _pid -> :ok end)
        |> Keyword.put(:claim_fun, fn _issue, _owner ->
          record(events, {:fresh_claim, failure})
          {:ok, %{claim_id: "fresh", generation: 2}}
        end)

      recovered = Orchestrator.fire_issue_retry_for_test(failed, candidate.id, token, recovered_opts)
      assert Map.has_key?(recovered.running, candidate.id)
      assert MapSet.member?(recovered.claimed, candidate.id)
      assert {:fresh_claim, failure} in Agent.get(events, & &1)
    end
  end

  test "cleanup finalize and backoff failures fail closed without a second finalize" do
    for stage <- [:finalize, :backoff], failure <- [:raise, :exit, :throw] do
      {:ok, events} = Agent.start_link(fn -> [] end)
      {:ok, worker_holder} = Agent.start_link(fn -> nil end)
      candidate = %{issue("cleanup-#{stage}-#{failure}", @central_profile, 1) | project_profile: @central_profile}

      fail = fn ->
        case failure do
          :raise -> raise "cleanup failed"
          :exit -> exit(:cleanup_failed)
          :throw -> throw(:cleanup_failed)
        end
      end

      opts =
        dispatch_opts(
          fn profile -> {:ok, if(profile.key == "central-brain", do: [candidate], else: [])} end,
          %{candidate.id => candidate},
          events,
          project_profiles: @profiles,
          task_start_fun: fn _task_fun ->
            worker = spawn(fn -> receive do: (:stop -> :ok) end)
            worker_ref = Process.monitor(worker)
            Agent.update(worker_holder, fn _ -> {worker, worker_ref} end)
            {:ok, worker}
          end,
          bind_worker_fun: fn _id, _pid -> {:error, :bind_failed} end,
          terminate_task_fun: fn _pid -> :ok end,
          finalize_claim_fun: fn issue_id, action ->
            {worker, worker_ref} = Agent.get(worker_holder, & &1)
            assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
            refute Process.alive?(worker)
            record(events, {:finalize, issue_id, action})
            if stage == :finalize, do: fail.(), else: :ok
          end,
          unowned_backoff_fun: fn _state, _issue, _attempt, _error, _host, _opts ->
            fail.()
          end
        )
        |> Keyword.delete(:dispatch_fun)

      failed = Orchestrator.multi_project_dispatch_for_test(base_state(), @profiles, opts)
      {worker, _worker_ref} = Agent.get(worker_holder, & &1)

      refute Process.alive?(worker)
      assert Enum.count(Agent.get(events, & &1), &match?({:finalize, _, :release}, &1)) == 1
      refute Map.has_key?(failed.running, candidate.id)
      refute MapSet.member?(failed.claimed, candidate.id)
      refute Map.has_key?(failed.retry_attempts, candidate.id)
    end
  end

  test "running reconciliation preserves approved profile through normal and abnormal retry creation" do
    for reason <- [:normal, :crashed] do
      candidate = %{
        issue("reconcile-#{reason}", @central_profile, 1)
        | project_profile: @central_profile,
          repository: @central_profile.repository,
          routing_revision: 7
      }

      ref = make_ref()

      state = %{
        base_state()
        | claimed: MapSet.new([candidate.id]),
          running: %{
            candidate.id => %{
              issue: candidate,
              identifier: candidate.identifier,
              pid: self(),
              ref: ref,
              worker_host: nil,
              workspace_path: nil,
              session_id: "session-#{reason}",
              started_at: DateTime.utc_now(),
              distributed_claim: %{claim_id: "claim", generation: 1}
            }
          }
      }

      unscoped = %{
        candidate
        | project_id:
            if(reason == :normal,
              do: String.upcase(@central_profile.linear_project_id),
              else: @central_profile.linear_project_id
            ),
          project_slug: "central-display-refreshed",
          project_profile: nil,
          repository: nil,
          routing_revision: nil,
          state: "In Progress"
      }

      reconciled = Orchestrator.reconcile_issue_states_for_test([unscoped], state)
      preserved = reconciled.running[candidate.id].issue
      assert preserved.project_profile == @central_profile
      assert preserved.project_id == @central_profile.linear_project_id
      assert preserved.project_slug == "central-display-refreshed"
      assert preserved.repository == @central_profile.repository
      assert preserved.routing_revision == 7

      assert {:noreply, retried} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, reconciled)

      assert %{project_profile: %{key: "central-brain"}, ownership: :retained_owner} =
               retried.retry_attempts[candidate.id]
    end
  end

  test "running reconciliation fails closed on mismatched or missing authoritative project identity" do
    for refreshed_project_id <- [@project_management_profile.linear_project_id, nil] do
      candidate = %{
        issue("identity-#{inspect(refreshed_project_id)}", @central_profile, 1)
        | project_profile: @central_profile
      }

      worker = spawn(fn -> Process.sleep(:infinity) end)

      state = %{
        base_state()
        | claimed: MapSet.new([candidate.id]),
          retry_attempts: %{candidate.id => %{attempt: 1, retry_token: make_ref()}},
          running: %{
            candidate.id => %{
              issue: candidate,
              identifier: candidate.identifier,
              pid: worker,
              ref: Process.monitor(worker),
              started_at: DateTime.utc_now(),
              distributed_claim: %{claim_id: "claim", generation: 1}
            }
          }
      }

      refreshed = %{candidate | project_id: refreshed_project_id, project_profile: nil}
      reconciled = Orchestrator.reconcile_issue_states_for_test([refreshed], state)

      refute Map.has_key?(reconciled.running, candidate.id)
      refute MapSet.member?(reconciled.claimed, candidate.id)
      refute Map.has_key?(reconciled.retry_attempts, candidate.id)
      refute Process.alive?(worker)
    end
  end

  test "running reconciliation keeps legacy issues legacy" do
    legacy = %{issue("legacy-reconcile", @central_profile, 1) | project_profile: nil, repository: nil}
    refreshed = %{legacy | title: "Refreshed legacy", project_profile: nil}

    state = %{
      base_state()
      | running: %{legacy.id => %{issue: legacy, identifier: legacy.identifier, pid: self(), ref: make_ref()}}
    }

    reconciled = Orchestrator.reconcile_issue_states_for_test([refreshed], state)
    assert reconciled.running[legacy.id].issue.title == "Refreshed legacy"
    assert is_nil(reconciled.running[legacy.id].issue.project_profile)
  end

  test "pre-claim candidate exception isolates the profile without finalizing an unowned claim" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    candidate = issue("preclaim-raise", @central_profile, 1)

    state =
      run_cycle([candidate], %{candidate.id => candidate}, events,
        claim_fun: fn _issue, _owner -> raise "claim callback failed before acquisition" end,
        finalize_claim_fun: fn _issue_id, _action -> flunk("pre-claim failure finalized an unowned claim") end
      )

    refute MapSet.member?(state.claimed, candidate.id)
    refute Map.has_key?(state.retry_attempts, candidate.id)
    assert %{reason: :candidate_failure} = state.profile_retry_attempts["central-brain"]
  end

  test "post-PID bind, tracking, and termination failures stop the worker before one release" do
    for stage <- [:bind, :track, :terminate], failure <- [:raise, :exit, :throw] do
      {:ok, events} = Agent.start_link(fn -> [] end)
      {:ok, worker_holder} = Agent.start_link(fn -> nil end)
      candidate = %{issue("post-pid-#{stage}-#{failure}", @central_profile, 1) | project_profile: @central_profile}

      fail = fn ->
        case failure do
          :raise -> raise "startup failed"
          :exit -> exit(:startup_failed)
          :throw -> throw(:startup_failed)
        end
      end

      opts =
        dispatch_opts(
          fn profile -> {:ok, if(profile.key == "central-brain", do: [candidate], else: [])} end,
          %{candidate.id => candidate},
          events,
          project_profiles: @profiles,
          task_start_fun: fn _task_fun ->
            worker = spawn(fn -> receive do: (:stop -> :ok) end)
            worker_ref = Process.monitor(worker)
            Agent.update(worker_holder, fn _ -> {worker, worker_ref} end)
            {:ok, worker}
          end,
          bind_worker_fun: fn _id, _pid ->
            cond do
              stage == :bind -> fail.()
              stage == :terminate -> {:error, :bind_failed}
              true -> :ok
            end
          end,
          terminate_task_fun: fn _pid -> if stage == :terminate, do: fail.(), else: :ok end,
          track_worker_fun: fn state, _issue, _attempt, _host, _claim, _pid, _ref ->
            if stage == :track, do: fail.(), else: state
          end,
          finalize_claim_fun: fn issue_id, action ->
            {worker, worker_ref} = Agent.get(worker_holder, & &1)
            assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
            refute Process.alive?(worker)
            record(events, {:finalize, issue_id, action})
            :ok
          end
        )
        |> Keyword.delete(:dispatch_fun)

      failed = Orchestrator.multi_project_dispatch_for_test(base_state(), @profiles, opts)
      {worker, _worker_ref} = Agent.get(worker_holder, & &1)

      refute Process.alive?(worker)
      assert Enum.count(Agent.get(events, & &1), &match?({:finalize, _, :release}, &1)) == 1
      assert %{ownership: :unowned_backoff, retry_token: token} = failed.retry_attempts[candidate.id]
      refute MapSet.member?(failed.claimed, candidate.id)
      refute Map.has_key?(failed.running, candidate.id)

      recovered_opts =
        opts
        |> Keyword.delete(:track_worker_fun)
        |> Keyword.put(:retry_fetch_fun, fn _id, _metadata -> {:ok, [candidate]} end)
        |> Keyword.put(:profile_refresh_fun, fn _ids -> {:ok, [candidate]} end)
        |> Keyword.put(:task_start_fun, fn _fun -> {:ok, self()} end)
        |> Keyword.put(:bind_worker_fun, fn _id, _pid -> :ok end)
        |> Keyword.put(:terminate_task_fun, fn _pid -> :ok end)
        |> Keyword.put(:claim_fun, fn _issue, _owner -> {:ok, %{claim_id: "fresh", generation: 2}} end)

      recovered = Orchestrator.fire_issue_retry_for_test(failed, candidate.id, token, recovered_opts)
      assert Map.keys(recovered.running) == [candidate.id]
      assert MapSet.member?(recovered.claimed, candidate.id)
    end
  end

  test "worker capacity race retains ownership and reschedules the profile retry" do
    candidate = %{issue("capacity-race", @central_profile, 1) | project_profile: @central_profile}
    {state, token} = issue_retry_state(candidate, 1)
    {:ok, events} = Agent.start_link(fn -> [] end)

    opts =
      dispatch_opts(fn _profile -> {:ok, []} end, %{candidate.id => candidate}, events,
        project_profiles: @profiles,
        retry_fetch_fun: fn _id, _metadata -> {:ok, [candidate]} end,
        profile_refresh_fun: fn _ids -> {:ok, [candidate]} end,
        worker_host_selector: fn _state, _preferred -> :no_worker_capacity end,
        claim_fun: fn _issue, _owner -> flunk("capacity race must not claim") end
      )

    result = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)
    assert MapSet.member?(result.claimed, candidate.id)

    assert %{attempt: 2, ownership: :retained_owner, project_profile: %{key: "central-brain"}} =
             result.retry_attempts[candidate.id]
  end

  test "removing multi-project mode releases a pending retry instead of renewing it" do
    candidate = %{
      issue("profiles-removed", @central_profile, 1)
      | project_profile: @central_profile,
        repository: @central_profile.repository,
        routing_revision: 1
    }

    assert {:ok, execution_context} = SymphonyElixir.ProjectExecutionContext.from_issue(candidate)

    assert {:ok, %{path: workspace_path, workspace_attestation: workspace_attestation}} =
             Workspace.prepare_for_issue(candidate, nil, execution_context)

    {state, token} = issue_retry_state(candidate, 1)

    state =
      put_in(
        state.retry_attempts[candidate.id],
        Map.merge(state.retry_attempts[candidate.id], %{
          execution_context: execution_context,
          workspace_attestation: workspace_attestation,
          worker_host: nil
        })
      )

    {:ok, events} = Agent.start_link(fn -> [] end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert :ok = WorkflowStore.force_reload()

    assert {:error, :approved_project_profiles_removed} =
             Orchestrator.retry_issue_fetch_for_test(candidate.id, %{project_profile: @central_profile})

    assert {:error, :approved_project_profiles_removed} =
             Orchestrator.approved_profile_result_for_test(
               %{version: 1, profiles: %{"project-management" => @project_management_profile}},
               "central-brain"
             )

    opts = [
      retry_fetch_fun: fn _id, _metadata -> {:error, :approved_project_profiles_removed} end,
      claim_release_fun: fn state_arg, issue_id ->
        record(events, {:release, issue_id})
        %{state_arg | claimed: MapSet.delete(state_arg.claimed, issue_id)}
      end
    ]

    result = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)

    refute MapSet.member?(result.claimed, candidate.id)
    refute Map.has_key?(result.retry_attempts, candidate.id)
    refute File.exists?(workspace_path)
    assert {:release, candidate.id} in Agent.get(events, & &1)
  end

  test "ineligible post-pop outcome releases ownership without rescheduling" do
    {:ok, events} = Agent.start_link(fn -> [] end)

    candidate = %{
      issue("terminal-pending", @central_profile, 1)
      | project_profile: @central_profile,
        labels: []
    }

    {state, token} = issue_retry_state(candidate, 1)

    opts =
      dispatch_opts(fn _profile -> {:ok, []} end, %{}, events,
        project_profiles: @profiles,
        retry_fetch_fun: fn _issue_id, _metadata -> {:ok, [candidate]} end,
        profile_refresh_fun: fn _ids -> {:ok, [candidate]} end,
        claim_release_fun: fn state_arg, issue_id ->
          record(events, {:release, issue_id})
          %{state_arg | claimed: MapSet.delete(state_arg.claimed, issue_id)}
        end
      )

    result = Orchestrator.fire_issue_retry_for_test(state, candidate.id, token, opts)

    refute MapSet.member?(result.claimed, candidate.id), inspect(Agent.get(events, & &1))
    refute Map.has_key?(result.retry_attempts, candidate.id)
    assert {:release, candidate.id} in Agent.get(events, & &1)
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

  defp issue_retry_state(candidate, attempt) do
    token = make_ref()

    state = %{
      base_state()
      | claimed: MapSet.new([candidate.id]),
        retry_attempts: %{
          candidate.id => %{
            attempt: attempt,
            retry_token: token,
            project_profile: candidate.project_profile,
            identifier: candidate.identifier
          }
        }
    }

    {state, token}
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
        assert is_integer(issue.routing_revision) and issue.routing_revision > 0
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

  defp preflight_contract_request(failed_phase, failure_body, failure_status \\ 200) do
    fn request ->
      {phase, body} =
        cond do
          String.ends_with?(request[:url], "/graphql") -> {:actor, %{"data" => %{"viewer" => %{"login" => "automation[bot]"}}}}
          String.contains?(request[:url], "/contents/") -> {:package, %{"scripts" => %{"typecheck" => "tsc", "build" => "build", "test" => "test"}}}
          String.contains?(request[:url], "/git/ref/") -> {:head, %{"ref" => "refs/heads/main", "object" => %{"sha" => String.duplicate("a", 40)}}}
          true -> {:repository, %{"full_name" => @central_profile.repository, "default_branch" => "main", "permissions" => %{"pull" => true, "push" => true}}}
        end

      if phase == failed_phase,
        do: {:ok, %{status: failure_status, body: failure_body}},
        else: {:ok, %{status: 200, body: body}}
    end
  end

  defp callback_failure_overrides(:refresh, failure, first, refreshed_by_id, events) do
    [
      refresh_fun: fn issue_ids ->
        record(events, {:refresh, issue_ids})

        if issue_ids == [first.id],
          do: fail_callback(failure),
          else: {:ok, Enum.map(issue_ids, &Map.fetch!(refreshed_by_id, &1))}
      end
    ]
  end

  defp callback_failure_overrides(:route, failure, first, _refreshed_by_id, events) do
    [
      route_reader: fn issue ->
        record(events, {:route, issue.id})
        if issue.id == first.id, do: fail_callback(failure), else: {:ok, %{routing_revision: 7}}
      end
    ]
  end

  defp callback_failure_overrides(:preflight, failure, first, _refreshed_by_id, events) do
    [
      preflight_fun: fn profile ->
        record(events, {:preflight, profile.key})

        if profile.linear_project_id == first.project_id,
          do: fail_callback(failure),
          else: {:ok, %{repository: profile.repository}}
      end
    ]
  end

  defp callback_failure_overrides(:claim, failure, first, _refreshed_by_id, events) do
    [
      claim_fun: fn issue, owner ->
        assert owner == self()
        record(events, {:claim, issue.id})

        if issue.id == first.id,
          do: fail_callback(failure),
          else: {:ok, %{claim_id: "claim-#{issue.id}", generation: 1}}
      end
    ]
  end

  defp fail_callback(:raise), do: raise("candidate callback failure")
  defp fail_callback(:throw), do: throw(:candidate_callback_failure)
  defp fail_callback(:exit), do: exit(:candidate_callback_failure)

  defp base_state do
    %Orchestrator.State{
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp configure_multi_project_memory_tracker! do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    project_profiles = """
    project_profiles:
      version: 1
      profiles:
        - key: central-brain
          linear_project_id: d0acfb71-f68c-4a9f-8a1a-477265d3c3ec
          repository: aroakpm-svg/aroak-central-brain
          canonical_branch: main
          workspace_namespace: central-brain
          credential_ref: github-central-brain
          environment: local_non_production
        - key: project-management
          linear_project_id: 708053e0-f42c-4e93-bec4-7abbb37e74af
          repository: aroakpm-svg/aroak-project-management
          canonical_branch: main
          workspace_namespace: project-management
          credential_ref: github-project-management
          environment: local_non_production
    """

    workflow = File.read!(Workflow.workflow_file_path())

    File.write!(
      Workflow.workflow_file_path(),
      String.replace(workflow, "---\n", "---\n#{project_profiles}", global: false)
    )

    assert :ok = WorkflowStore.force_reload()
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
