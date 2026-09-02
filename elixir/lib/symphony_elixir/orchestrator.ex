defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    ClaimService,
    Config,
    DispatchCandidate,
    MultiProjectPoll,
    ProjectExecutionContext,
    ProjectProfiles,
    ProjectRepoPreflight,
    ReviewMonitor,
    RuntimeHealth,
    StatusDashboard,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue

  @permanent_preflight_blockers ~w(
    project_mapping_missing
    repository_mismatch
    default_branch_mismatch
    required_check_contract_invalid
    required_check_contract_missing
  )a
  @transient_preflight_blockers ~w(
    repository_unavailable
    repository_metadata_invalid
    default_branch_unresolvable
    required_check_contract_unreadable
  )a

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @profile_retry_base_ms 1_000
  @worker_terminate_grace_ms 100
  @worker_kill_grace_ms 1_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }
  @agent_runner_option_keys [
    :codex_session_starter,
    :credential_provider,
    :effect_ledger_ready?,
    :issue_state_fetcher,
    :max_turns,
    :readiness_command_runner
  ]

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      profile_retry_attempts: %{},
      review_convergence: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.merge(configured_orchestrator_opts(), opts)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Records the owning issue's completed Design 4 landing evidence for the next production poll."
  @spec finding_complete(String.t(), map(), GenServer.server()) :: :ok | {:error, :invalid_finding_complete}
  def finding_complete(issue_id, evidence, server \\ __MODULE__) do
    if is_binary(issue_id) and String.trim(issue_id) != "" and is_map(evidence) do
      GenServer.call(server, {:finding_complete, issue_id, evidence})
    else
      {:error, :invalid_finding_complete}
    end
  end

  @impl true
  def init(opts) do
    identity_validator = identity_validator(opts)

    case validate_startup_identity(identity_validator) do
      {:ok, _viewer_id} ->
        report_health(opts, {:dependency, :linear, %{status: :connected}})
        now_ms = System.monotonic_time(:millisecond)
        config = Config.settings!()

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil
        }

        run_terminal_workspace_cleanup()
        state = schedule_tick(state, 0)

        {:ok, state}

      {:error, reason} ->
        report_health(opts, {:dependency, :linear, %{status: :failed, failure_category: reason}})
        report_health(opts, {:stop, %{category: :startup_failure, failure_category: reason}})
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(
            :workspace_attestation,
            runtime_info[:workspace_attestation]
          )

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:claim_lost, issue_id, reason}, state) when is_binary(issue_id) do
    Logger.error("Database claim lost; stopping worker: issue_id=#{issue_id} reason=#{inspect(reason)}")

    state =
      case Map.get(state.running, issue_id) do
        nil -> retire_lost_claim(state, issue_id)
        running_entry -> stop_and_block_issue(state, issue_id, running_entry, "database claim lost: #{inspect(reason)}")
      end

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:agent_hard_blocker, issue_id, blocker_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(blocker_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        error = Map.get(blocker_info, :error) || "agent hard blocker"

        running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, Map.get(blocker_info, :worker_host))
          |> maybe_put_runtime_value(:workspace_path, Map.get(blocker_info, :workspace_path))

        Logger.warning("Agent reported hard blocker for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier}: #{error}")

        state =
          state
          |> record_session_completion_totals(running_entry)
          |> block_issue_from_entry(issue_id, running_entry, error)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata, [])
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:retry_project_profile, profile_key, retry_token}, state)
      when is_binary(profile_key) and is_reference(retry_token) do
    state = retry_project_profile(state, current_project_profiles(), profile_key, retry_token, [])
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp validate_startup_identity(identity_validator) when is_function(identity_validator, 0) do
    case identity_validator.() do
      {:ok, %{viewer_id: viewer_id}} when is_binary(viewer_id) -> validate_viewer_id(viewer_id)
      {:error, reason} when is_atom(reason) -> {:error, normalize_identity_error(reason)}
      _result -> {:error, :linear_response_invalid}
    end
  rescue
    _exception -> {:error, :linear_unavailable}
  catch
    _kind, _reason -> {:error, :linear_unavailable}
  end

  defp validate_startup_identity(_identity_validator), do: {:error, :linear_response_invalid}

  defp identity_validator(opts) do
    case Keyword.fetch(opts, :identity_validator) do
      {:ok, validator} -> validator
      :error -> &Tracker.validate_identity/0
    end
  end

  defp configured_orchestrator_opts do
    case Application.get_env(:symphony_elixir, :orchestrator_opts, []) do
      opts when is_list(opts) -> opts
      _opts -> []
    end
  end

  defp validate_viewer_id(viewer_id) do
    if String.trim(viewer_id) == "" do
      {:error, :linear_identity_missing}
    else
      {:ok, viewer_id}
    end
  end

  defp normalize_identity_error(reason)
       when reason in [
              :linear_unauthorized,
              :linear_forbidden,
              :linear_identity_missing,
              :linear_response_invalid,
              :linear_workspace_mismatch,
              :linear_unavailable
            ],
       do: reason

  defp normalize_identity_error(_reason), do: :linear_unavailable

  defp handle_agent_down({:claim_lost, issue_id, reason}, state, issue_id, running_entry, _session_id) do
    block_issue_from_entry(state, issue_id, running_entry, "database claim lost: #{inspect(reason)}")
  end

  defp handle_agent_down(:killed, state, issue_id, %{distributed_claim: claim} = running_entry, _session_id)
       when not is_nil(claim) do
    block_issue_from_entry(state, issue_id, running_entry, "database claim lost: worker fenced")
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, running_retry_metadata(running_entry, %{delay_type: :continuation}))
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(
      state,
      issue_id,
      next_attempt,
      running_retry_metadata(running_entry, %{
        error: "agent exited: #{inspect(reason)}"
      })
    )
  end

  defp running_retry_metadata(running_entry, extra) do
    Map.merge(
      %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        workspace_attestation: Map.get(running_entry, :workspace_attestation),
        execution_context: Map.get(running_entry, :execution_context),
        project_profile: running_entry.issue.project_profile
      },
      extra
    )
  end

  defp maybe_dispatch(%State{} = state, opts \\ []) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with {:ok, settings} <- Config.settings(),
         state <- reconcile_review_convergence(state),
         :ok <- Config.validate!() do
      fetch_and_dispatch_candidates(state, settings.project_profiles, opts)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  @doc false
  @spec maybe_dispatch_for_test(term()) :: term()
  def maybe_dispatch_for_test(%State{} = state), do: maybe_dispatch(state)

  @doc false
  @spec maybe_dispatch_for_test(term(), keyword()) :: term()
  def maybe_dispatch_for_test(%State{} = state, opts) when is_list(opts), do: maybe_dispatch(state, opts)

  @doc false
  @spec multi_project_dispatch_for_test(term(), ProjectProfiles.t(), keyword()) :: term()
  def multi_project_dispatch_for_test(%State{} = state, profiles, opts)
      when is_list(opts) do
    profiles_to_poll = available_project_profiles(profiles, state)
    run_multi_project_poll(state, profiles, profiles_to_poll, opts)
  end

  @doc false
  @spec retry_project_profile_for_test(term(), ProjectProfiles.t(), String.t(), reference(), keyword()) :: term()
  def retry_project_profile_for_test(%State{} = state, profiles, profile_key, retry_token, opts)
      when is_binary(profile_key) and is_reference(retry_token) and is_list(opts) do
    retry_project_profile(state, profiles, profile_key, retry_token, opts)
  end

  @doc false
  @spec profile_retry_delay_for_test(pos_integer()) :: pos_integer()
  def profile_retry_delay_for_test(attempt) when is_integer(attempt) and attempt > 0 do
    profile_retry_delay(attempt)
  end

  defp fetch_and_dispatch_candidates(state, nil, _opts) do
    if available_slots(state) > 0 do
      case Tracker.fetch_candidate_issues() do
        {:ok, issues} ->
          choose_issues(issues, state)

        {:error, reason} ->
          Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp fetch_and_dispatch_candidates(state, profiles, opts) do
    run_multi_project_poll(
      state,
      profiles,
      available_project_profiles(profiles, state),
      opts
    )
  end

  defp available_project_profiles(profiles, state) do
    retrying_profiles = Map.get(state, :profile_retry_attempts, %{})

    profiles
    |> ProjectProfiles.list()
    |> Enum.reject(&Map.has_key?(retrying_profiles, &1.key))
  end

  defp run_multi_project_poll(state, _profiles, [], _opts), do: state

  defp run_multi_project_poll(state, profiles, profiles_to_poll, opts) do
    fetcher = Keyword.get(opts, :fetcher, &Tracker.fetch_candidate_issues/1)
    poll_opts = multi_project_poll_opts(opts)

    Enum.each(profiles_to_poll, fn profile ->
      report_health(opts, {:stage, :candidate_fetch, health_profile_metadata(profile, :started)})
    end)

    result = MultiProjectPoll.fetch(profiles_to_poll, fetcher, poll_opts)

    Enum.each(profiles_to_poll, fn profile ->
      outcome = Map.get(result.outcomes, profile.key, %{status: :error})
      report_candidate_fetch_outcome(opts, profile, outcome)
    end)

    if Enum.all?(result.outcomes, fn {_profile, outcome} -> outcome.status == :ok end) do
      report_health(opts, {:dependency, :linear, %{status: :connected}})
      report_health(opts, :poll_succeeded)
    else
      report_health(opts, {
        :dependency,
        :linear,
        %{status: :failed, failure_category: :candidate_fetch_failed}
      })
    end

    state = update_profile_poll_outcomes(state, result.outcomes, opts)

    result.candidates
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn candidate, state_acc ->
      safely_dispatch_multi_project_candidate(state_acc, candidate, profiles, opts)
    end)
  end

  defp multi_project_poll_opts(opts) do
    case Keyword.get(opts, :poll_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> [timeout: timeout]
      _other -> []
    end
  end

  defp update_profile_poll_outcomes(state, outcomes, opts) do
    outcomes
    |> Enum.sort_by(fn {profile_key, _outcome} -> profile_key end)
    |> Enum.reduce(state, fn
      {profile_key, %{status: :ok}}, state_acc ->
        clear_profile_retry(state_acc, profile_key, opts)

      {profile_key, %{status: :timeout}}, state_acc ->
        schedule_profile_retry(state_acc, profile_key, :poll_timeout, opts)

      {profile_key, _outcome}, state_acc ->
        schedule_profile_retry(state_acc, profile_key, :poll_error, opts)
    end)
  end

  defp safely_dispatch_multi_project_candidate(state, candidate, profiles, opts) do
    dispatch_multi_project_candidate(state, candidate, profiles, opts)
  rescue
    _exception ->
      Logger.warning("Skipping multi-project candidate after isolated failure: #{issue_context(candidate)}")
      schedule_candidate_profile_retry(state, candidate, :candidate_failure, opts)
  catch
    _kind, _reason ->
      Logger.warning("Skipping multi-project candidate after isolated failure: #{issue_context(candidate)}")
      schedule_candidate_profile_retry(state, candidate, :candidate_failure, opts)
  end

  defp dispatch_multi_project_candidate(state, %Issue{} = candidate, profiles, opts) do
    refresh_fun = Keyword.get(opts, :refresh_fun, &Tracker.fetch_issue_states_by_ids/1)

    report_health(opts, {:stage, :issue_refresh, health_issue_metadata(candidate, :started)})

    refresh_result =
      observed_call(
        fn -> revalidate_issue_for_dispatch(candidate, refresh_fun, terminal_state_set()) end,
        fn failure_category ->
          report_health(opts, {
            :stage,
            :issue_refresh,
            health_issue_metadata(candidate, :failed, failure_category)
          })
        end
      )

    case refresh_result do
      {:ok, %Issue{} = refreshed_issue} ->
        report_health(opts, {:stage, :issue_refresh, health_issue_metadata(candidate, :succeeded)})

        refreshed_issue = %{
          refreshed_issue
          | project_profile: candidate.project_profile,
            repository: nil
        }

        authorize_multi_project_candidate(state, refreshed_issue, profiles, opts)

      {:skip, :missing} ->
        report_health(opts, {:stage, :issue_refresh, health_issue_metadata(candidate, :skipped, :missing)})
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(candidate)}")
        transition_retry_release(state, candidate, opts)

      {:skip, %Issue{} = refreshed_issue} ->
        report_health(opts, {
          :stage,
          :issue_refresh,
          health_issue_metadata(refreshed_issue, :skipped, :stale_issue)
        })

        Logger.info("Skipping stale multi-project dispatch after issue refresh: #{issue_context(refreshed_issue)}")

        transition_retry_release(state, refreshed_issue, opts)

      {:error, _reason} ->
        report_health(opts, {
          :stage,
          :issue_refresh,
          health_issue_metadata(candidate, :failed, :refresh_unavailable)
        })

        Logger.warning("Retrying profile after issue refresh failed: #{issue_context(candidate)}")
        transition_retry_transient(state, candidate, :refresh_unavailable, opts)
    end
  end

  defp dispatch_multi_project_candidate(state, _candidate, _profiles, _opts), do: state

  defp authorize_multi_project_candidate(state, issue, profiles, opts) do
    route_reader = Keyword.get(opts, :route_reader, &ClaimService.exclusive_route/1)

    authorization_opts = [
      active_states: Config.settings!().tracker.active_states,
      route_reader: route_reader
    ]

    for stage <- [:routing, :profile_resolution] do
      report_health(opts, {:stage, stage, health_issue_metadata(issue, :started)})
    end

    authorization_result =
      observed_call(
        fn -> DispatchCandidate.authorize(issue, profiles, authorization_opts) end,
        fn failure_category ->
          for stage <- [:routing, :profile_resolution] do
            report_health(opts, {
              :stage,
              stage,
              health_issue_metadata(issue, :failed, failure_category)
            })
          end
        end
      )

    case authorization_result do
      {:ok, authorized_issue} ->
        for stage <- [:routing, :profile_resolution] do
          report_health(opts, {:stage, stage, health_issue_metadata(authorized_issue, :succeeded)})
        end

        report_health(opts, {:dependency, :claim_store, %{status: :connected}})
        preflight_multi_project_candidate(state, authorized_issue, opts)

      {:skip, reason} ->
        for stage <- [:routing, :profile_resolution] do
          report_health(opts, {:stage, stage, health_issue_metadata(issue, :skipped, reason)})
        end

        Logger.info("Skipping ineligible multi-project candidate: #{issue_context(issue)} reason=#{reason}")
        transition_retry_release(state, issue, opts)

      {:retry, reason} ->
        for stage <- [:routing, :profile_resolution] do
          report_health(opts, {:stage, stage, health_issue_metadata(issue, :retrying, reason)})
        end

        report_health(opts, {
          :dependency,
          :claim_store,
          %{status: :failed, failure_category: :routing_unavailable}
        })

        Logger.warning("Retrying profile after authorization uncertainty: #{issue_context(issue)} reason=#{reason}")
        transition_retry_transient(state, issue, reason, opts)
    end
  end

  defp preflight_multi_project_candidate(state, issue, opts) do
    preflight_fun = Keyword.get(opts, :preflight_fun, &ProjectRepoPreflight.check/1)

    report_health(opts, {:stage, :preflight, health_issue_metadata(issue, :started)})

    preflight_result =
      observed_call(
        fn -> preflight_fun.(issue.project_profile) end,
        fn failure_category ->
          report_health(opts, {
            :stage,
            :preflight,
            health_issue_metadata(issue, :failed, failure_category)
          })
        end
      )

    case preflight_result do
      {:ok, _receipt} ->
        report_health(opts, {:stage, :preflight, health_issue_metadata(issue, :succeeded)})
        dispatch_authorized_multi_project_candidate(state, issue, opts)

      {:blocked, %{code: code}} ->
        report_health(opts, {:stage, :preflight, health_issue_metadata(issue, :skipped, code)})
        Logger.warning("Skipping multi-project candidate after repository preflight: #{issue_context(issue)} profile=#{issue.project_profile.key} reason=#{code}")

        case preflight_blocker_disposition(code) do
          :transient -> transition_retry_transient(state, issue, {:preflight_blocked, code}, opts)
          :permanent -> transition_retry_release(state, issue, opts)
        end

      _other ->
        report_health(opts, {
          :stage,
          :preflight,
          health_issue_metadata(issue, :retrying, :preflight_unavailable)
        })

        Logger.warning("Skipping multi-project candidate after repository preflight: #{issue_context(issue)} profile=#{issue.project_profile.key} reason=preflight_unavailable")

        transition_retry_transient(state, issue, :preflight_unavailable, opts)
    end
  end

  defp preflight_blocker_disposition(code) do
    case preflight_blocker_classification(code) do
      :unclassified -> :permanent
      classification -> classification
    end
  end

  defp preflight_blocker_classification(code) when code in @transient_preflight_blockers, do: :transient
  defp preflight_blocker_classification(code) when code in @permanent_preflight_blockers, do: :permanent
  defp preflight_blocker_classification(_unknown), do: :unclassified

  defp dispatch_authorized_multi_project_candidate(state, issue, opts) do
    if dispatch_authorized_issue?(issue, state, opts) do
      do_dispatch_issue(
        state,
        issue,
        Keyword.get(opts, :issue_retry_attempt),
        Keyword.get(opts, :preferred_worker_host),
        opts
      )
    else
      maybe_reschedule_capacity_retry(state, issue, opts)
    end
  end

  defp dispatch_authorized_issue?(issue, state, opts) do
    if retry_dispatch?(opts) do
      retry_dispatch_allowed?(issue, state, opts)
    else
      should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
    end
  end

  defp retry_dispatch_allowed?(issue, state, opts) do
    case get_in(opts, [:retry_metadata, :ownership]) do
      :unowned_backoff ->
        should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())

      _retained_owner ->
        retained_owner_retry_allowed?(issue, state, opts)
    end
  end

  defp retained_owner_retry_allowed?(issue, state, opts) do
    candidate_issue?(issue, active_state_set(), terminal_state_set()) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_state_set()) and
      MapSet.member?(state.claimed, issue.id) and
      !Map.has_key?(state.running, issue.id) and
      !Map.has_key?(state.blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, state.running) and
      worker_slots_available?(state, Keyword.get(opts, :preferred_worker_host))
  end

  defp maybe_reschedule_capacity_retry(state, issue, opts) do
    attempt = Keyword.get(opts, :issue_retry_attempt)
    metadata = Keyword.get(opts, :retry_metadata, %{})

    if is_integer(attempt) and retry_capacity_blocked?(state, issue, metadata) do
      schedule_issue_retry(
        state,
        issue.id,
        attempt + 1,
        Map.put(metadata, :error, "retry capacity unavailable")
      )
    else
      state
    end
  end

  defp retry_capacity_blocked?(state, issue, metadata) do
    retry_ownership_allows_capacity_backoff?(state, issue.id, metadata[:ownership]) and
      !Map.has_key?(state.running, issue.id) and
      !Map.has_key?(state.blocked, issue.id) and
      (available_slots(state) <= 0 or
         !state_slots_available?(issue, state.running) or
         !worker_slots_available?(state, metadata[:worker_host]))
  end

  defp retry_ownership_allows_capacity_backoff?(state, issue_id, :retained_owner) do
    MapSet.member?(state.claimed, issue_id)
  end

  defp retry_ownership_allows_capacity_backoff?(state, issue_id, :unowned_backoff) do
    !MapSet.member?(state.claimed, issue_id)
  end

  defp retry_ownership_allows_capacity_backoff?(_state, _issue_id, _ownership), do: false

  defp schedule_candidate_profile_retry(state, %Issue{project_profile: %{key: profile_key}}, reason, opts)
       when is_binary(profile_key) do
    schedule_profile_retry(state, profile_key, reason, opts)
  end

  defp schedule_candidate_profile_retry(state, _candidate, _reason, _opts), do: state

  defp transition_retry_transient(state, issue, reason, opts) do
    if retry_dispatch?(opts) do
      attempt = Keyword.fetch!(opts, :issue_retry_attempt)
      metadata = Keyword.get(opts, :retry_metadata, %{})

      schedule_issue_retry(
        state,
        issue.id,
        attempt + 1,
        Map.put(metadata, :error, "retry authorization pending: #{inspect(reason)}")
      )
    else
      schedule_candidate_profile_retry(state, issue, reason, opts)
    end
  end

  defp transition_retry_release(state, issue, opts) do
    transition_retry_release_id(state, issue.id, opts)
  end

  defp transition_retry_release_id(state, issue_id, opts) do
    if retry_dispatch?(opts) do
      release_fun = Keyword.get(opts, :claim_release_fun, &release_issue_claim/2)
      release_fun.(state, issue_id)
    else
      state
    end
  end

  defp retry_dispatch?(opts), do: is_integer(Keyword.get(opts, :issue_retry_attempt))

  defp schedule_profile_retry(state, profile_key, reason, opts) do
    retries = Map.get(state, :profile_retry_attempts, %{})

    if Map.has_key?(retries, profile_key) do
      state
    else
      attempt = Keyword.get(opts, :profile_retry_attempt, 0) + 1
      put_profile_retry(state, retries, profile_key, attempt, reason, opts)
    end
  end

  defp reschedule_profile_retry(state, profile_key, previous_retry, reason, opts) do
    attempt = previous_retry.attempt + 1
    put_profile_retry(state, state.profile_retry_attempts, profile_key, attempt, reason, opts)
  end

  defp put_profile_retry(state, retries, profile_key, attempt, reason, opts) do
    delay_fun = Keyword.get(opts, :retry_delay_fun, &profile_retry_delay/1)
    delay_ms = delay_fun.(attempt)
    retry_token = make_ref()
    message = {:retry_project_profile, profile_key, retry_token}
    timer_fun = Keyword.get(opts, :timer_fun, &Process.send_after(self(), &1, &2))
    timer_ref = timer_fun.(message, delay_ms)

    retry = %{
      attempt: attempt,
      due_at_ms: System.monotonic_time(:millisecond) + delay_ms,
      reason: reason,
      retry_token: retry_token,
      timer_ref: timer_ref
    }

    Logger.warning("Retrying project profile=#{profile_key} in #{delay_ms}ms attempt=#{attempt} reason=#{reason}")
    %{state | profile_retry_attempts: Map.put(retries, profile_key, retry)}
  end

  defp clear_profile_retry(state, profile_key, opts) do
    case Map.pop(Map.get(state, :profile_retry_attempts, %{}), profile_key) do
      {nil, _retries} ->
        state

      {%{timer_ref: timer_ref}, retries} ->
        cancel_timer_fun = Keyword.get(opts, :cancel_timer_fun, &Process.cancel_timer/1)
        if is_reference(timer_ref), do: cancel_timer_fun.(timer_ref)
        %{state | profile_retry_attempts: retries}
    end
  end

  defp retry_project_profile(state, profiles, profile_key, retry_token, opts) do
    case Map.get(Map.get(state, :profile_retry_attempts, %{}), profile_key) do
      %{retry_token: ^retry_token} = previous_retry ->
        state = %{
          state
          | profile_retry_attempts: Map.delete(state.profile_retry_attempts, profile_key)
        }

        case ProjectProfiles.fetch(profiles, profile_key) do
          {:ok, profile} ->
            retry_profile_poll(state, profiles, profile, previous_retry, opts)

          :error ->
            state
        end

      _stale_or_missing ->
        state
    end
  end

  defp retry_profile_poll(state, profiles, profile, previous_retry, opts) do
    fetcher = Keyword.get(opts, :fetcher, &Tracker.fetch_candidate_issues/1)
    result = MultiProjectPoll.fetch([profile], fetcher, multi_project_poll_opts(opts))

    case result.outcomes[profile.key] do
      %{status: :ok} ->
        retry_opts = Keyword.put(opts, :profile_retry_attempt, previous_retry.attempt)

        result.candidates
        |> sort_issues_for_dispatch()
        |> Enum.reduce(state, fn candidate, state_acc ->
          safely_dispatch_multi_project_candidate(state_acc, candidate, profiles, retry_opts)
        end)

      %{status: :timeout} ->
        reschedule_profile_retry(state, profile.key, previous_retry, :poll_timeout, opts)

      _outcome ->
        reschedule_profile_retry(state, profile.key, previous_retry, :poll_error, opts)
    end
  end

  defp current_project_profiles do
    case Config.settings() do
      {:ok, settings} -> settings.project_profiles
      {:error, _reason} -> nil
    end
  end

  defp profile_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    upper_bound = min(@profile_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
    lower_bound = max(1, div(upper_bound * 3, 4))
    lower_bound + :rand.uniform(upper_bound - lower_bound + 1) - 1
  end

  defp reconcile_review_convergence(%State{} = state) do
    %{state | review_convergence: ReviewMonitor.run(state.review_convergence)}
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    opts = [issue_retry_attempt: attempt, retry_metadata: metadata]
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata, opts)
    updated_state
  end

  @doc false
  @spec fire_issue_retry_for_test(term(), String.t(), reference(), keyword()) :: term()
  def fire_issue_retry_for_test(%State{} = state, issue_id, retry_token, opts)
      when is_binary(issue_id) and is_reference(retry_token) and is_list(opts) do
    case pop_retry_attempt_state(state, issue_id, retry_token) do
      {:ok, attempt, metadata, state} ->
        {:noreply, updated_state} = handle_retry_issue(state, issue_id, attempt, metadata, opts)
        updated_state

      :missing ->
        state
    end
  end

  @doc false
  @spec retry_issue_fetch_for_test(String.t(), map(), ([String.t()] -> term())) :: term()
  def retry_issue_fetch_for_test(issue_id, metadata, fetch_fun \\ &Tracker.fetch_issue_states_by_ids/1)
      when is_binary(issue_id) and is_map(metadata) and is_function(fetch_fun, 1) do
    retry_issue_fetch_unfiltered(issue_id, metadata, fetch_fun)
  end

  @doc false
  @spec report_runtime_health_for_test(term()) :: :ok
  def report_runtime_health_for_test(event), do: report_runtime_health(event)

  @doc false
  @spec runtime_health_snapshot_for_test() :: map()
  def runtime_health_snapshot_for_test, do: runtime_health_snapshot()

  @doc false
  @spec approved_profile_result_for_test(term(), String.t()) :: {:ok, map()} | {:error, atom()}
  def approved_profile_result_for_test(profiles, key) when is_binary(key), do: approved_profile_result(profiles, key)

  @doc false
  @spec preflight_blocker_classification_for_test(atom()) :: :permanent | :transient | :unclassified
  def preflight_blocker_classification_for_test(code) when is_atom(code) do
    preflight_blocker_classification(code)
  end

  @doc false
  @spec retire_lost_claim_for_test(term(), String.t()) :: term()
  def retire_lost_claim_for_test(%State{} = state, issue_id) when is_binary(issue_id) do
    retire_lost_claim(state, issue_id)
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec terminal_cleanup_for_test(
          [map()],
          [String.t()],
          (map(), [String.t()] -> term()),
          (String.t() -> term())
          | (String.t(), ProjectExecutionContext.t() -> term())
          | (String.t(), ProjectExecutionContext.t(), map() | nil -> term())
          | (String.t(), String.t() | nil, ProjectExecutionContext.t(), map() | nil -> term())
        ) :: :ok
  def terminal_cleanup_for_test(profiles, states, fetcher, cleanup_fun)
      when is_list(profiles) and is_function(fetcher, 2) and
             (is_function(cleanup_fun, 1) or is_function(cleanup_fun, 2) or
                is_function(cleanup_fun, 3) or is_function(cleanup_fun, 4)) do
    cleanup_terminal_profiles(profiles, states, fetcher, cleanup_fun)
  end

  @doc false
  @spec agent_runner_options_for_test(keyword(), keyword()) :: keyword()
  def agent_runner_options_for_test(opts, authority) when is_list(opts) and is_list(authority),
    do: agent_runner_options(opts, authority)

  @doc false
  @spec handle_claim_rejection_for_test(term(), Issue.t(), term()) :: term()
  def handle_claim_rejection_for_test(%State{} = state, %Issue{} = issue, attempt) do
    handle_claim_rejection(state, issue, attempt, nil, :claim_timeout, [])
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, :complete)

      running_project_identity_changed?(state, issue) ->
        Logger.warning("Running issue project identity changed; releasing claim: #{issue_context(issue)} project_id=#{inspect(issue.project_id)}")
        terminate_running_issue(state, issue.id, :invalidate_context)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, :retain_context)

      active_issue_state?(issue.state, active_states) ->
        reconcile_active_running_issue(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, :retain_context)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp running_project_identity_changed?(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{execution_context: %ProjectExecutionContext{}} = running_entry ->
        not running_project_identity_matches?(running_entry, issue)

      _legacy_or_missing ->
        false
    end
  end

  defp reconcile_active_running_issue(state, issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _existing_issue} = running_entry ->
        if running_project_identity_matches?(running_entry, issue) do
          refresh_running_issue_state(state, issue)
        else
          Logger.warning("Running issue project identity changed; releasing claim: #{issue_context(issue)} project_id=#{inspect(issue.project_id)}")
          terminate_running_issue(state, issue.id, :invalidate_context)
        end

      _missing ->
        state
    end
  end

  defp running_project_identity_matches?(
         %{execution_context: %ProjectExecutionContext{linear_project_id: expected_project_id}},
         %Issue{project_id: refreshed_project_id}
       ) do
    project_ids_match?(expected_project_id, refreshed_project_id)
  end

  defp running_project_identity_matches?(%{issue: %Issue{project_profile: nil}}, _refreshed_issue),
    do: true

  defp running_project_identity_matches?(
         %{issue: %Issue{project_profile: %{linear_project_id: expected_project_id}}},
         %Issue{project_id: refreshed_project_id}
       )
       when is_binary(expected_project_id) and is_binary(refreshed_project_id) do
    project_ids_match?(expected_project_id, refreshed_project_id)
  end

  defp running_project_identity_matches?(_running_entry, _refreshed_issue), do: false

  defp project_ids_match?(expected_project_id, refreshed_project_id)
       when is_binary(expected_project_id) and is_binary(refreshed_project_id) do
    with {:ok, expected_uuid} <- Ecto.UUID.cast(expected_project_id),
         {:ok, refreshed_uuid} <- Ecto.UUID.cast(refreshed_project_id) do
      expected_uuid == refreshed_uuid
    else
      :error -> false
    end
  end

  defp project_ids_match?(_expected_project_id, _refreshed_project_id), do: false

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")

        retire_blocked_execution_context(state, issue.id)

        release_issue_claim(state, issue.id)

      !blocked_project_identity_matches?(state, issue) ->
        Logger.warning(
          "Blocked issue project identity changed; releasing claim: " <>
            "#{issue_context(issue)} project_id=#{inspect(issue.project_id)}"
        )

        retire_blocked_execution_context(state, issue.id)
        release_issue_claim(state, issue.id)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp blocked_project_identity_matches?(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{execution_context: %ProjectExecutionContext{linear_project_id: expected_project_id}} ->
        project_ids_match?(expected_project_id, issue.project_id)

      _legacy_or_missing ->
        true
    end
  end

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, :retain_context)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: existing_issue} = running_entry ->
        refreshed_issue = merge_running_issue_context(existing_issue, issue)
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: refreshed_issue})}

      _ ->
        state
    end
  end

  defp merge_running_issue_context(%Issue{project_profile: nil}, %Issue{} = refreshed_issue),
    do: refreshed_issue

  defp merge_running_issue_context(%Issue{} = existing_issue, %Issue{} = refreshed_issue) do
    %{
      refreshed_issue
      | project_id: existing_issue.project_id,
        project_profile: existing_issue.project_profile,
        repository: existing_issue.repository,
        routing_revision: existing_issue.routing_revision
    }
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, termination_policy)
       when termination_policy in [:complete, :invalidate_context, :retain_context] do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)
        execution_context = Map.get(running_entry, :execution_context)
        workspace_attestation = Map.get(running_entry, :workspace_attestation)

        stop_running_task(pid, ref)

        if retire_execution_context?(termination_policy) do
          retire_execution_context(
            identifier,
            worker_host,
            execution_context,
            workspace_attestation
          )
        end

        if termination_policy == :complete do
          finalize_distributed_claim(issue_id, :complete)
        else
          finalize_distributed_claim(issue_id, :release)
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp retire_execution_context?(termination_policy),
    do: termination_policy in [:complete, :invalidate_context]

  defp retire_blocked_execution_context(%State{} = state, issue_id) do
    case Map.get(state.blocked, issue_id) do
      %{identifier: identifier} = blocked_entry ->
        retire_execution_context(
          identifier,
          Map.get(blocked_entry, :worker_host),
          Map.get(blocked_entry, :execution_context),
          Map.get(blocked_entry, :workspace_attestation)
        )

      _missing ->
        :ok
    end
  end

  defp retire_execution_context(identifier, worker_host, execution_context, workspace_attestation) do
    cleanup_issue_workspace(identifier, worker_host, execution_context, workspace_attestation)
  end

  defp reconcile_stalled_running_issues(%State{running: running} = state) when map_size(running) == 0,
    do: state

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    if timeout_ms <= 0 do
      state
    else
      now = DateTime.utc_now()

      Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
        maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
      end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, :retain_context)
        |> schedule_issue_retry(
          issue_id,
          next_attempt,
          running_retry_metadata(running_entry, %{
            error: "stalled for #{elapsed_ms}ms without codex activity",
            ownership: :unowned_backoff
          })
        )
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp stop_running_task(pid, ref) do
    if is_pid(pid) do
      terminate_task(pid)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))
    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    :ok = finalize_distributed_claim(issue_id, :release)

    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      workspace_attestation: Map.get(running_entry, :workspace_attestation),
      execution_context: Map.get(running_entry, :execution_context),
      session_id: running_entry_session_id(running_entry),
      error: error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(state.retry_attempts, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, opts \\ []) do
    recipient = self()
    claim_fun = Keyword.get(opts, :claim_fun, &ClaimService.claim/2)
    worker_host_selector = Keyword.get(opts, :worker_host_selector, &select_worker_host/2)

    dispatch_fun =
      Keyword.get(opts, :dispatch_fun) ||
        fn state, issue, attempt, recipient, worker_host, distributed_claim ->
          spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, distributed_claim, opts)
        end

    case worker_host_selector.(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        transition_retry_retained(state, issue, :worker_capacity_race, opts)

      worker_host ->
        report_health(opts, {:stage, :claim, health_issue_metadata(issue, :started)})

        claim_result =
          observed_call(
            fn -> claim_fun.(issue, recipient) end,
            fn failure_category ->
              report_health(opts, {
                :stage,
                :claim,
                health_issue_metadata(issue, :failed, failure_category)
              })
            end
          )

        case claim_result do
          {:ok, distributed_claim} ->
            report_health(opts, {:stage, :claim, health_issue_metadata(issue, :succeeded)})
            report_health(opts, {:dependency, :claim_store, %{status: :connected}})

            dispatch_acquired_claim(
              dispatch_fun,
              state,
              issue,
              attempt,
              recipient,
              worker_host,
              distributed_claim,
              opts
            )

          {:error, reason} ->
            report_health(opts, {:stage, :claim, health_issue_metadata(issue, :failed, :claim_rejected)})

            report_health(opts, {
              :dependency,
              :claim_store,
              %{status: :failed, failure_category: :claim_rejected}
            })

            Logger.warning("Skipping dispatch; database claim rejected for #{issue_context(issue)}: #{inspect(reason)}")
            handle_claim_rejection(state, issue, attempt, worker_host, reason, opts)
        end
    end
  end

  defp dispatch_acquired_claim(dispatch_fun, state, issue, attempt, recipient, worker_host, claim, opts) do
    report_health(opts, {:stage, :dispatch, health_issue_metadata(issue, :started)})

    case dispatch_fun.(state, issue, attempt, recipient, worker_host, claim) do
      {:ok, result} ->
        report_health(opts, {:stage, :dispatch, health_issue_metadata(issue, :succeeded)})
        result

      {:error, result} ->
        report_health(opts, {
          :stage,
          :dispatch,
          health_issue_metadata(issue, :failed, :dispatch_failure)
        })

        result

      result ->
        report_health(opts, {:stage, :dispatch, health_issue_metadata(issue, :succeeded)})
        result
    end
  rescue
    exception ->
      report_health(opts, {:stage, :dispatch, health_issue_metadata(issue, :failed, :dispatch_exception)})
      cleanup_acquired_dispatch_failure(state, issue, attempt, worker_host, {:exception, exception}, opts)
  catch
    kind, reason ->
      report_health(opts, {:stage, :dispatch, health_issue_metadata(issue, :failed, :dispatch_failure)})
      cleanup_acquired_dispatch_failure(state, issue, attempt, worker_host, {kind, reason}, opts)
  end

  defp cleanup_acquired_dispatch_failure(state, issue, attempt, worker_host, reason, opts) do
    finalize_fun = Keyword.get(opts, :finalize_claim_fun, &finalize_distributed_claim/2)
    :ok = finalize_fun.(issue.id, :release)
    Logger.error("Dispatch failed after database claim acquisition for #{issue_context(issue)}: #{inspect(reason)}")

    transition_retry_unowned_backoff(
      state,
      issue,
      if(is_integer(attempt), do: attempt + 1, else: nil),
      "post-claim dispatch failed: #{inspect(reason)}",
      worker_host,
      opts
    )
  end

  defp handle_claim_rejection(state, issue, attempt, worker_host, reason, opts) when is_integer(attempt) do
    Logger.info("Returning rejected retry claim to ordinary authorization: #{issue_context(issue)} attempt=#{attempt} worker_host=#{inspect(worker_host)} reason=#{inspect(reason)}")
    transition_retry_unowned(state, issue.id, opts)
  end

  defp handle_claim_rejection(state, issue, _attempt, _worker_host, _reason, _opts) do
    transition_retry_unowned(state, issue.id, [])
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, distributed_claim, opts) do
    execution_context = execution_context_for_dispatch!(issue)
    opts = Keyword.put(opts, :execution_context, execution_context)
    start_fun = Keyword.get(opts, :task_start_fun, &Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, &1))
    bind_fun = Keyword.get(opts, :bind_worker_fun, &ClaimService.bind_worker/2)
    terminate_fun = Keyword.get(opts, :terminate_task_fun, &terminate_task/1)
    finalize_fun = Keyword.get(opts, :finalize_claim_fun, &finalize_distributed_claim/2)

    track_fun =
      Keyword.get(opts, :track_worker_fun) ||
        fn state_arg, issue_arg, attempt_arg, host_arg, claim_arg, pid_arg, ref_arg ->
          track_spawned_issue(
            state_arg,
            issue_arg,
            attempt_arg,
            host_arg,
            claim_arg,
            pid_arg,
            ref_arg,
            execution_context
          )
        end

    runner_options =
      agent_runner_options(opts,
        attempt: attempt,
        worker_host: worker_host,
        distributed_claim: distributed_claim,
        execution_context: execution_context
      )

    task_fun = fn ->
      AgentRunner.run(issue, recipient, runner_options)
    end

    case start_fun.(task_fun) do
      {:ok, pid} ->
        complete_spawned_worker_startup(%{
          state: state,
          issue: issue,
          attempt: attempt,
          worker_host: worker_host,
          claim: distributed_claim,
          pid: pid,
          bind_fun: bind_fun,
          terminate_fun: terminate_fun,
          finalize_fun: finalize_fun,
          track_fun: track_fun,
          opts: opts
        })

      {:error, reason} ->
        :ok = finalize_fun.(issue.id, :release)
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        {:error,
         transition_retry_unowned_backoff(
           state,
           issue,
           next_attempt,
           "failed to spawn agent: #{inspect(reason)}",
           worker_host,
           opts
         )}
    end
  end

  defp agent_runner_options(opts, authority) do
    opts
    |> Keyword.take(@agent_runner_option_keys)
    |> Keyword.merge(authority)
  end

  defp complete_spawned_worker_startup(context) do
    context = Map.put(context, :ref, Process.monitor(context.pid))

    case spawned_worker_startup_outcome(context) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, cleanup_spawned_worker_failure(context, reason)}
    end
  end

  defp spawned_worker_startup_outcome(context) do
    case context.bind_fun.(context.issue.id, context.pid) do
      :ok ->
        {:ok,
         context.track_fun.(
           context.state,
           context.issue,
           context.attempt,
           context.worker_host,
           context.claim,
           context.pid,
           context.ref
         )}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      {:error, {:exception, exception}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp cleanup_spawned_worker_failure(context, reason) do
    case fence_spawned_worker(context) do
      :down -> finalize_spawned_worker_failure(context, reason)
      :timeout -> fail_closed_spawned_worker_state(context, :worker_fence_timeout)
    end
  end

  defp fence_spawned_worker(context) do
    try do
      context.terminate_fun.(context.pid)
    catch
      _kind, _reason -> :ok
    end

    case await_spawned_worker_down(context.ref, context.pid, @worker_terminate_grace_ms) do
      :down ->
        :down

      :timeout ->
        Process.exit(context.pid, :kill)
        await_spawned_worker_down(context.ref, context.pid, @worker_kill_grace_ms)
    end
  end

  defp await_spawned_worker_down(ref, pid, timeout_ms) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :down
    after
      timeout_ms -> :timeout
    end
  end

  defp finalize_spawned_worker_failure(context, reason) do
    Process.demonitor(context.ref, [:flush])

    case invoke_cleanup_step(fn -> context.finalize_fun.(context.issue.id, :release) end) do
      {:ok, :ok} ->
        invoke_backoff_or_fail_closed(context, reason)

      {:ok, other} ->
        fail_closed_spawned_worker_state(context, {:finalize_failed, other})

      {:error, finalize_reason} ->
        fail_closed_spawned_worker_state(context, {:finalize_failed, finalize_reason})
    end
  end

  defp invoke_backoff_or_fail_closed(context, reason) do
    backoff_fun =
      Keyword.get(
        context.opts,
        :unowned_backoff_fun,
        &transition_retry_unowned_backoff/6
      )

    backoff = fn ->
      backoff_fun.(
        context.state,
        context.issue,
        normalize_retry_attempt(context.attempt) + 1,
        "spawned worker startup failed: #{inspect(reason)}",
        context.worker_host,
        context.opts
      )
    end

    case invoke_cleanup_step(backoff) do
      {:ok, state} -> state
      {:error, backoff_reason} -> fail_closed_spawned_worker_state(context, {:backoff_failed, backoff_reason})
    end
  end

  defp invoke_cleanup_step(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp fail_closed_spawned_worker_state(context, reason) do
    Logger.error("Spawned worker cleanup failed closed for #{issue_context(context.issue)}: #{inspect(reason)}")

    %{
      context.state
      | running: Map.delete(context.state.running, context.issue.id),
        claimed: MapSet.delete(context.state.claimed, context.issue.id),
        retry_attempts: Map.delete(context.state.retry_attempts, context.issue.id)
    }
  end

  defp dispatch_failure_retry_metadata(issue, worker_host, error, opts) do
    retry_metadata = Keyword.get(opts, :retry_metadata, %{})

    Map.merge(retry_metadata, %{
      identifier: issue.identifier,
      issue_url: issue.url,
      error: error,
      worker_host: worker_host,
      execution_context: Keyword.get(opts, :execution_context) || retry_metadata[:execution_context],
      project_profile: issue.project_profile || retry_metadata[:project_profile]
    })
  end

  defp transition_retry_retained(state, issue, reason, opts) do
    transition_retry_transient(state, issue, reason, opts)
  end

  defp transition_retry_unowned(state, issue_id, opts) do
    release_fun = Keyword.get(opts, :claim_release_fun, &release_issue_claim/2)
    release_fun.(state, issue_id)
  end

  defp transition_retry_unowned_backoff(state, issue, attempt, error, worker_host, opts) do
    state = %{state | claimed: MapSet.delete(state.claimed, issue.id)}

    metadata =
      issue
      |> dispatch_failure_retry_metadata(worker_host, error, opts)
      |> Map.put(:ownership, :unowned_backoff)

    schedule_issue_retry(state, issue.id, attempt, metadata)
  end

  defp track_spawned_issue(
         state,
         issue,
         attempt,
         worker_host,
         distributed_claim,
         pid,
         ref,
         execution_context
       ) do
    Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

    running =
      Map.put(state.running, issue.id, %{
        pid: pid,
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        execution_context: execution_context,
        worker_host: worker_host,
        workspace_path: nil,
        workspace_attestation: nil,
        session_id: nil,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        turn_count: 0,
        retry_attempt: normalize_retry_attempt(attempt),
        started_at: DateTime.utc_now(),
        distributed_claim: distributed_claim
      })

    %{
      state
      | running: running,
        claimed: MapSet.put(state.claimed, issue.id),
        retry_attempts: Map.delete(state.retry_attempts, issue.id)
    }
  end

  defp execution_context_for_dispatch!(%Issue{project_profile: nil}), do: nil

  defp execution_context_for_dispatch!(%Issue{} = issue) do
    case ProjectExecutionContext.from_issue(issue) do
      {:ok, execution_context} ->
        execution_context

      {:error, reason} ->
        raise ArgumentError,
              "invalid project execution context for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    workspace_attestation = retry_value(metadata, previous_retry, :workspace_attestation)
    project_profile = retry_value(metadata, previous_retry, :project_profile)
    execution_context = retry_value(metadata, previous_retry, :execution_context)
    ownership = retry_ownership(state, issue_id, metadata, previous_retry)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            workspace_attestation: workspace_attestation,
            execution_context: execution_context,
            project_profile: project_profile,
            ownership: ownership
          })
    }
  end

  defp retry_value(metadata, previous_retry, key) do
    Map.get(metadata, key) || Map.get(previous_retry, key)
  end

  defp retry_ownership(state, issue_id, metadata, previous_retry) do
    retry_value(metadata, previous_retry, :ownership) || default_retry_ownership(state, issue_id)
  end

  defp default_retry_ownership(state, issue_id) do
    if MapSet.member?(state.claimed, issue_id), do: :retained_owner, else: :unowned_backoff
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          workspace_attestation: Map.get(retry_entry, :workspace_attestation),
          execution_context: Map.get(retry_entry, :execution_context),
          project_profile: Map.get(retry_entry, :project_profile),
          ownership:
            Map.get(retry_entry, :ownership) ||
              if(MapSet.member?(state.claimed, issue_id), do: :retained_owner, else: :unowned_backoff)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata, opts) do
    opts = Keyword.merge(opts, issue_retry_attempt: attempt, retry_metadata: metadata)

    case retry_issue_fetch(issue_id, metadata, opts) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata, opts)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        if reason == :approved_project_profiles_removed do
          retire_retry_execution_context(nil, metadata)
          {:noreply, transition_retry_release_id(state, issue_id, opts)}
        else
          {:noreply,
           schedule_issue_retry(
             state,
             issue_id,
             attempt + 1,
             Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
           )}
        end
    end
  end

  defp retry_issue_fetch(issue_id, metadata, opts) do
    case Keyword.get(opts, :retry_fetch_fun) do
      fetcher when is_function(fetcher, 2) -> fetcher.(issue_id, metadata)
      _ -> retry_issue_fetch(issue_id, metadata)
    end
  end

  defp retry_issue_fetch(issue_id, %{project_profile: %{key: _key}} = metadata) do
    retry_issue_fetch_unfiltered(issue_id, metadata, &Tracker.fetch_issue_states_by_ids/1)
  end

  defp retry_issue_fetch(_issue_id, _metadata), do: Tracker.fetch_candidate_issues()

  defp retry_issue_fetch_unfiltered(issue_id, %{project_profile: %{key: key}}, fetch_fun) do
    case current_project_profiles_result() do
      {:ok, nil} ->
        {:error, :approved_project_profiles_removed}

      {:ok, profiles} ->
        case approved_profile_result(profiles, key) do
          {:ok, _profile} -> fetch_fun.([issue_id])
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:approved_project_profiles_read_failed, reason}}
    end
  end

  defp retry_issue_fetch_unfiltered(issue_id, metadata, _fetch_fun), do: retry_issue_fetch(issue_id, metadata)

  defp approved_profile_result(nil, _key), do: {:error, :approved_project_profiles_removed}

  defp approved_profile_result(profiles, key) do
    case ProjectProfiles.fetch(profiles, key) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, :approved_project_profiles_removed}
    end
  end

  defp current_project_profiles_result do
    case Config.settings() do
      {:ok, settings} -> {:ok, settings.project_profiles}
      error -> error
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata, opts) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        retire_retry_execution_context(issue, metadata)

        {:noreply, transition_retry_release(state, issue, opts)}

      retry_project_identity_changed?(metadata, issue) ->
        Logger.warning(
          "Retry issue project identity changed; releasing claim: " <>
            "#{issue_context(issue)} project_id=#{inspect(issue.project_id)}"
        )

        retire_retry_execution_context(issue, metadata)

        {:noreply, transition_retry_release(state, issue, opts)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata, opts)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, transition_retry_release(state, issue, opts)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata, opts) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, transition_retry_release_id(state, issue_id, opts)}
  end

  defp retry_project_identity_changed?(
         %{execution_context: %ProjectExecutionContext{linear_project_id: expected_project_id}},
         %Issue{project_id: refreshed_project_id}
       ) do
    not project_ids_match?(expected_project_id, refreshed_project_id)
  end

  defp retry_project_identity_changed?(_metadata, _issue), do: false

  defp retire_retry_execution_context(
         _issue,
         %{execution_context: %ProjectExecutionContext{issue_identifier: identifier}} = metadata
       ) do
    retire_execution_context(
      identifier,
      metadata[:worker_host],
      metadata[:execution_context],
      metadata[:workspace_attestation]
    )
  end

  defp retire_retry_execution_context(%Issue{identifier: identifier}, metadata) do
    retire_execution_context(
      identifier,
      metadata[:worker_host],
      metadata[:execution_context],
      metadata[:workspace_attestation]
    )
  end

  defp cleanup_issue_workspace(
         identifier,
         worker_host \\ nil,
         execution_context \\ nil,
         workspace_attestation \\ nil
       )

  defp cleanup_issue_workspace(
         identifier,
         worker_host,
         %ProjectExecutionContext{} = execution_context,
         nil
       )
       when is_binary(identifier) do
    case Workspace.attest_existing_issue_workspace(identifier, worker_host, execution_context) do
      {:ok, workspace_attestation} ->
        cleanup_issue_workspace(
          identifier,
          worker_host,
          execution_context,
          workspace_attestation
        )

      {:error, reason} ->
        Logger.warning(
          "Skipping terminal workspace cleanup " <>
            "profile=#{execution_context.profile_key} " <>
            "worker_host=#{worker_host || "local"} " <>
            "issue_identifier=#{identifier}; attestation failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp cleanup_issue_workspace(
         identifier,
         worker_host,
         execution_context,
         workspace_attestation
       )
       when is_binary(identifier) do
    cleanup_options = [workspace_attestation: workspace_attestation, exact_worker_host: true]
    Workspace.remove_issue_workspaces(identifier, worker_host, execution_context, cleanup_options)
  end

  defp cleanup_issue_workspace(
         _identifier,
         _worker_host,
         _execution_context,
         _workspace_attestation
       ),
       do: :ok

  defp run_terminal_workspace_cleanup do
    settings = Config.settings!()

    case settings.project_profiles do
      %{profiles: profiles} when map_size(profiles) > 0 ->
        cleanup_terminal_profiles(
          ProjectProfiles.list(settings.project_profiles),
          settings.tracker.terminal_states,
          &Tracker.fetch_issues_by_states/2,
          fn identifier, worker_host, execution_context, workspace_attestation ->
            cleanup_issue_workspace(
              identifier,
              worker_host,
              execution_context,
              workspace_attestation
            )
          end
        )

      _legacy ->
        cleanup_terminal_fetch(Tracker.fetch_issues_by_states(settings.tracker.terminal_states), nil)
    end
  end

  defp cleanup_terminal_profiles(profiles, terminal_states, fetcher, cleanup_fun) do
    profiles
    |> Enum.flat_map(&fetch_terminal_profile(&1, terminal_states, fetcher))
    |> Enum.reduce({MapSet.new(), []}, &collect_terminal_cleanup_target/2)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.each(fn {identifier, execution_context} ->
      attest_and_cleanup_terminal_workspace(cleanup_fun, identifier, execution_context)
    end)
  end

  defp collect_terminal_cleanup_target(
         %Issue{identifier: identifier} = issue,
         {seen, cleanup_targets}
       )
       when is_binary(identifier) do
    case terminal_cleanup_context(issue) do
      {:ok, execution_context} ->
        add_terminal_cleanup_target(identifier, execution_context, seen, cleanup_targets)

      {:error, reason} ->
        Logger.warning(
          "Skipping startup terminal workspace cleanup issue_identifier=#{identifier}; " <>
            "invalid execution authority: #{inspect(reason)}"
        )

        {seen, cleanup_targets}
    end
  end

  defp collect_terminal_cleanup_target(_issue, accumulator), do: accumulator

  defp add_terminal_cleanup_target(identifier, execution_context, seen, cleanup_targets) do
    cleanup_identity = {execution_context.linear_project_id, identifier}

    if MapSet.member?(seen, cleanup_identity) do
      {seen, cleanup_targets}
    else
      {MapSet.put(seen, cleanup_identity), [{identifier, execution_context} | cleanup_targets]}
    end
  end

  defp attest_and_cleanup_terminal_workspace(cleanup_fun, identifier, execution_context) do
    cleanup_worker_hosts()
    |> Enum.each(fn worker_host ->
      attest_and_cleanup_terminal_worker(cleanup_fun, identifier, worker_host, execution_context)
    end)
  end

  defp cleanup_worker_hosts do
    [nil | Config.settings!().worker.ssh_hosts]
  end

  defp attest_and_cleanup_terminal_worker(
         cleanup_fun,
         identifier,
         worker_host,
         execution_context
       ) do
    case Workspace.attest_existing_issue_workspace(identifier, worker_host, execution_context) do
      {:ok, workspace_attestation} ->
        safely_cleanup_terminal_workspace(
          cleanup_fun,
          identifier,
          worker_host,
          execution_context.profile_key,
          execution_context,
          workspace_attestation
        )

      {:error, reason} ->
        Logger.warning(
          "Skipping startup terminal workspace cleanup " <>
            "profile=#{execution_context.profile_key} " <>
            "worker_host=#{worker_host || "local"} " <>
            "issue_identifier=#{identifier}; attestation failed: #{inspect(reason)}"
        )
    end
  end

  defp terminal_cleanup_context(%Issue{} = issue) do
    case ProjectExecutionContext.from_issue(issue) do
      {:ok, execution_context} ->
        {:ok, execution_context}

      {:error, :missing_routing_revision} ->
        case ClaimService.exclusive_route(issue) do
          {:ok, %{routing_revision: routing_revision}} ->
            ProjectExecutionContext.from_issue(%{issue | routing_revision: routing_revision})

          error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_terminal_profile(profile, terminal_states, fetcher) do
    result =
      try do
        fetcher.(profile, terminal_states)
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, issues} when is_list(issues) ->
        issues

      {:error, reason} ->
        Logger.warning(
          "Skipping startup terminal workspace cleanup profile=#{profile.key}; " <>
            "failed to fetch terminal issues: #{inspect(reason)}"
        )

        []

      other ->
        Logger.warning(
          "Skipping startup terminal workspace cleanup profile=#{profile.key}; " <>
            "invalid terminal issue result: #{inspect(other)}"
        )

        []
    end
  end

  defp cleanup_terminal_fetch(result, profile_key, cleanup_fun \\ &cleanup_issue_workspace/1) do
    case result do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            safely_cleanup_terminal_workspace(cleanup_fun, identifier, nil, profile_key, nil, nil)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning(
          "Skipping startup terminal workspace cleanup profile=#{profile_key || "legacy"}; " <>
            "failed to fetch terminal issues: #{inspect(reason)}"
        )
    end
  end

  defp safely_cleanup_terminal_workspace(
         cleanup_fun,
         identifier,
         worker_host,
         profile_key,
         execution_context,
         workspace_attestation
       ) do
    result =
      invoke_terminal_cleanup(
        cleanup_fun,
        identifier,
        worker_host,
        execution_context,
        workspace_attestation
      )

    case result do
      {:error, reason} ->
        Logger.warning(
          "Skipping failed terminal workspace cleanup " <>
            "profile=#{profile_key || "legacy"} " <>
            "issue_identifier=#{identifier}: #{inspect(reason)}"
        )

      _other ->
        :ok
    end
  rescue
    exception ->
      Logger.warning("Skipping failed terminal workspace cleanup profile=#{profile_key || "legacy"} issue_identifier=#{identifier}: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Skipping failed terminal workspace cleanup profile=#{profile_key || "legacy"} issue_identifier=#{identifier}: #{inspect({kind, reason})}")
      :ok
  end

  defp invoke_terminal_cleanup(
         cleanup_fun,
         identifier,
         worker_host,
         execution_context,
         workspace_attestation
       ) do
    case :erlang.fun_info(cleanup_fun, :arity) do
      {:arity, 4} ->
        cleanup_fun.(identifier, worker_host, execution_context, workspace_attestation)

      {:arity, 3} ->
        cleanup_fun.(identifier, execution_context, workspace_attestation)

      {:arity, 2} ->
        cleanup_fun.(identifier, execution_context)

      {:arity, 1} ->
        cleanup_fun.(identifier)
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata, opts) do
    if is_map(metadata[:project_profile]) do
      profile = current_retry_project_profile(metadata) || metadata[:project_profile]
      issue = %{issue | project_profile: profile}

      refresh_fun =
        Keyword.get(opts, :profile_refresh_fun, fn ids ->
          Tracker.fetch_issue_states_by_ids(profile, ids)
        end)

      {:noreply,
       dispatch_multi_project_candidate(
         state,
         issue,
         Keyword.get(opts, :project_profiles, current_project_profiles()),
         Keyword.merge(opts,
           profile_retry_attempt: attempt,
           issue_retry_attempt: attempt,
           preferred_worker_host: metadata[:worker_host],
           retry_metadata: metadata,
           refresh_fun: refresh_fun
         )
       )}
    else
      handle_legacy_active_retry(state, issue, attempt, metadata)
    end
  end

  defp current_retry_project_profile(%{project_profile: %{key: key}}) do
    with {:ok, profiles} <- current_project_profiles_result(),
         {:ok, profile} <- approved_profile_result(profiles, key) do
      profile
    else
      _ -> nil
    end
  end

  defp handle_legacy_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    case ClaimService.release(issue_id) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Unable to release database claim issue_id=#{issue_id}: #{inspect(reason)}")
    end

    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retire_lost_claim(%State{} = state, issue_id) do
    :ok = finalize_distributed_claim(issue_id, :release)
    cancel_issue_retry_timer(Map.get(state.retry_attempts, issue_id))

    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp cancel_issue_retry_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_issue_retry_timer(_retry), do: :ok

  defp finalize_distributed_claim(issue_id, action) when action in [:release, :complete] do
    result =
      case action do
        :release -> ClaimService.release(issue_id)
        :complete -> ClaimService.complete(issue_id)
      end

    case result do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp report_candidate_fetch_outcome(opts, profile, %{status: :ok}) do
    report_health(opts, {:stage, :candidate_fetch, health_profile_metadata(profile, :succeeded)})
  end

  defp report_candidate_fetch_outcome(opts, profile, %{status: :timeout}) do
    report_health(opts, {
      :stage,
      :candidate_fetch,
      health_profile_metadata(profile, :failed, :poll_timeout)
    })
  end

  defp report_candidate_fetch_outcome(opts, profile, _outcome) do
    report_health(opts, {
      :stage,
      :candidate_fetch,
      health_profile_metadata(profile, :failed, :poll_error)
    })
  end

  defp health_profile_metadata(%{key: profile_key}, status, failure_category \\ nil) do
    %{profile_key: profile_key, status: status}
    |> maybe_put_health_failure(failure_category)
  end

  defp health_issue_metadata(%Issue{} = issue, status, failure_category \\ nil) do
    issue
    |> safe_issue_health_metadata()
    |> Map.put(:status, status)
    |> maybe_put_health_failure(failure_category)
  end

  defp safe_issue_health_metadata(issue) do
    case ProjectExecutionContext.from_issue(issue) do
      {:ok, context} ->
        ProjectExecutionContext.safe_metadata(context)

      {:error, _reason} ->
        %{
          profile_key: get_in(issue, [Access.key(:project_profile), Access.key(:key)]) || issue.project_slug,
          issue_id: issue.id,
          issue_identifier: issue.identifier
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    end
  end

  defp maybe_put_health_failure(metadata, nil), do: metadata
  defp maybe_put_health_failure(metadata, failure_category), do: Map.put(metadata, :failure_category, failure_category)

  defp observed_call(fun, on_failure) when is_function(fun, 0) and is_function(on_failure, 1) do
    fun.()
  rescue
    exception ->
      on_failure.(:callback_exception)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      on_failure.(:callback_failure)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp report_health(opts, event) do
    case Keyword.get(opts, :health_fun) do
      health_fun when is_function(health_fun, 1) -> health_fun.(event)
      _other -> report_runtime_health(event)
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp report_runtime_health({:stage, stage, metadata}),
    do: RuntimeHealth.stage(runtime_health_server(), stage, metadata)

  defp report_runtime_health({:dependency, dependency, metadata}),
    do: RuntimeHealth.dependency(runtime_health_server(), dependency, metadata)

  defp report_runtime_health(:poll_succeeded), do: RuntimeHealth.poll_succeeded(runtime_health_server())

  defp report_runtime_health({:stop, metadata}), do: RuntimeHealth.stop(runtime_health_server(), metadata)

  defp runtime_health_server do
    Application.get_env(:symphony_elixir, :runtime_health_server, RuntimeHealth)
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call({:finding_complete, issue_id, evidence}, _from, state) do
    entry =
      state.review_convergence
      |> Map.get(issue_id, %{})
      |> invalidate_merge_ready_result()
      |> Map.put(:landing_evidence, evidence)

    review_convergence = Map.put(state.review_convergence, issue_id, entry)
    {:reply, :ok, %{state | review_convergence: review_convergence}}
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    profile_retries =
      state.profile_retry_attempts
      |> Enum.map(fn {profile, %{attempt: attempt, due_at_ms: due_at_ms, reason: reason}} ->
        %{
          profile: profile,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          reason: reason
        }
      end)
      |> Enum.sort_by(& &1.profile)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       profile_retries: profile_retries,
       blocked: blocked,
       review_convergence: observable_review_convergence(state.review_convergence),
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       health: runtime_health_snapshot(),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp runtime_health_snapshot do
    RuntimeHealth.snapshot(runtime_health_server())
  rescue
    _exception -> unknown_runtime_health()
  catch
    _kind, _reason -> unknown_runtime_health()
  end

  defp unknown_runtime_health do
    %{
      last_successful_poll_at: :unknown,
      dependencies: %{
        linear: %{status: :unknown, failure_category: nil},
        claim_store: %{status: :unknown, failure_category: nil}
      },
      stages: [],
      final_stop: :unknown,
      history: []
    }
  end

  defp invalidate_merge_ready_result(%{terminal_result: {:merge_ready_candidate, _candidate}} = entry),
    do: %{entry | terminal_result: nil}

  defp invalidate_merge_ready_result(%{terminal_result: {:merge_ready_blocked, _blockers}} = entry),
    do: %{entry | terminal_result: nil}

  defp invalidate_merge_ready_result(entry), do: entry

  defp observable_review_convergence(review_convergence) do
    review_convergence
    |> Enum.map(fn {issue_id, entry} ->
      %{
        issue_id: issue_id,
        handoff_recorded?: is_map(entry[:landing_evidence]),
        terminal_result: entry[:terminal_result],
        blocker: entry[:global_blocker]
      }
    end)
    |> Enum.sort_by(& &1.issue_id)
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
