defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger

  alias SymphonyElixir.{
    ClaimService,
    Codex.AppServer,
    Config,
    GitHubReviewClient,
    HandoffReceipt,
    Linear.Issue,
    ReviewConvergence
  }

  alias SymphonyElixir.{PromptBuilder, ReadinessGate, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.prepare_for_issue(issue, worker_host) do
      {:ok, %{path: workspace, readiness_state: readiness_state} = preparation} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        run_result =
          try do
            with :ok <- Workspace.preflight(workspace, issue, worker_host),
                 {:ok, receipt} <-
                   verify_readiness(workspace, issue, worker_host, readiness_state, opts),
                 :ok <-
                   persist_readiness(
                     preparation,
                     issue,
                     receipt,
                     worker_host,
                     opts
                   ),
                 :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
                 {:ok, current_issue, handoff_resume} <-
                   prepare_handoff(issue, receipt, workspace, worker_host, opts) do
              run_codex_turns(
                workspace,
                current_issue,
                codex_update_recipient,
                Keyword.put(opts, :handoff_resume, handoff_resume),
                worker_host
              )
            else
              {:stop, %Issue{} = current_issue} ->
                Logger.info("Skipping Codex because refreshed issue is inactive or unroutable: #{issue_context(current_issue)}")

                :ok

              {:error, {:workspace_preflight_failed, _type, _command, _status, _output} = reason} ->
                {:deferred_workspace_preflight_failure, reason}

              {:error, {:workspace_preflight_failed, _type, _command, _detail} = reason} ->
                {:deferred_workspace_preflight_failure, reason}

              {:error, {:readiness_gate_failed, %ReadinessGate.Failure{}} = reason} ->
                {:deferred_workspace_preflight_failure, reason}

              {:error, {:readiness_state_failed, _state_reason} = reason} ->
                {:deferred_workspace_preflight_failure, reason}

              other ->
                other
            end
          after
            Workspace.run_after_run_hook(workspace, issue, worker_host)
          end

        case run_result do
          {:deferred_workspace_preflight_failure, reason} ->
            handle_workspace_preflight_failure(codex_update_recipient, issue, worker_host, workspace, reason)

          other ->
            other
        end

      {:error, reason} ->
        case readiness_state_error_workspace(reason) do
          {:ok, workspace} ->
            send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

            Workspace.run_after_run_hook(workspace, issue, worker_host)

            handle_workspace_preflight_failure(
              codex_update_recipient,
              issue,
              worker_host,
              workspace,
              {:readiness_state_failed, reason}
            )

          :error ->
            {:error, reason}
        end
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp handle_workspace_preflight_failure(recipient, issue, worker_host, workspace, reason) do
    case send_hard_blocker(recipient, issue, worker_host, workspace, reason) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp send_hard_blocker(recipient, %Issue{id: issue_id}, worker_host, workspace, reason)
       when is_binary(issue_id) and is_pid(recipient) do
    send(
      recipient,
      {:agent_hard_blocker, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace,
         error: hard_blocker_message(reason)
       }}
    )

    :ok
  end

  defp send_hard_blocker(_recipient, _issue, _worker_host, _workspace, reason) do
    {:error, {:agent_hard_blocker_unreported, reason}}
  end

  defp hard_blocker_message({:workspace_preflight_failed, type, command, status, output}) do
    "workspace preflight failed type=#{type} command=#{command} status=#{status} output=#{inline_text(output)}"
  end

  defp hard_blocker_message({:workspace_preflight_failed, type, command, detail}) do
    "workspace preflight failed type=#{type} command=#{command} detail=#{inline_text(detail)}"
  end

  defp hard_blocker_message({:readiness_gate_failed, %ReadinessGate.Failure{} = failure}) do
    "workspace readiness failed code=#{failure.code} command=#{failure.command || "n/a"} detail=#{inline_text(failure.detail)} action=#{inline_text(failure.operator_action)}"
  end

  defp hard_blocker_message({:readiness_state_failed, reason}) do
    "workspace readiness state failed detail=#{inline_text(inspect(reason))} action=Preserve the workspace and repair or recreate its durable readiness state before retrying."
  end

  defp verify_readiness(workspace, issue, worker_host, readiness_state, opts) do
    readiness_opts =
      [workspace_readiness_state: readiness_state, worker_host: worker_host]
      |> maybe_put_readiness_command_runner(Keyword.get(opts, :readiness_command_runner))

    case ReadinessGate.check(workspace, issue, readiness_opts) do
      {:ok, receipt} ->
        Logger.info(
          "Workspace readiness verified for #{issue_context(issue)} classification=#{receipt.classification} issue_branch=#{receipt.issue_branch} head_sha=#{receipt.head_sha} canonical_ref=#{receipt.canonical.ref} canonical_sha=#{receipt.canonical.fetched_sha}"
        )

        {:ok, receipt}

      {:error, %ReadinessGate.Failure{} = failure} ->
        {:error, {:readiness_gate_failed, failure}}
    end
  end

  defp persist_readiness(preparation, issue, receipt, worker_host, opts) do
    persistence_opts =
      case Keyword.get(opts, :readiness_command_runner) do
        runner when is_function(runner, 1) -> [command_runner: runner]
        _runner -> []
      end

    case Workspace.mark_readiness_ready(
           preparation,
           issue,
           receipt,
           worker_host,
           persistence_opts
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:readiness_state_failed, reason}}
    end
  end

  defp readiness_state_error_workspace({kind, workspace, _detail})
       when kind in [
              :workspace_readiness_identity_mismatch,
              :workspace_readiness_state_changed,
              :workspace_readiness_state_invalid,
              :workspace_readiness_state_missing,
              :workspace_readiness_state_read_failed,
              :workspace_readiness_state_write_failed,
              :workspace_changed_before_readiness_persist
            ] and is_binary(workspace) do
    {:ok, workspace}
  end

  defp readiness_state_error_workspace(_reason), do: :error

  defp maybe_put_readiness_command_runner(opts, runner) when is_function(runner, 1) do
    Keyword.put(opts, :command_runner, runner)
  end

  defp maybe_put_readiness_command_runner(opts, _runner), do: opts

  defp prepare_handoff(issue, readiness, workspace, worker_host, opts) do
    case Keyword.get(opts, :distributed_claim) do
      claim when is_map(claim) ->
        prepare_distributed_handoff(issue, readiness, workspace, worker_host, claim, opts)

      _claim ->
        {:ok, issue, nil}
    end
  end

  defp prepare_distributed_handoff(issue, readiness, workspace, worker_host, _claim, opts) do
    ready? = Keyword.get(opts, :handoff_receipt_ready?, &ClaimService.handoff_receipt_ready?/0)
    context = Keyword.get(opts, :handoff_context, &ClaimService.handoff_context/1)
    issue_fetcher = Keyword.get(opts, :handoff_issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with true <- ready?.() || {:error, :handoff_receipt_contract_unavailable},
         {:ok, fresh_issue} <- fetch_handoff_issue(issue.id, issue_fetcher) do
      if handoff_issue_runnable?(fresh_issue) do
        continue_distributed_handoff(
          fresh_issue,
          readiness,
          workspace,
          worker_host,
          context,
          opts
        )
      else
        {:stop, fresh_issue}
      end
    end
  end

  defp continue_distributed_handoff(
         fresh_issue,
         readiness,
         workspace,
         worker_host,
         context,
         opts
       ) do
    with {:ok, connection, claim} <- context.(fresh_issue.id),
         {:ok, repository, owner, name} <- handoff_repository(),
         {:ok, git_evidence} <-
           HandoffReceipt.workspace_evidence(workspace, readiness.issue_branch, repository, worker_host),
         {:ok, pr} <- handoff_pull_request(repository, readiness.issue_branch, opts) do
      run_handoff_transaction(
        connection,
        claim,
        fresh_issue,
        readiness,
        git_evidence,
        pr,
        repository,
        owner,
        name
      )
    end
  end

  defp run_handoff_transaction(
         connection,
         claim,
         fresh_issue,
         readiness,
         git_evidence,
         pr,
         repository,
         owner,
         name
       ) do
    transaction_result =
      Postgrex.transaction(connection, fn transaction ->
        transaction
        |> run_locked_handoff(
          claim,
          fresh_issue,
          readiness,
          git_evidence,
          pr,
          repository,
          owner,
          name
        )
        |> finish_handoff_transaction(transaction)
      end)

    unwrap_handoff_transaction(transaction_result)
  end

  defp finish_handoff_transaction({:ok, _issue, _resume} = result, _transaction), do: result

  defp finish_handoff_transaction({:error, reason}, transaction),
    do: Postgrex.rollback(transaction, reason)

  defp unwrap_handoff_transaction({:ok, result}), do: result
  defp unwrap_handoff_transaction({:error, reason}), do: {:error, reason}

  defp run_locked_handoff(
         connection,
         claim,
         fresh_issue,
         readiness,
         git_evidence,
         pr,
         repository,
         owner,
         name
       ) do
    with :ok <- lock_handoff_claim(connection, claim),
         {:ok, previous} <- HandoffReceipt.latest(connection, claim),
         {:ok, truth} <-
           handoff_truth(
             previous,
             fresh_issue,
             readiness,
             git_evidence,
             claim,
             connection,
             repository,
             pr
           ),
         resume <- HandoffReceipt.resume(previous, truth),
         attrs <- checkpoint_attrs(previous, resume, readiness, git_evidence, owner, name),
         {:ok, checkpoint} <- HandoffReceipt.append(connection, claim, attrs),
         {:ok, checkpoint_effects} <-
           HandoffReceipt.effect_statuses(connection, claim, checkpoint.effect_operation_ids),
         verified_resume <-
           HandoffReceipt.resume(checkpoint, Map.put(truth, :effect_operations, checkpoint_effects)) do
      Logger.info("Handoff checkpoint restored for #{issue_context(fresh_issue)} result=#{inspect(verified_resume)}")

      {:ok, fresh_issue, %{decision: verified_resume, effect_operation_ids: checkpoint.effect_operation_ids}}
    end
  end

  defp lock_handoff_claim(connection, claim) do
    case HandoffReceipt.effect_statuses(connection, claim, []) do
      {:ok, _effects} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handoff_issue_runnable?(%Issue{} = issue),
    do: active_issue_state?(issue.state) and issue_routable?(issue)

  @doc false
  @spec handoff_issue_runnable_for_test(Issue.t()) :: boolean()
  def handoff_issue_runnable_for_test(issue), do: handoff_issue_runnable?(issue)

  defp fetch_handoff_issue(issue_id, issue_fetcher) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{id: ^issue_id} = issue]} -> {:ok, issue}
      {:ok, []} -> {:error, :handoff_issue_not_found}
      {:ok, _issues} -> {:error, :handoff_issue_response_invalid}
      {:error, reason} -> {:error, {:handoff_issue_fetch_failed, reason}}
    end
  end

  defp handoff_repository do
    case Config.settings!().review_convergence.repository do
      repository when is_binary(repository) ->
        case String.split(repository, "/", parts: 2) do
          [owner, name] -> {:ok, repository, owner, name}
          _parts -> {:error, :handoff_repository_invalid}
        end

      _repository ->
        {:error, :handoff_repository_unconfigured}
    end
  end

  defp handoff_truth(previous, issue, readiness, git_evidence, claim, connection, repository, pr) do
    operation_ids = if previous, do: previous.effect_operation_ids, else: []

    with {:ok, effects} <- HandoffReceipt.effect_statuses(connection, claim, operation_ids) do
      {:ok,
       %{
         issue_id: issue.id,
         canonical_owner: repository |> String.split("/", parts: 2) |> hd(),
         canonical_repository: repository |> String.split("/", parts: 2) |> List.last(),
         branch: readiness.issue_branch,
         worktree_fingerprint: git_evidence.worktree_fingerprint,
         remote_branch_sha: handoff_remote_sha(previous, git_evidence.remote_branch_sha),
         commit_sha: handoff_commit_sha(previous, git_evidence.head_sha),
         pr_number: pr.number,
         pr_ready?: handoff_pr_ready?(pr, git_evidence),
         linear_updated_at: issue.updated_at,
         active_claim?: same_claim_revision?(claim, issue.updated_at),
         effect_operations: effects
       }}
    end
  end

  defp handoff_pr_ready?(%{number: nil}, _git_evidence), do: false

  defp handoff_pr_ready?(pr, git_evidence) do
    pr.ready? and is_binary(pr.head_sha) and
      pr.head_sha == git_evidence.head_sha and
      pr.head_sha == git_evidence.remote_branch_sha
  end

  @doc false
  @spec handoff_pr_ready_for_test(map(), map()) :: boolean()
  def handoff_pr_ready_for_test(pr, git_evidence), do: handoff_pr_ready?(pr, git_evidence)

  defp handoff_pull_request(repository, branch, opts) do
    snapshot = Keyword.get(opts, :handoff_review_snapshot, &GitHubReviewClient.snapshot/2)

    case snapshot.(repository, branch) do
      {:ok, current} ->
        max_rounds = Config.settings!().review_convergence.max_fix_rounds
        converged? = match?({:converged, _evidence}, ReviewConvergence.evaluate(current, 0, max_rounds))

        {:ok,
         %{
           number: current.pull_request_number,
           head_sha: current.current_head_sha,
           ready?: current.pr_ready? and converged?
         }}

      {:error, :pull_request_not_found} ->
        {:ok, %{number: nil, head_sha: nil, ready?: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handoff_commit_sha(nil, _head_sha), do: nil
  defp handoff_commit_sha(%{commit_sha: nil}, _head_sha), do: nil
  defp handoff_commit_sha(_previous, head_sha), do: head_sha

  defp handoff_remote_sha(%{completed_step_ids: completed}, remote_sha) do
    if :push in completed, do: remote_sha, else: nil
  end

  defp handoff_remote_sha(_previous, _remote_sha), do: nil

  defp same_claim_revision?(%{linear_updated_at: claim_revision}, %DateTime{} = issue_revision),
    do: DateTime.compare(claim_revision, issue_revision) == :eq

  defp same_claim_revision?(_claim, _issue_revision), do: false

  defp checkpoint_attrs(previous, {:ok, _next}, _readiness, _git_evidence, _owner, _name)
       when is_map(previous) do
    Map.take(previous, [
      :canonical_owner,
      :canonical_repository,
      :branch,
      :worktree_fingerprint,
      :remote_branch_sha,
      :commit_sha,
      :pr_number,
      :current_phase,
      :completed_step_ids,
      :pending_step_ids,
      :test_results,
      :effect_operation_ids
    ])
  end

  defp checkpoint_attrs(_previous, _resume, readiness, git_evidence, owner, name) do
    %{
      canonical_owner: owner,
      canonical_repository: name,
      branch: readiness.issue_branch,
      worktree_fingerprint: git_evidence.worktree_fingerprint,
      remote_branch_sha: nil,
      commit_sha: nil,
      pr_number: nil,
      current_phase: :implementation,
      completed_step_ids: [:preflight, :branch],
      pending_step_ids: [:implementation, :tests, :commit, :push, :pull_request, :review],
      test_results: [],
      effect_operation_ids: []
    }
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    distributed_claim = Keyword.get(opts, :distributed_claim)
    effect_ledger_ready? = Keyword.get(opts, :effect_ledger_ready?, &ClaimService.effect_ledger_ready?/0)

    with {:ok, managed_session} <- managed_session_mode(distributed_claim, effect_ledger_ready?),
         {:ok, session} <-
           AppServer.start_session(workspace,
             worker_host: worker_host,
             managed_session: managed_session,
             managed_issue_id: if(managed_session, do: issue.id)
           ) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp managed_session_mode(distributed_claim, effect_ledger_ready?) when is_map(distributed_claim) do
    if effect_ledger_ready?.(), do: {:ok, true}, else: {:error, :effect_ledger_contract_unavailable}
  end

  defp managed_session_mode(_distributed_claim, _effect_ledger_ready?), do: {:ok, false}

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    base =
      PromptBuilder.build_prompt(issue, opts) <>
        "\n\nFor managed runs, call handoff_checkpoint after every durable safe transition: implementation, tests, commit, push, pull request, and review. Include all completed/pending steps, structured test evidence, and managed effect operation IDs.\n"

    case Keyword.get(opts, :handoff_resume) do
      %{decision: {:ok, next}, effect_operation_ids: operation_ids} ->
        base <>
          "\n\nVerified handoff: resume at #{next}. Recheck external state before side effects." <>
          handoff_effect_context(operation_ids)

      %{decision: {:safe_recheck, reason}, effect_operation_ids: operation_ids} ->
        base <>
          "\n\nHandoff could not be trusted (#{inspect(reason)}). Recheck all external state before continuing." <>
          handoff_effect_context(operation_ids)

      _none ->
        base
    end
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp handoff_effect_context(operation_ids) do
    "\nKnown canonical managed effect IDs: #{Jason.encode!(operation_ids)}. Reuse the exact existing ID for the same intended effect; do not mint a replacement key.\n"
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp inline_text(value) when is_binary(value) do
    value
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp inline_text(value), do: inspect(value)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
