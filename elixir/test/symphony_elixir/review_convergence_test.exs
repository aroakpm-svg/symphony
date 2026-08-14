defmodule SymphonyElixir.ReviewConvergenceTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubReviewClient
  alias SymphonyElixir.Linear.{Adapter, Issue}
  alias SymphonyElixir.ReviewConvergence
  alias SymphonyElixir.ReviewMonitor

  defmodule ReviewClient do
    @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
    def snapshot(_repository, _branch), do: Application.fetch_env!(:symphony_elixir, :review_snapshot)

    @spec request_review(String.t(), pos_integer(), String.t()) :: :ok
    def request_review(repository, number, key) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:review_requested, repository, number, key})
      :ok
    end

    @spec review_request_exists?(String.t(), pos_integer(), String.t()) :: {:ok, boolean()}
    def review_request_exists?(_repository, _number, key) do
      {:ok, key in Application.get_env(:symphony_elixir, :existing_review_keys, [])}
    end

    @spec publish_status(String.t(), String.t(), atom(), String.t(), String.t() | nil) :: :ok
    def publish_status(repository, head_sha, state, description, _target_url) do
      send(
        Application.fetch_env!(:symphony_elixir, :review_recipient),
        {:status, repository, head_sha, state, description}
      )

      :ok
    end
  end

  defmodule Tracker do
    @spec fetch_routed_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_routed_issues_by_states(_states), do: {:ok, Application.fetch_env!(:symphony_elixir, :review_issues)}

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(_states), do: {:ok, Application.fetch_env!(:symphony_elixir, :review_issues)}

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
    def fetch_issue_states_by_ids([issue_id]) do
      case Application.get_env(:symphony_elixir, :verified_issue_state, "In Progress") do
        {:error, reason} ->
          {:error, reason}

        state ->
          issue = Application.fetch_env!(:symphony_elixir, :review_issues) |> hd()
          {:ok, [%{issue | id: issue_id, state: state}]}
      end
    end

    @spec review_history(String.t()) :: {:ok, map()} | {:error, term()}
    def review_history(_issue_id),
      do: Application.get_env(:symphony_elixir, :review_history, {:ok, %{dedup: MapSet.new(), rework_count: 0}})

    @spec create_comment(String.t(), String.t()) :: :ok
    def create_comment(issue_id, body) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:comment, issue_id, body})
      :ok
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:state, issue_id, state})
      Application.get_env(:symphony_elixir, :review_state_result, :ok)
    end
  end

  defmodule FailingIssueTracker do
    @spec fetch_routed_issues_by_states([String.t()]) :: {:error, :linear_unavailable}
    def fetch_routed_issues_by_states(_states), do: {:error, :linear_unavailable}
  end

  defmodule FailingClaimService do
    @spec claim(Issue.t(), pid()) :: {:error, :claim_service_unavailable}
    def claim(_issue, _owner), do: {:error, :claim_service_unavailable}
  end

  defmodule AutonomousClaimService do
    @spec claim(Issue.t(), pid()) :: {:ok, map()}
    def claim(issue, owner) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:autonomous_call, :claim})

      {:ok,
       %{
         issue_id: issue.id,
         claim_id: "11111111-1111-4111-8111-111111111111",
         generation: Application.get_env(:symphony_elixir, :claim_generation, 1),
         acquisition: Application.get_env(:symphony_elixir, :claim_acquisition, :new),
         owner: owner,
         worker: Application.get_env(:symphony_elixir, :claim_worker)
       }}
    end

    @spec bind_worker(String.t(), pid()) :: :ok
    def bind_worker(_issue_id, _worker) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:autonomous_call, :bind_worker})
      :ok
    end

    @spec effect_context(String.t()) :: {:ok, (String.t(), list() -> term()), map()}
    def effect_context(_issue_id) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:autonomous_call, :effect_context})
      {:ok, fn _sql, _params -> :unused end, claim_context()}
    end

    @spec release(String.t()) :: :ok
    def release(_issue_id) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:autonomous_call, :release})
      :ok
    end

    def release_if_owned(_issue_id, identity) do
      owner = Application.fetch_env!(:symphony_elixir, :review_recipient)
      worker = Application.get_env(:symphony_elixir, :claim_worker)

      if identity == %{
           claim_id: "11111111-1111-4111-8111-111111111111",
           generation: Application.get_env(:symphony_elixir, :claim_generation, 1)
         } and owner == self() and worker in [nil, self()] do
        send(owner, {:autonomous_call, :release_if_owned})
        :ok
      else
        {:error, :claim_ownership_changed}
      end
    end

    defp claim_context do
      %{
        issue_id: "issue-160",
        claim_id: "11111111-1111-4111-8111-111111111111",
        generation: Application.get_env(:symphony_elixir, :claim_generation, 1),
        node_id: "22222222-2222-4222-8222-222222222222",
        node_instance_id: "33333333-3333-4333-8333-333333333333"
      }
    end
  end

  defmodule AutonomousEffectLedger do
    @spec list_operations(term(), map()) :: {:ok, [map()]}
    def list_operations(_connection, _claim_context) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:autonomous_call, :list_operations})
      {:ok, Application.get_env(:symphony_elixir, :autonomous_operations, [])}
    end
  end

  defmodule FailingAutonomousEffectLedger do
    @spec list_operations(term(), map()) :: {:error, :readback_failed}
    def list_operations(_connection, _claim_context), do: {:error, :readback_failed}
  end

  defmodule CountingPatchAuthorization do
    @spec authorize(map(), map(), map(), [map()], map()) :: SymphonyElixir.PatchAuthorization.result()
    def authorize(disposition, receipt, claim, effects, runtime) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:autonomous_call, :authorize})
      SymphonyElixir.PatchAuthorization.authorize(disposition, receipt, claim, effects, runtime)
    end
  end

  defmodule ReviewSettlementOwner do
    @spec settle(map(), map()) :: :ok
    def settle(_finding, _context), do: :ok
  end

  setup do
    Application.put_env(:symphony_elixir, :review_recipient, self())
    Application.put_env(:symphony_elixir, :review_issues, [issue()])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :review_recipient)
      Application.delete_env(:symphony_elixir, :review_issues)
      Application.delete_env(:symphony_elixir, :review_snapshot)
      Application.delete_env(:symphony_elixir, :existing_review_keys)
      Application.delete_env(:symphony_elixir, :review_history)
      Application.delete_env(:symphony_elixir, :linear_client_module)
      Application.delete_env(:symphony_elixir, :review_state_result)
      Application.delete_env(:symphony_elixir, :verified_issue_state)
      Application.delete_env(:symphony_elixir, :autonomous_operations)
      Application.delete_env(:symphony_elixir, :claim_acquisition)
      Application.delete_env(:symphony_elixir, :claim_generation)
      Application.delete_env(:symphony_elixir, :claim_worker)
    end)
  end

  test "review convergence config is disabled by default and fail-closed when enabled without a repository" do
    assert {:ok, config} = Schema.parse(%{})
    refute config.review_convergence.enabled

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"review_convergence" => %{"enabled" => true}})

    assert message =~ "review_convergence.repository"

    assert {:error, {:invalid_workflow_config, malformed_message}} =
             Schema.parse(%{
               "review_convergence" => %{"enabled" => true, "repository" => "symphony"}
             })

    assert malformed_message =~ "must use owner/name format"
  end

  test "raw actionable threads remain blocking when an empty finding summary is present" do
    snapshot =
      snapshot(%{
        threads: [%{priority: 1, resolved: false, body: "P1"}],
        finding_summary: %{decisions: [], requires_lifecycle?: false}
      })

    assert {:rework, %{actionable_threads: [_]}} = ReviewConvergence.evaluate(snapshot, 0, 3)
  end

  test "invalid finding summaries fail closed before convergence" do
    assert {:wait, %{reason: :finding_summary_invalid}} =
             ReviewConvergence.evaluate(
               snapshot(%{finding_summary: %{decisions: :invalid}}),
               0,
               3
             )

    assert {:wait, %{reason: :finding_summary_invalid}} =
             ReviewConvergence.evaluate(snapshot(%{finding_summary: :invalid}), 0, 3)
  end

  test "autonomous global preflight failure performs no external write" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{finding_summary: %{decisions: [], requires_lifecycle?: false}})}
    )

    state =
      ReviewMonitor.run_with(
        %{},
        settings(),
        ReviewClient,
        Tracker,
        %{profile: :aroak_autonomous_v1, claim_service: FailingClaimService}
      )

    assert state["issue-160"].global_blocker == :claim_service_unavailable
    refute_received {:comment, _, _}
    refute_received {:state, _, _}
    refute_received {:status, _, _, _, _}
  end

  test "successful autonomous recovery clears a stale global blocker" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{finding_summary: %{decisions: [], requires_lifecycle?: false}})}
    )

    entry = %{
      "issue-160" => %{
        evaluated_head_sha: "old-head",
        decisions: %{"old-finding" => %{disposition: :blocked_unverified}},
        pending_effect_ids: ["old-operation"],
        global_blocker: :pending_effects,
        authorization_required: false,
        terminal_result: nil
      }
    }

    state =
      ReviewMonitor.run_with(
        entry,
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state["issue-160"].global_blocker == nil
    assert state["issue-160"].pending_effect_ids == []
    assert state["issue-160"].decisions == %{}
  end

  test "autonomous profile bypasses the legacy advisory status publisher" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{finding_summary: %{decisions: [], requires_lifecycle?: false}})}
    )

    state =
      ReviewMonitor.run_with(
        %{},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state["issue-160"].decisions == %{}
    assert state["issue-160"].pending_effect_ids == []
    refute_received {:status, _, _, _, _}
    assert_receive {:autonomous_call, :claim}
    assert_receive {:autonomous_call, :bind_worker}
    assert_receive {:autonomous_call, :effect_context}
    assert_receive {:autonomous_call, :list_operations}
    assert_receive {:autonomous_call, :release}
  end

  test "autonomous readback loads the configured effect ledger before introspection" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{finding_summary: %{decisions: [], requires_lifecycle?: false}})}
    )

    lazy_effect_ledger =
      prepare_unloaded_module(
        Module.concat(__MODULE__, RuntimeEffectLedger),
        """
        def list_operations(_connection, _claim_context) do
          send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:lazy_autonomous_call, :list_operations})
          {:ok, []}
        end
        """
      )

    refute function_exported?(lazy_effect_ledger, :list_operations, 2)

    state =
      ReviewMonitor.run_with(
        %{},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: lazy_effect_ledger
        }
      )

    assert state["issue-160"].global_blocker == nil
    assert_receive {:lazy_autonomous_call, :list_operations}
  end

  test "autonomous owner API checks load configured modules before introspection" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         finding_summary: %{
           decisions: [%{finding_key_digest: "finding-1", disposition: :fix_in_current_pr}],
           requires_lifecycle?: true
         }
       })}
    )

    lazy_effect_ledger =
      prepare_unloaded_module(
        Module.concat(__MODULE__, RuntimeOwnerEffectLedger),
        """
        def list_operations(_connection, _claim_context), do: {:ok, []}
        """
      )

    lazy_authorization =
      prepare_unloaded_module(
        Module.concat(__MODULE__, RuntimePatchAuthorization),
        """
        def authorize(_issue, _finding, _patch, _head, _context), do: :ok
        """
      )

    lazy_settlement =
      prepare_unloaded_module(
        Module.concat(__MODULE__, RuntimeReviewSettlement),
        """
        def settle(_finding, _context), do: :ok
        """
      )

    state =
      ReviewMonitor.run_with(
        %{},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: lazy_effect_ledger,
          patch_authorization: lazy_authorization,
          review_settlement: lazy_settlement
        }
      )

    assert state["issue-160"].global_blocker == :root_cause_receipt_unavailable
  end

  test "autonomous monitor invokes Design 3 once after claim binding and returns an opaque grant" do
    head = String.duplicate("a", 40)

    facts = %{
      repository: "aroakpm-svg/repo",
      pull_request_number: 42,
      source_head_sha: head,
      review_thread_id: "thread-design-3",
      selected_review_comment_id: "comment-design-3",
      body: "P1 causal failure"
    }

    {:ok, finding_key} = SymphonyElixir.FindingDisposition.build_finding_key(facts)
    {:ok, lineage_key} = SymphonyElixir.FindingDisposition.build_lineage_key(facts)

    decision = %{
      disposition: :fix_in_current_pr,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      finding_key_digest: finding_key.digest
    }

    receipt = design3_receipt(finding_key, lineage_key, head)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         current_head_sha: head,
         finding_summary: %{decisions: [decision], requires_lifecycle?: true}
       })}
    )

    options = %{
      profile: :aroak_autonomous_v1,
      claim_service: AutonomousClaimService,
      effect_ledger: AutonomousEffectLedger,
      patch_authorization: CountingPatchAuthorization,
      review_settlement: ReviewSettlementOwner,
      root_cause_receipts: %{finding_key.digest => receipt},
      authorization_runtime: %{circuit_breaker: :clear, causal_history_complete?: true, prior_attempts: []}
    }

    initial_state = %{
      "issue-160" => %{
        authorization_results: %{"removed-finding" => {:blocked, :stale_result}}
      }
    }

    state = ReviewMonitor.run_with(initial_state, settings(), ReviewClient, Tracker, options)

    digest = finding_key.digest
    assert {:grant, %{^digest => grant}} = state["issue-160"].terminal_result
    assert grant.authorization == :bounded_managed_mutation
    assert state["issue-160"].authorization_required
    assert Map.keys(state["issue-160"].authorization_results) == [digest]
    assert [attempt] = state["issue-160"].causal_attempts
    assert attempt.finding_lineage_digest == lineage_key.digest
    assert attempt.causal_attempt_fingerprint == receipt.causal_attempt_fingerprint
    assert attempt.causal_evidence_digest == receipt.causal_evidence_digest
    assert_receive {:autonomous_call, :authorize}
    refute_received {:autonomous_call, :release}

    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)
    state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker, options)
    assert {:grant, _grants} = state["issue-160"].terminal_result
    assert length(state["issue-160"].causal_attempts) == 1
    refute_receive {:autonomous_call, :authorize}
    refute_received {:autonomous_call, :release}
    refute_received {:comment, _, _}
    refute_received {:state, _, _}
    refute_received {:status, _, _, _, _}

    stopped =
      ReviewMonitor.run_with(
        state,
        settings(),
        ReviewClient,
        Tracker,
        put_in(options, [:authorization_runtime, :circuit_breaker], :open)
      )

    assert stopped["issue-160"].global_blocker == :safety_stopped
    assert_receive {:autonomous_call, :authorize}
    assert_receive {:autonomous_call, :release}
  end

  test "retained grants continue only under the exact owning claim and release after consumption" do
    head = String.duplicate("a", 40)
    grant = %{claim_id: "11111111-1111-4111-8111-111111111111", generation: 1}

    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{current_head_sha: head, finding_summary: %{decisions: [], requires_lifecycle?: false}})}
    )

    state = %{
      "issue-160" => %{
        authorization_required: true,
        terminal_result: {:grant, %{"finding" => grant}}
      }
    }

    options = %{
      profile: :aroak_autonomous_v1,
      claim_service: AutonomousClaimService,
      effect_ledger: AutonomousEffectLedger
    }

    continued = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker, options)
    assert continued["issue-160"].global_blocker == nil
    assert_receive {:autonomous_call, :release}

    foreign =
      put_in(
        state,
        ["issue-160", :terminal_result],
        {:grant, %{"finding" => %{grant | generation: 2}}}
      )

    blocked = ReviewMonitor.run_with(foreign, settings(), ReviewClient, Tracker, options)
    assert blocked["issue-160"].global_blocker == :claim_already_owned
  end

  test "a retained grant transferred to a running worker is not reconciled or released by the monitor" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    grant = %{claim_id: "11111111-1111-4111-8111-111111111111", generation: 1}
    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)
    Application.put_env(:symphony_elixir, :claim_worker, worker)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{finding_summary: %{decisions: [], requires_lifecycle?: false}})}
    )

    state = %{
      "issue-160" => %{
        authorization_required: true,
        terminal_result: {:grant, %{"finding" => grant}}
      }
    }

    options = %{
      profile: :aroak_autonomous_v1,
      claim_service: AutonomousClaimService,
      effect_ledger: AutonomousEffectLedger
    }

    blocked = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker, options)

    assert blocked["issue-160"].global_blocker == :claim_already_owned
    refute_received {:autonomous_call, :bind_worker}
    refute_received {:autonomous_call, :release}
  end

  test "a retained grant holds its claim across polls while nothing consumes it" do
    head = String.duplicate("a", 40)

    facts = %{
      repository: "aroakpm-svg/repo",
      pull_request_number: 42,
      source_head_sha: head,
      review_thread_id: "thread-retained-loop",
      selected_review_comment_id: "comment-retained-loop",
      body: "P1 retained loop"
    }

    {:ok, finding_key} = SymphonyElixir.FindingDisposition.build_finding_key(facts)
    {:ok, lineage_key} = SymphonyElixir.FindingDisposition.build_lineage_key(facts)

    decision = %{
      disposition: :fix_in_current_pr,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      finding_key_digest: finding_key.digest
    }

    receipt = design3_receipt(finding_key, lineage_key, head)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         current_head_sha: head,
         finding_summary: %{decisions: [decision], requires_lifecycle?: true}
       })}
    )

    options = %{
      profile: :aroak_autonomous_v1,
      claim_service: AutonomousClaimService,
      effect_ledger: AutonomousEffectLedger,
      patch_authorization: CountingPatchAuthorization,
      review_settlement: ReviewSettlementOwner,
      root_cause_receipts: %{finding_key.digest => receipt},
      authorization_runtime: %{circuit_breaker: :clear, causal_history_complete?: true, prior_attempts: []}
    }

    granted = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker, options)
    assert {:grant, _grants} = granted["issue-160"].terminal_result

    # From here nothing an authorization decision depends on changes: same head, same
    # decision set, same receipt, same claim identity, same circuit breaker. The only
    # new fact on each poll is that the monitor already holds an unconsumed grant.
    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)

    final =
      Enum.reduce(1..5, granted, fn _round, acc ->
        ReviewMonitor.run_with(acc, settings(), ReviewClient, Tracker, options)
      end)

    assert {:grant, _grants} = final["issue-160"].terminal_result

    calls = drain_autonomous_calls()

    # Retention is deliberate: a monitor must not release the claim its own grant is
    # bound to, so `releasable_result?/1` holds while the grant is unconsumed. This
    # boundary performs no mutation, so nothing consumes the grant here and the claim
    # is renewed on every poll. In production that renewal is bounded by the
    # ClaimService lease; within this boundary there is no earlier exit.
    assert Enum.count(calls, &(&1 == :claim)) == 6
    refute Enum.any?(calls, &(&1 == :release))
  end

  defp drain_autonomous_calls(acc \\ []) do
    receive do
      {:autonomous_call, call} -> drain_autonomous_calls([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a new head alone cannot reauthorize the same causal attempt" do
    old_head = String.duplicate("a", 40)
    new_head = String.duplicate("b", 40)

    facts = %{
      repository: "aroakpm-svg/repo",
      pull_request_number: 42,
      source_head_sha: old_head,
      review_thread_id: "thread-design-3-repeat",
      selected_review_comment_id: "comment-design-3-repeat",
      body: "P1 repeated causal failure"
    }

    {:ok, finding_key} = SymphonyElixir.FindingDisposition.build_finding_key(facts)
    {:ok, lineage_key} = SymphonyElixir.FindingDisposition.build_lineage_key(facts)

    decision = %{
      disposition: :fix_in_current_pr,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      finding_key_digest: finding_key.digest
    }

    old_receipt = design3_receipt(finding_key, lineage_key, old_head)

    options = %{
      profile: :aroak_autonomous_v1,
      claim_service: AutonomousClaimService,
      effect_ledger: AutonomousEffectLedger,
      patch_authorization: CountingPatchAuthorization,
      review_settlement: ReviewSettlementOwner,
      root_cause_receipts: %{finding_key.digest => old_receipt},
      authorization_runtime: %{circuit_breaker: :clear, causal_history_complete?: true, prior_attempts: []}
    }

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         current_head_sha: old_head,
         finding_summary: %{decisions: [decision], requires_lifecycle?: true}
       })}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker, options)
    assert {:grant, _grants} = state["issue-160"].terminal_result

    new_receipt =
      old_receipt
      |> Map.put(:evaluated_head_sha, new_head)
      |> Map.put(:authorized_head_sha, new_head)
      |> put_in([:pre_mutation_regression, :head_sha], new_head)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         current_head_sha: new_head,
         finding_summary: %{decisions: [decision], requires_lifecycle?: true}
       })}
    )

    blocked =
      ReviewMonitor.run_with(
        state,
        settings(),
        ReviewClient,
        Tracker,
        put_in(options, [:root_cause_receipts, finding_key.digest], new_receipt)
      )

    assert blocked["issue-160"].global_blocker == :non_progress_blocked
    assert blocked["issue-160"].terminal_result == {:blocked, :non_progress_blocked}
    assert_receive {:autonomous_call, :release}
  end

  test "authorization cache never replays a grant under a new claim generation" do
    head = String.duplicate("a", 40)

    facts = %{
      repository: "aroakpm-svg/repo",
      pull_request_number: 42,
      source_head_sha: head,
      review_thread_id: "thread-new-claim",
      selected_review_comment_id: "comment-new-claim",
      body: "P1 claim transition"
    }

    {:ok, finding_key} = SymphonyElixir.FindingDisposition.build_finding_key(facts)
    {:ok, lineage_key} = SymphonyElixir.FindingDisposition.build_lineage_key(facts)

    decision = %{
      disposition: :fix_in_current_pr,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      finding_key_digest: finding_key.digest
    }

    receipt = design3_receipt(finding_key, lineage_key, head)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{current_head_sha: head, finding_summary: %{decisions: [decision], requires_lifecycle?: true}})}
    )

    options = %{
      profile: :aroak_autonomous_v1,
      claim_service: AutonomousClaimService,
      effect_ledger: AutonomousEffectLedger,
      patch_authorization: CountingPatchAuthorization,
      review_settlement: ReviewSettlementOwner,
      root_cause_receipts: %{finding_key.digest => receipt},
      authorization_runtime: %{circuit_breaker: :clear, causal_history_complete?: true, prior_attempts: []}
    }

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker, options)
    assert_receive {:autonomous_call, :authorize}

    Application.put_env(:symphony_elixir, :claim_generation, 2)
    transitioned = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker, options)

    assert_receive {:autonomous_call, :authorize}
    assert transitioned["issue-160"].global_blocker == :non_progress_blocked
  end

  test "pending ledger effects block autonomous execution before owner APIs" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         finding_summary: %{
           decisions: [%{finding_key_digest: "finding-1", disposition: :fix_in_current_pr}],
           requires_lifecycle?: true
         }
       })}
    )

    Application.put_env(
      :symphony_elixir,
      :autonomous_operations,
      [
        %{
          operation_id: "issue-160:operation-1",
          request_fingerprint: "fingerprint",
          status: :pending
        }
      ]
    )

    state =
      ReviewMonitor.run_with(
        %{},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state["issue-160"].global_blocker == :pending_effects
    assert state["issue-160"].pending_effect_ids == ["issue-160:operation-1"]
    assert state["issue-160"].authorization_required == false
    refute_received {:comment, _, _}
    refute_received {:state, _, _}
    refute_received {:status, _, _, _, _}
  end

  test "releasing a retained claim invalidates its stale grant for every fail-closed exit" do
    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         finding_summary: %{
           decisions: [%{finding_key_digest: "finding-1", disposition: :fix_in_current_pr}],
           requires_lifecycle?: true
         }
       })}
    )

    retained = %{
      authorization_required: true,
      retained_claim: %{claim_id: "11111111-1111-4111-8111-111111111111", generation: 1},
      terminal_result:
        {:grant,
         %{
           "finding-1" => %{
             claim_id: "11111111-1111-4111-8111-111111111111",
             generation: 1
           }
         }}
    }

    cases = [
      {:pending_effects, AutonomousEffectLedger, [%{operation_id: "issue-160:operation-1", request_fingerprint: "fingerprint", status: :pending}]},
      {:owner_api_unavailable, AutonomousEffectLedger, []},
      {:readback_failed, FailingAutonomousEffectLedger, []}
    ]

    for {expected_blocker, ledger, operations} <- cases do
      Application.put_env(:symphony_elixir, :autonomous_operations, operations)

      result =
        ReviewMonitor.run_with(
          %{"issue-160" => retained},
          settings(),
          ReviewClient,
          Tracker,
          %{
            profile: :aroak_autonomous_v1,
            claim_service: AutonomousClaimService,
            effect_ledger: ledger
          }
        )

      entry = result["issue-160"]
      assert entry.global_blocker == expected_blocker
      refute match?({:grant, _}, entry.terminal_result)
      assert entry.retained_claim == nil
      refute entry.authorization_required
      assert_receive {:autonomous_call, :release}
    end
  end

  test "fail-closed exits invalidate retained grants even when claim release is forbidden" do
    grant = %{
      authorization_required: true,
      retained_claim: %{claim_id: "11111111-1111-4111-8111-111111111111", generation: 1},
      terminal_result:
        {:grant,
         %{
           "finding-1" => %{
             claim_id: "11111111-1111-4111-8111-111111111111",
             generation: 1
           }
         }}
    }

    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})

    unavailable =
      ReviewMonitor.run_with(
        %{"issue-160" => grant},
        settings(),
        ReviewClient,
        Tracker,
        %{profile: :aroak_autonomous_v1, claim_service: AutonomousClaimService}
      )

    assert unavailable["issue-160"].global_blocker == :github_unavailable
    assert unavailable["issue-160"].terminal_result == nil
    assert unavailable["issue-160"].retained_claim == grant.retained_claim
    refute unavailable["issue-160"].authorization_required
    refute_received {:autonomous_call, :release}

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{finding_summary: %{decisions: [], requires_lifecycle?: false}})}
    )

    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)
    Application.put_env(:symphony_elixir, :claim_generation, 2)

    ownership_changed =
      ReviewMonitor.run_with(
        %{"issue-160" => grant},
        settings(),
        ReviewClient,
        Tracker,
        %{profile: :aroak_autonomous_v1, claim_service: AutonomousClaimService}
      )

    assert ownership_changed["issue-160"].global_blocker == :claim_already_owned
    assert ownership_changed["issue-160"].terminal_result == nil
    assert ownership_changed["issue-160"].retained_claim == grant.retained_claim
    refute ownership_changed["issue-160"].authorization_required
    refute_received {:autonomous_call, :release}
  end

  test "tracker enumeration failure invalidates grants but preserves conditional claim recovery identity" do
    retained = %{claim_id: "11111111-1111-4111-8111-111111111111", generation: 1}

    state = %{
      "issue-160" => %{
        authorization_required: true,
        retained_claim: retained,
        terminal_result: {:grant, %{"finding-1" => retained}}
      }
    }

    failed =
      ReviewMonitor.run_with(
        state,
        settings(),
        ReviewClient,
        FailingIssueTracker,
        %{profile: :aroak_autonomous_v1, claim_service: AutonomousClaimService}
      )

    assert failed["issue-160"].terminal_result == nil
    assert failed["issue-160"].retained_claim == retained
    refute failed["issue-160"].authorization_required
    refute_received {:autonomous_call, :release}
  end

  test "an unresolved managed effect releases claim capacity and is read back by a fresh generation" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         finding_summary: %{
           decisions: [%{finding_key_digest: "finding-1", disposition: :fix_in_current_pr}],
           requires_lifecycle?: true
         }
       })}
    )

    Application.put_env(
      :symphony_elixir,
      :autonomous_operations,
      [%{operation_id: "issue-160:operation-1", request_fingerprint: "fingerprint", status: :pending}]
    )

    options = %{
      profile: :aroak_autonomous_v1,
      claim_service: AutonomousClaimService,
      effect_ledger: AutonomousEffectLedger
    }

    blocked = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker, options)

    assert blocked["issue-160"].global_blocker == :pending_effects
    assert_receive {:autonomous_call, :release}

    # Readback accepts prior-generation operations, so a fresh claim can continue
    # reconciliation without one In Review issue monopolising claim capacity.
    Application.put_env(:symphony_elixir, :claim_generation, 2)
    retried = ReviewMonitor.run_with(blocked, settings(), ReviewClient, Tracker, options)

    assert retried["issue-160"].global_blocker == :pending_effects
    assert retried["issue-160"].pending_effect_ids == ["issue-160:operation-1"]
    assert_receive {:autonomous_call, :release}

    # Once the effect resolves, the claim is no longer load-bearing and goes back.
    Application.put_env(
      :symphony_elixir,
      :autonomous_operations,
      [%{operation_id: "issue-160:operation-1", request_fingerprint: "fingerprint", status: :succeeded}]
    )

    resolved = ReviewMonitor.run_with(retried, settings(), ReviewClient, Tracker, options)

    assert resolved["issue-160"].pending_effect_ids == []
    assert_received {:autonomous_call, :release}
  end

  test "a foreign existing claim is still rejected when no retention is recorded" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         finding_summary: %{
           decisions: [%{finding_key_digest: "finding-1", disposition: :fix_in_current_pr}],
           requires_lifecycle?: true
         }
       })}
    )

    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)

    state =
      ReviewMonitor.run_with(
        %{},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state["issue-160"].global_blocker == :claim_already_owned
    refute_received {:autonomous_call, :release}
  end

  test "an inactive routed issue releases a valid retained claim before its entry is dropped" do
    retained = %{
      claim_id: "11111111-1111-4111-8111-111111111111",
      generation: 1
    }

    Application.put_env(:symphony_elixir, :review_issues, [])

    state =
      ReviewMonitor.run_with(
        %{"issue-160" => %{retained_claim: retained}},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state == %{}
    assert_receive {:autonomous_call, :release_if_owned}
  end

  test "an inactive malformed retention record cannot release a claim" do
    Application.put_env(:symphony_elixir, :review_issues, [])

    state =
      ReviewMonitor.run_with(
        %{"issue-160" => %{retained_claim: %{claim_id: "", generation: 1}}},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state == %{}
    refute_received {:autonomous_call, :release_if_owned}
  end

  test "an inactive unconsumed grant releases its still monitor-owned claim" do
    grant = %{claim_id: "11111111-1111-4111-8111-111111111111", generation: 1}
    Application.put_env(:symphony_elixir, :review_issues, [])

    state =
      ReviewMonitor.run_with(
        %{
          "issue-160" => %{
            retained_claim: nil,
            terminal_result: {:grant, %{"finding" => grant}}
          }
        },
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state == %{}
    assert_receive {:autonomous_call, :release_if_owned}
  end

  test "inactive cleanup cannot release a retained claim transferred to a worker" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    Application.put_env(:symphony_elixir, :claim_worker, worker)
    Application.put_env(:symphony_elixir, :review_issues, [])

    retained = %{
      claim_id: "11111111-1111-4111-8111-111111111111",
      generation: 1
    }

    state =
      ReviewMonitor.run_with(
        %{"issue-160" => %{retained_claim: retained}},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state == %{}
    refute_received {:autonomous_call, :release_if_owned}
  end

  test "the monitor never rebinds a retained claim transferred to a running worker" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)
    Application.put_env(:symphony_elixir, :claim_worker, worker)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{finding_summary: %{decisions: [], requires_lifecycle?: false}})}
    )

    retained = %{
      claim_id: "11111111-1111-4111-8111-111111111111",
      generation: 1
    }

    state =
      ReviewMonitor.run_with(
        %{"issue-160" => %{retained_claim: retained}},
        settings(),
        ReviewClient,
        Tracker,
        %{
          profile: :aroak_autonomous_v1,
          claim_service: AutonomousClaimService,
          effect_ledger: AutonomousEffectLedger
        }
      )

    assert state["issue-160"].global_blocker == :claim_already_owned
    refute_received {:autonomous_call, :bind_worker}
    refute_received {:autonomous_call, :release}
    Process.exit(worker, :kill)
  end

  test "a malformed retention record cannot assert ownership of an existing claim" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok,
       snapshot(%{
         finding_summary: %{
           decisions: [%{finding_key_digest: "finding-1", disposition: :fix_in_current_pr}],
           requires_lifecycle?: true
         }
       })}
    )

    Application.put_env(:symphony_elixir, :claim_acquisition, :existing)

    options = %{
      profile: :aroak_autonomous_v1,
      claim_service: AutonomousClaimService,
      effect_ledger: AutonomousEffectLedger
    }

    for retained <- [
          %{claim_id: "11111111-1111-4111-8111-111111111111", generation: nil},
          %{claim_id: "", generation: 1},
          %{claim_id: nil, generation: 1}
        ] do
      state = ReviewMonitor.run_with(%{"issue-160" => %{retained_claim: retained}}, settings(), ReviewClient, Tracker, options)

      assert state["issue-160"].global_blocker == :claim_already_owned
      refute_received {:autonomous_call, :release}
    end
  end

  test "missing expected GitHub Actions checks fail closed instead of treating zero rows as passing" do
    assert {:ok, checks} = GitHubReviewClient.normalize_expected_checks_for_test(%{"check_runs" => []})

    assert checks == [
             %{name: "make-all", state: :missing, link: nil},
             %{name: "validate-pr-description", state: :missing, link: nil}
           ]
  end

  test "expected checks require exact job and GitHub Actions app identities" do
    run = fn name, slug, id, conclusion ->
      %{
        "name" => name,
        "status" => "completed",
        "conclusion" => conclusion,
        "details_url" => "url/#{name}",
        "app" => %{"slug" => slug, "id" => id}
      }
    end

    payload = %{
      "check_runs" => [
        run.("make-all", "github-actions", 15_368, "success"),
        run.("validate-pr-description", "impostor", 15_368, "success"),
        run.("validate-pr-description", "github-actions", 15_368, "failure")
      ]
    }

    assert {:ok,
            [
              %{name: "make-all", state: :success},
              %{name: "validate-pr-description", state: :failure}
            ]} = GitHubReviewClient.normalize_expected_checks_for_test(payload)
  end

  test "check-run REST pages are all merged before expected checks are selected" do
    first = %{"check_runs" => [%{"name" => "unrelated"}]}

    second = %{
      "check_runs" => [
        %{
          "name" => "make-all",
          "status" => "completed",
          "conclusion" => "success",
          "app" => %{"slug" => "github-actions", "id" => 15_368}
        },
        %{
          "name" => "validate-pr-description",
          "status" => "completed",
          "conclusion" => "success",
          "app" => %{"slug" => "github-actions", "id" => 15_368}
        }
      ]
    }

    assert {:ok, payload} = GitHubReviewClient.merge_check_run_pages_for_test([first, second])

    assert {:ok, [%{state: :success}, %{state: :success}]} =
             GitHubReviewClient.normalize_expected_checks_for_test(payload)
  end

  test "GitHub skipped conclusion uses the explicitly allowed skipped gate state" do
    run = fn name ->
      %{
        "name" => name,
        "status" => "completed",
        "conclusion" => "skipped",
        "app" => %{"slug" => "github-actions", "id" => 15_368}
      }
    end

    assert {:ok, [%{state: :skipped}, %{state: :skipped}]} =
             GitHubReviewClient.normalize_expected_checks_for_test(%{
               "check_runs" => [run.("make-all"), run.("validate-pr-description")]
             })
  end

  test "formal pass requires the trusted reviewer database identity on the current head" do
    trusted = %{
      "body" => "No major issues found",
      "state" => "COMMENTED",
      "commit" => %{"oid" => "head"},
      "author" => %{
        "login" => "chatgpt-codex-connector",
        "__typename" => "Organization",
        "databaseId" => 261_883_814
      }
    }

    assert GitHubReviewClient.accepted_review_for_test?(trusted, "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(trusted, ["author", "databaseId"], 123), "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(trusted, ["commit", "oid"], "old"), "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "state" => "DISMISSED"}, "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "state" => "PENDING"}, "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "body" => "No major issues found"}, "other")

    bot = %{
      trusted
      | "author" => %{
          "login" => "chatgpt-codex-connector[bot]",
          "__typename" => "Bot",
          "databaseId" => 199_175_422
        }
    }

    assert GitHubReviewClient.accepted_review_for_test?(bot, "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(bot, ["author", "databaseId"], 123), "head")

    issue_comment = %{
      "body" => "No major issues found\n\n**Reviewed commit:** `head`",
      "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot", "id" => 199_175_422}
    }

    refute GitHubReviewClient.accepted_review_for_test?(issue_comment, "head")
  end

  test "formal pass uses only the latest unambiguous trusted current-head review" do
    head = "head"

    clean = %{
      "body" => "No major issues found",
      "state" => "COMMENTED",
      "submittedAt" => "2026-07-22T01:00:00Z",
      "commit" => %{"oid" => head},
      "author" => %{
        "login" => "chatgpt-codex-connector",
        "__typename" => "Organization",
        "databaseId" => 261_883_814
      }
    }

    assert GitHubReviewClient.latest_accepted_review_for_test([clean], head) == clean

    conflicting = %{
      clean
      | "body" => "Changes required",
        "state" => "CHANGES_REQUESTED",
        "submittedAt" => "2026-07-22T01:01:00Z"
    }

    refute GitHubReviewClient.latest_accepted_review_for_test([clean, conflicting], head)
    refute GitHubReviewClient.latest_accepted_review_for_test([clean, Map.delete(conflicting, "submittedAt")], head)
  end

  test "trusted current-head clean comment attests only to its unique earlier request" do
    head = String.duplicate("a", 40)
    request = review_request_comment(head)
    clean = clean_attestation_comment(String.slice(head, 0, 10))

    assert GitHubReviewClient.accepted_comment_attestation_for_test([request, clean], head) == clean

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, %{clean | "created_at" => "2026-07-22T00:59:00Z"}],
             head
           )

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, clean_attestation_comment("bbbbbbbbbb")],
             head
           )
  end

  test "comment attestation rejects duplicate requests and invalidates on a new head" do
    head = String.duplicate("a", 40)
    request = review_request_comment(head)
    clean = clean_attestation_comment(String.slice(head, 0, 10))

    refute GitHubReviewClient.accepted_comment_attestation_for_test([request, request, clean], head)
    refute GitHubReviewClient.accepted_comment_attestation_for_test([request, clean], String.duplicate("b", 40))
  end

  test "comment attestation rejects multiple trusted responses after one request" do
    head = String.duplicate("a", 40)
    request = review_request_comment(head)
    clean = clean_attestation_comment(String.slice(head, 0, 10))
    later = %{clean | "created_at" => "2026-07-22T01:06:00Z"}

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, clean, later],
             head
           )
  end

  test "comment attestation rejects impersonation, general comments, and missing app identity" do
    head = String.duplicate("a", 40)
    request = review_request_comment(head)
    clean = clean_attestation_comment(String.slice(head, 0, 10))

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, put_in(clean, ["user", "id"], 123)],
             head
           )

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, Map.put(clean, "performed_via_github_app", nil)],
             head
           )

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, %{clean | "body" => "Looks good to me\n\n**Reviewed commit:** `aaaaaaaaaa`"}],
             head
           )
  end

  test "pending required checks returned with gh exit status 8 remain pending evidence" do
    output = Jason.encode!([%{"name" => "ci", "bucket" => "pending", "state" => "PENDING", "link" => "url"}])

    assert {:ok, [%{name: "ci", state: :pending}]} =
             GitHubReviewClient.normalize_required_checks_for_test(output, 8)
  end

  test "protected required checks normalize the gh skipping bucket as skipped" do
    output = Jason.encode!([%{"name" => "optional", "bucket" => "skipping", "state" => "SKIPPED", "link" => "url"}])

    assert {:ok, [%{name: "optional", state: :skipped}]} =
             GitHubReviewClient.normalize_required_checks_for_test(output, 0)
  end

  test "protected required checks are merged with bootstrap checks and cannot be masked" do
    expected = [
      %{name: "make-all", state: :success, link: "expected"},
      %{name: "validate-pr-description", state: :success, link: nil}
    ]

    protected = [
      %{name: "security", state: :pending, link: "security"},
      %{name: "make-all", state: :failure, link: "protected"}
    ]

    assert GitHubReviewClient.merge_required_checks_for_test(expected, protected) == [
             %{name: "make-all", state: :failure, link: "expected"},
             %{name: "security", state: :pending, link: "security"},
             %{name: "validate-pr-description", state: :success, link: nil}
           ]
  end

  test "authoritative ruleset and branch-protection contexts retain app identity" do
    rules = [
      %{
        "type" => "required_status_checks",
        "parameters" => %{
          "required_status_checks" => [
            %{"context" => "linux", "integration_id" => 42},
            %{"context" => "Review Convergence Gate", "integration_id" => nil}
          ]
        }
      }
    ]

    protection = %{"checks" => [%{"context" => "lint", "app_id" => 7}]}

    assert {:ok, contexts} =
             GitHubReviewClient.normalize_required_contexts_for_test(rules, protection)

    assert contexts == [%{name: "lint", app_id: 7}, %{name: "linux", app_id: 42}]
  end

  test "branch-protection app_id minus one allows any check provider" do
    protection = %{"checks" => [%{"context" => "lint", "app_id" => -1}]}

    assert {:ok, [%{name: "lint", app_id: nil}]} =
             GitHubReviewClient.normalize_required_contexts_for_test([], protection)

    assert {:ok, [%{name: "lint", state: :success}]} =
             GitHubReviewClient.match_required_contexts_for_test(
               [%{name: "lint", app_id: nil}],
               %{
                 "check_runs" => [
                   %{
                     "name" => "lint",
                     "status" => "completed",
                     "conclusion" => "success",
                     "app" => %{"id" => 99}
                   }
                 ]
               }
             )
  end

  test "disabled classic required checks are absence, not an evidence error" do
    assert {:ok, nil} =
             GitHubReviewClient.normalize_branch_protection_response_for_test(
               "gh: Required status checks are not enabled for this branch. (HTTP 404)",
               1
             )

    assert {:error, {:required_status_checks_failed, 1, _}} =
             GitHubReviewClient.normalize_branch_protection_response_for_test(
               "gh: resource unavailable (HTTP 404)",
               1
             )
  end

  test "required contexts absent from current-head evidence are synthesized as missing" do
    contexts = [%{name: "linux", app_id: 42}, %{name: "lint", app_id: nil}]

    payload = %{
      "check_runs" => [
        %{
          "name" => "linux",
          "status" => "completed",
          "conclusion" => "success",
          "details_url" => "wrong-app",
          "app" => %{"id" => 9}
        }
      ]
    }

    assert {:ok, checks} = GitHubReviewClient.match_required_contexts_for_test(contexts, payload)
    assert checks == [%{name: "linux", state: :missing, link: nil}, %{name: "lint", state: :missing, link: nil}]
  end

  test "partial and complete current-head required evidence preserve pending and success" do
    contexts = [%{name: "linux", app_id: 42}, %{name: "lint", app_id: nil}]

    pending = %{
      "name" => "linux",
      "status" => "in_progress",
      "details_url" => "linux",
      "app" => %{"id" => 42}
    }

    success = %{
      "name" => "lint",
      "status" => "completed",
      "conclusion" => "success",
      "details_url" => "lint",
      "app" => %{"id" => 7}
    }

    assert {:ok, [%{state: :pending}, %{state: :success}]} =
             GitHubReviewClient.match_required_contexts_for_test(contexts, %{
               "check_runs" => [pending, success]
             })

    assert {:ok, [%{state: :success}, %{state: :success}]} =
             GitHubReviewClient.match_required_contexts_for_test(contexts, %{
               "check_runs" => [
                 pending |> Map.put("status", "completed") |> Map.put("conclusion", "success"),
                 success
               ]
             })
  end

  test "a newer queued rerun keeps a required context pending" do
    contexts = [%{name: "linux", app_id: 42}]

    old_success = %{
      "name" => "linux",
      "status" => "completed",
      "conclusion" => "success",
      "completed_at" => "2026-07-22T01:05:00Z",
      "created_at" => "2026-07-22T01:00:00Z",
      "details_url" => "old",
      "app" => %{"id" => 42}
    }

    queued_rerun = %{
      "name" => "linux",
      "status" => "queued",
      "created_at" => "2026-07-22T01:06:00Z",
      "details_url" => "new",
      "app" => %{"id" => 42}
    }

    assert {:ok, [%{state: :pending, link: "new"}]} =
             GitHubReviewClient.match_required_contexts_for_test(
               contexts,
               %{"check_runs" => [old_success, queued_rerun]}
             )
  end

  test "legacy required commit statuses are matched on the current head" do
    contexts = [%{name: "jenkins", app_id: nil}]
    statuses = [%{"context" => "jenkins", "state" => "success", "target_url" => "jenkins/url"}]

    assert {:ok, [%{name: "jenkins", state: :success, link: "jenkins/url"}]} =
             GitHubReviewClient.match_required_contexts_for_test(
               contexts,
               %{"check_runs" => []},
               statuses
             )
  end

  test "app-bound required contexts cannot be satisfied by a legacy commit status" do
    contexts = [%{name: "ci", app_id: 42}]
    statuses = [%{"context" => "ci", "state" => "success", "target_url" => "impostor"}]

    assert {:ok, [%{name: "ci", state: :missing, link: nil}]} =
             GitHubReviewClient.match_required_contexts_for_test(
               contexts,
               %{"check_runs" => []},
               statuses
             )
  end

  test "unknown required-rule or check evidence fails closed" do
    assert {:error, _} = GitHubReviewClient.normalize_required_contexts_for_test(%{}, nil)
    assert {:error, _} = GitHubReviewClient.match_required_contexts_for_test([], %{})
  end

  test "review thread pagination merges every page before evaluation" do
    page = fn body, has_next_page, end_cursor ->
      %{
        "data" => %{
          "repository" => %{
            "pullRequest" => %{
              "body" => "",
              "reviewThreads" => %{
                "nodes" => [
                  %{
                    "id" => "thread-#{body}",
                    "isResolved" => false,
                    "comments" => %{
                      "nodes" => [
                        %{
                          "id" => "review-#{body}",
                          "body" => body,
                          "path" => "lib/example.ex",
                          "url" => "https://github.test/review/#{body}",
                          "commit" => %{"oid" => "head"},
                          "createdAt" => "2026-08-09T00:00:00Z",
                          "updatedAt" => "2026-08-09T00:00:00Z",
                          "author" => %{
                            "login" => "chatgpt-codex-connector",
                            "__typename" => "Organization",
                            "databaseId" => 261_883_814
                          }
                        }
                      ],
                      "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                    }
                  }
                ],
                "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
              }
            }
          }
        }
      }
    end

    assert {:ok, pull_request} =
             GitHubReviewClient.merge_pull_request_pages_for_test([
               page.("P4 first", true, "next"),
               page.("P1 second", false, nil)
             ])

    assert Enum.map(
             pull_request["reviewThreads"]["nodes"],
             &get_in(&1, ["comments", "nodes", Access.at(0), "body"])
           ) == ["P4 first", "P1 second"]
  end

  test "normalized review events retain exact comment identity and provider order" do
    head = String.duplicate("a", 40)

    pull_request = %{
      "body" => "## Scope Contract\n",
      "headRefOid" => head,
      "baseRefOid" => String.duplicate("b", 40),
      "reviews" => %{"nodes" => []},
      "reviewThreads" => %{
        "nodes" => [
          %{
            "id" => "thread-1",
            "isResolved" => false,
            "comments" => %{
              "nodes" => [
                review_event_comment("review-1", "P2 old", head, "2026-08-09T01:00:00Z", "Organization", 261_883_814),
                review_event_comment("review-2", "P1\r\nexact bytes", head, "2026-08-09T01:02:03Z", "Organization", 261_883_814)
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        ]
      }
    }

    snapshot =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [%{name: "make-all", state: :success}],
        %{required: false, result: :not_required},
        []
      )

    [event] = snapshot.review_events
    assert snapshot.pull_request_body == "## Scope Contract\n"
    assert event.review_thread_id == "thread-1"
    assert event.resolved? == false
    assert event.complete_pagination? == true
    assert Enum.map(event.comments, & &1.id) == ["review-1", "review-2"]
    assert Enum.map(event.comments, & &1.connection_index) == [0, 1]
    assert Enum.at(event.comments, 1).body == "P1\r\nexact bytes"
    assert Enum.at(event.comments, 1).updated_at == "2026-08-09T01:02:03Z"
    assert Enum.all?(event.comments, &(&1.trusted_review_source? == true))
  end

  test "missing thread comment pagination evidence blocks normalization" do
    page = %{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{
            "body" => "",
            "reviewThreads" => %{
              "nodes" => [
                %{
                  "id" => "thread-1",
                  "isResolved" => false,
                  "comments" => %{"nodes" => []}
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    }

    assert {:error, {:invalid_pull_request_page, ^page}} =
             GitHubReviewClient.merge_pull_request_pages_for_test([page])
  end

  test "review pages reject missing identity, malformed dates, and invalid authors" do
    valid = review_event_page()

    invalid_pages = [
      put_in(valid, ["data", "repository", "pullRequest", "reviewThreads", "nodes", Access.at(0), "id"], ""),
      put_in(
        valid,
        [
          "data",
          "repository",
          "pullRequest",
          "reviewThreads",
          "nodes",
          Access.at(0),
          "comments",
          "nodes",
          Access.at(0),
          "id"
        ],
        nil
      ),
      put_in(
        valid,
        [
          "data",
          "repository",
          "pullRequest",
          "reviewThreads",
          "nodes",
          Access.at(0),
          "comments",
          "nodes",
          Access.at(0),
          "author"
        ],
        "unsupported"
      ),
      put_in(
        valid,
        [
          "data",
          "repository",
          "pullRequest",
          "reviewThreads",
          "nodes",
          Access.at(0),
          "comments",
          "nodes",
          Access.at(0),
          "createdAt"
        ],
        "not-a-date"
      )
    ]

    for invalid <- invalid_pages do
      assert {:error, {:invalid_pull_request_page, ^invalid}} =
               GitHubReviewClient.merge_pull_request_pages_for_test([invalid])
    end
  end

  test "review pages preserve comments whose author is unavailable as untrusted evidence" do
    page =
      put_in(
        review_event_page(),
        [
          "data",
          "repository",
          "pullRequest",
          "reviewThreads",
          "nodes",
          Access.at(0),
          "comments",
          "nodes",
          Access.at(0),
          "author"
        ],
        nil
      )

    assert {:ok, pull_request} = GitHubReviewClient.merge_pull_request_pages_for_test([page])

    assert get_in(pull_request, ["reviewThreads", "nodes", Access.at(0), "comments", "nodes", Access.at(0), "author"]) ==
             nil

    snapshot =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [],
        %{required: false, result: :not_required},
        []
      )

    assert [%{comments: [%{trusted_review_source?: false}]}] = snapshot.review_events
  end

  test "normalized provider facts distinguish managed and system comments" do
    head = String.duplicate("e", 40)
    operation_id = String.duplicate("1", 64)

    pull_request = %{
      "headRefOid" => head,
      "reviewThreads" => %{
        "nodes" => [
          %{
            "id" => "thread-identity",
            "isResolved" => false,
            "comments" => %{
              "nodes" => [
                review_event_comment("system", "P2 system", head, "2026-08-09T01:00:00Z", "User", 123),
                review_event_comment(
                  "trusted-finding",
                  "P2 actionable finding",
                  head,
                  "2026-08-09T01:00:30Z",
                  "Bot",
                  199_175_422
                ),
                review_event_comment(
                  "managed",
                  transition_completed_body(operation_id, head)["body"],
                  head,
                  "2026-08-09T01:01:00Z",
                  "Bot",
                  199_175_422
                )
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        ]
      }
    }

    [event] =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [],
        %{required: false, result: :not_required},
        []
      ).review_events

    [system, trusted_finding, managed] = event.comments
    assert system.trusted_review_source? == false
    assert system.managed_agent_reply? == false
    assert trusted_finding.trusted_review_source? == true
    assert trusted_finding.managed_agent_reply? == false
    assert trusted_finding.settlement_marker? == false
    assert managed.trusted_review_source? == true
    assert managed.managed_agent_reply? == true
    assert managed.settlement_marker? == true
  end

  test "ordinary review prose mentioning transition operations is not a settlement marker" do
    head = String.duplicate("f", 40)

    pull_request = %{
      "headRefOid" => head,
      "reviewThreads" => %{
        "nodes" => [
          %{
            "id" => "thread-prose",
            "isResolved" => false,
            "comments" => %{
              "nodes" => [
                review_event_comment(
                  "review-prose",
                  "P2 review text discusses `transition-operation:` but is not a managed marker.",
                  head,
                  "2026-08-09T01:00:00Z",
                  "Organization",
                  261_883_814
                )
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        ]
      }
    }

    [event] =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [],
        %{required: false, result: :not_required},
        []
      ).review_events

    [comment] = event.comments
    assert comment.trusted_review_source? == true
    assert comment.managed_agent_reply? == false
    assert comment.settlement_marker? == false
  end

  test "quoted complete transition templates in review prose are not settlement markers" do
    head = String.duplicate("a", 40)
    quoted = transition_completed_body("example", head)["body"]

    pull_request = %{
      "headRefOid" => head,
      "reviewThreads" => %{
        "nodes" => [
          %{
            "id" => "thread-quoted-template",
            "isResolved" => false,
            "comments" => %{
              "nodes" => [
                review_event_comment(
                  "review-quoted-template",
                  "P2 diagnostic prose quoting an example:\n\n#{quoted}\nThis is not managed metadata.",
                  head,
                  "2026-08-09T01:00:00Z",
                  "Organization",
                  261_883_814
                )
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        ]
      }
    }

    [event] =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [],
        %{required: false, result: :not_required},
        []
      ).review_events

    [comment] = event.comments
    assert comment.trusted_review_source? == true
    assert comment.managed_agent_reply? == false
    assert comment.settlement_marker? == false
  end

  test "settlement markers require the generated template and matching operation identity" do
    head = String.duplicate("b", 40)
    completed_operation_id = String.duplicate("2", 64)
    intent_operation_id = String.duplicate("3", 64)
    other_completed_operation_id = String.duplicate("4", 64)
    other_intent_operation_id = String.duplicate("5", 64)
    completed = transition_completed_body(completed_operation_id, head)["body"]
    intent = transition_intent_body(intent_operation_id, head)["body"]

    comments = [
      review_event_comment("completed", completed, head, "2026-08-09T01:00:00Z", "Bot", 199_175_422),
      review_event_comment("intent", intent, head, "2026-08-09T01:01:00Z", "Bot", 199_175_422),
      review_event_comment(
        "completed-mismatch",
        String.replace(
          completed,
          "- dedup-key: `#{completed_operation_id}`",
          "- dedup-key: `#{other_completed_operation_id}`"
        ),
        head,
        "2026-08-09T01:02:00Z",
        "Organization",
        261_883_814
      ),
      review_event_comment(
        "intent-mismatch",
        String.replace(
          intent,
          "- dedup-key: `transition-intent:#{intent_operation_id}`",
          "- dedup-key: `transition-intent:#{other_intent_operation_id}`"
        ),
        head,
        "2026-08-09T01:03:00Z",
        "Organization",
        261_883_814
      )
    ]

    pull_request = %{
      "headRefOid" => head,
      "reviewThreads" => %{
        "nodes" => [
          %{
            "id" => "thread-marker-identity",
            "isResolved" => false,
            "comments" => %{
              "nodes" => comments,
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        ]
      }
    }

    [event] =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [],
        %{required: false, result: :not_required},
        []
      ).review_events

    assert Enum.map(event.comments, & &1.settlement_marker?) == [true, true, false, false]
  end

  test "settlement markers reject placeholder heads and operation identities" do
    head = String.duplicate("d", 40)

    comments = [
      review_event_comment(
        "completed-placeholder",
        transition_completed_body("P2-example", head)["body"]
        |> String.replace("- currentHeadSha: `#{head}`", "- currentHeadSha: `head`"),
        head,
        "2026-08-09T01:00:00Z",
        "Organization",
        261_883_814
      ),
      review_event_comment(
        "intent-placeholder",
        transition_intent_body("P2-example", head)["body"],
        head,
        "2026-08-09T01:01:00Z",
        "Organization",
        261_883_814
      )
    ]

    pull_request = %{
      "headRefOid" => head,
      "reviewThreads" => %{
        "nodes" => [
          %{
            "id" => "thread-marker-placeholder",
            "isResolved" => false,
            "comments" => %{
              "nodes" => comments,
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        ]
      }
    }

    [event] =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [],
        %{required: false, result: :not_required},
        []
      ).review_events

    assert Enum.map(event.comments, & &1.settlement_marker?) == [false, false]
  end

  test "resolved thread data is retained as a review event" do
    head = String.duplicate("c", 40)

    pull_request = %{
      "headRefOid" => head,
      "baseRefOid" => String.duplicate("d", 40),
      "reviews" => %{"nodes" => []},
      "reviewThreads" => %{
        "nodes" => [
          %{
            "id" => "thread-resolved",
            "isResolved" => true,
            "comments" => %{
              "nodes" => [
                review_event_comment(
                  "review-1",
                  "P1 resolved",
                  head,
                  "2026-08-09T01:00:00Z",
                  "Organization",
                  261_883_814
                )
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        ]
      }
    }

    snapshot =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [],
        %{required: false, result: :not_required},
        []
      )

    assert [%{review_thread_id: "thread-resolved", resolved?: true, comments: [_ | _]}] = snapshot.review_events
  end

  test "every paginated pull-request page must have valid data and pagination evidence" do
    valid = %{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{
            "body" => "",
            "reviewThreads" => %{
              "nodes" => [],
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => "next"}
            }
          }
        }
      }
    }

    for invalid <- [
          %{"errors" => [%{"message" => "rate limited"}]},
          %{"data" => %{"repository" => %{"pullRequest" => nil}}},
          %{"data" => %{"repository" => %{"pullRequest" => %{"reviewThreads" => %{}}}}},
          %{
            "data" => %{
              "repository" => %{
                "pullRequest" => %{
                  "reviewThreads" => %{
                    "nodes" => "not-a-list",
                    "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                  }
                }
              }
            }
          }
        ] do
      assert {:error, {:invalid_pull_request_page, ^invalid}} =
               GitHubReviewClient.merge_pull_request_pages_for_test([valid, invalid])
    end
  end

  test "base refs are encoded as one GitHub API path segment" do
    assert GitHubReviewClient.encode_path_segment_for_test("release/2026.07") ==
             "release%2F2026.07"

    assert GitHubReviewClient.encode_path_segment_for_test("release 100%/台灣") ==
             "release%20100%25%2F%E5%8F%B0%E7%81%A3"
  end

  test "pull-request pagination exposes both outer and nested cursors" do
    query = GitHubReviewClient.pull_request_query_for_test()

    assert length(Regex.scan(~r/pageInfo \{ hasNextPage endCursor \}/, query)) == 2
    assert query =~ "reviewThreads(first: 100, after: $endCursor)"
    assert query =~ "comments(first: 100)"
  end

  test "unresolved actionable threads remain blocking across head changes" do
    thread = fn commit, body ->
      %{
        "isResolved" => false,
        "comments" => %{
          "nodes" => [
            %{"body" => body, "path" => "lib/example.ex", "url" => "url", "commit" => %{"oid" => commit}}
          ]
        }
      }
    end

    assert [
             %{body: "P1 stale", commit_sha: "old"},
             %{body: "P2 current", commit_sha: "new"}
           ] =
             GitHubReviewClient.normalize_threads_for_test(
               [thread.("old", "P1 stale"), thread.("new", "P2 current")],
               "new"
             )
  end

  test "snapshot keeps unresolved actionable threads from prior heads" do
    pull_request = %{
      "headRefOid" => "new",
      "baseRefOid" => "base",
      "reviews" => %{"nodes" => []},
      "reviewThreads" => %{
        "nodes" => [
          %{
            "isResolved" => false,
            "comments" => %{
              "nodes" => [
                %{
                  "body" => "P1 unresolved on prior head",
                  "path" => "lib/example.ex",
                  "url" => "thread",
                  "commit" => %{"oid" => "old"}
                }
              ]
            }
          }
        ]
      }
    }

    snapshot =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [%{name: "make-all", state: :success}],
        %{required: false, result: :verified},
        []
      )

    assert [%{body: "P1 unresolved on prior head", commit_sha: "old"}] = snapshot.threads
  end

  test "a conflicting trusted formal review blocks comment-attestation fallback" do
    head = String.duplicate("d", 40)
    request = review_request_comment(head)
    clean_comment = clean_attestation_comment(head)

    pull_request = %{
      "headRefOid" => head,
      "baseRefOid" => "base",
      "reviewThreads" => %{"nodes" => []},
      "reviews" => %{
        "nodes" => [
          %{
            "commit" => %{"oid" => head},
            "state" => "CHANGES_REQUESTED",
            "body" => "P1 remains",
            "submittedAt" => "2026-07-22T01:10:00Z",
            "author" => %{
              "login" => "chatgpt-codex-connector[bot]",
              "__typename" => "Bot",
              "databaseId" => 199_175_422
            }
          }
        ]
      }
    }

    snapshot =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [%{name: "make-all", state: :success}],
        %{required: false, result: :verified},
        [request, clean_comment]
      )

    assert snapshot.reviewed_head_sha == nil
    assert snapshot.review_result == :missing
  end

  test "a current-head follow-up on an older thread remains actionable" do
    thread = %{
      "isResolved" => false,
      "comments" => %{
        "nodes" => [
          %{"body" => "P4 old", "commit" => %{"oid" => "old"}},
          %{"body" => "P1 current follow-up", "path" => "lib/current.ex", "url" => "thread", "commit" => %{"oid" => "head"}}
        ]
      }
    }

    assert [%{body: "P1 current follow-up", priority: 1, commit_sha: "head"}] =
             GitHubReviewClient.normalize_threads_for_test([thread], "head")
  end

  test "old-head base-missing claims do not contaminate current-head follow-ups" do
    thread = %{
      "comments" => %{
        "nodes" => [
          %{
            "body" => "The base branch is missing `lib/old.ex`",
            "commit" => %{"oid" => "old"}
          },
          %{"body" => "Current-head follow-up", "commit" => %{"oid" => "head"}}
        ]
      }
    }

    assert GitHubReviewClient.base_missing_paths_for_test([thread], "head") == []

    current = put_in(thread, ["comments", "nodes", Access.at(1), "body"], "Base ref is missing `lib/current.ex`")
    assert GitHubReviewClient.base_missing_paths_for_test([current], "head") == ["lib/current.ex"]
  end

  test "structural risk only uses unresolved current-head comments" do
    thread = fn resolved, commit, body ->
      %{
        "isResolved" => resolved,
        "comments" => %{"nodes" => [%{"body" => body, "commit" => %{"oid" => commit}}]}
      }
    end

    refute GitHubReviewClient.structural_risk_for_test?(
             [
               thread.(false, "old", "P2 spec conflict"),
               thread.(true, "head", "P2 scope keeps expanding")
             ],
             "head"
           )

    assert GitHubReviewClient.structural_risk_for_test?(
             [thread.(false, "head", "P2 one-off patch")],
             "head"
           )
  end

  test "review thread comments are merged across every comment page" do
    page = fn body ->
      %{
        "data" => %{
          "node" => %{
            "comments" => %{
              "nodes" => [
                %{
                  "id" => "review-#{body}",
                  "body" => body,
                  "path" => "lib/example.ex",
                  "url" => "https://github.test/review/#{body}",
                  "commit" => %{"oid" => "head"},
                  "createdAt" => "2026-08-09T00:00:00Z",
                  "updatedAt" => "2026-08-09T00:00:00Z",
                  "author" => %{
                    "login" => "chatgpt-codex-connector",
                    "__typename" => "Organization",
                    "databaseId" => 261_883_814
                  }
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    end

    assert {:ok, [%{"body" => "old"}, %{"body" => "current P1"}]} =
             GitHubReviewClient.merge_thread_comment_pages_for_test([
               page.("old"),
               page.("current P1")
             ])
  end

  test "a new head invalidates an old formal review and requests one deduplicated review" do
    snapshot = snapshot(%{current_head_sha: "new", reviewed_head_sha: "old"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, "aroakpm-svg/repo", "new", :pending, _}
    assert_receive {:review_requested, "aroakpm-svg/repo", 42, key}
    assert is_binary(key)

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "a persisted review-request key prevents a duplicate after monitor restart" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{reviewed_head_sha: nil})})
    digest = ReviewConvergence.dedup_key(:review_request, "issue-160", "head", :codex)
    key = "review-request:issue-160:head:#{digest}"
    Application.put_env(:symphony_elixir, :existing_review_keys, [key])

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:review_requested, _, _, _}
    assert_receive {:status, _, "head", :pending, _}
  end

  defmodule HistoryClient do
    @spec graphql(String.t(), map()) :: {:ok, map()}
    def graphql(_query, variables) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:history_page, variables.after})
      [response | rest] = Process.get(:history_responses)
      Process.put(:history_responses, rest)
      {:ok, response}
    end
  end

  test "review monitor ignores review-state issues outside tracker routing" do
    unroutable = %{issue() | id: "other", assigned_to_worker: false}
    Application.put_env(:symphony_elixir, :review_issues, [unroutable])
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{reviewed_head_sha: nil})})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:review_requested, _, _, _}
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
  end

  test "review monitor prunes entries for issues that left the review state" do
    Application.put_env(:symphony_elixir, :review_issues, [])

    stale_state = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: "old-head",
        fetch_failed: false
      }
    }

    assert ReviewMonitor.run_with(stale_state, settings(), ReviewClient, Tracker) == %{}
    refute_receive {:status, _, _, _, _}
  end

  test "Linear rework history paginates and counts stable keys once" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)

    Process.put(:history_responses, [
      history_page([rework_body("one")], true, "next"),
      history_page([rework_body("one"), rework_body("two"), converged_body(String.duplicate("b", 40))], false, nil)
    ])

    assert {:ok, %{dedup: dedup, rework_count: 2, last_head_sha: last_head_sha}} =
             Adapter.review_history("issue-160")

    assert dedup == MapSet.new(["one", "two", "converged"])
    assert last_head_sha == String.duplicate("b", 40)
    assert_receive {:history_page, nil}
    assert_receive {:history_page, "next"}
  end

  test "Linear history exposes only incomplete durable transition intents" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)
    head = String.duplicate("c", 40)

    Process.put(:history_responses, [
      history_page(
        [
          transition_intent_body("pending", head),
          transition_intent_body("completed", head),
          transition_completed_body("completed", head)
        ],
        false,
        nil
      )
    ])

    assert {:ok, %{pending_transitions: pending, rework_count: 1}} =
             Adapter.review_history("issue-160")

    assert pending == %{
             "pending" => %{
               operation_id: "pending",
               head_sha: head,
               target_state: "In Progress"
             }
           }
  end

  test "malformed or contradictory transition history fails closed" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)

    Process.put(:history_responses, [
      history_page(
        [
          %{
            "body" => "transition-operation: `intent`\ntransition-operation-id: `broken`\ndedup-key: `transition-intent:broken`"
          }
        ],
        false,
        nil
      )
    ])

    assert {:error, :invalid_review_transition_history} = Adapter.review_history("issue-160")
  end

  test "completion markers must match their durable transition intent" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)
    intent_head = String.duplicate("d", 40)
    conflicting_head = String.duplicate("e", 40)

    Process.put(:history_responses, [
      history_page(
        [
          transition_intent_body("conflict", intent_head),
          transition_completed_body("conflict", conflicting_head)
        ],
        false,
        nil
      )
    ])

    assert {:error, :invalid_review_transition_history} = Adapter.review_history("issue-160")

    Process.put(:history_responses, [
      history_page(
        [
          transition_intent_body("bad-dedup", intent_head),
          %{
            transition_completed_body("bad-dedup", intent_head)
            | "body" =>
                String.replace(
                  transition_completed_body("bad-dedup", intent_head)["body"],
                  "dedup-key: `bad-dedup`",
                  "dedup-key: `reused-other-key`"
                )
          }
        ],
        false,
        nil
      )
    ])

    assert {:error, :invalid_review_transition_history} = Adapter.review_history("issue-160")
  end

  test "structured snapshot errors fail closed without crashing comment rendering" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, {:command_failed, 8, %{state: :pending}}})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", body}
    assert body =~ "command_failed"
  end

  test "persisted wait key prevents duplicate evidence-outage effects after restart" do
    reason = inspect(:github_unavailable)
    key = ReviewConvergence.dedup_key(:wait, "issue-160", nil, reason)

    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})
    Application.put_env(:symphony_elixir, :review_history, {:ok, %{dedup: MapSet.new([key]), rework_count: 0}})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:comment, _, _}
  end

  test "evidence outage clears a known head's prior success with an error status" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: "known-head",
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "known-head", :error, _}
    assert_receive {:comment, "issue-160", _}
  end

  test "restart restores persisted head before snapshot outage clears success" do
    persisted_head = String.duplicate("a", 40)
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, %{dedup: MapSet.new(), rework_count: 0, last_head_sha: persisted_head}}
    )

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, ^persisted_head, :error, _}
  end

  test "review-issue fetch outage clears each known head once until recovery" do
    entry = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: "head",
        last_published_status: {"head", :success},
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    state = ReviewMonitor.run_with(entry, settings(), ReviewClient, FailingIssueTracker)
    assert_receive {:status, _, "head", :error, _}

    state = ReviewMonitor.run_with(state, settings(), ReviewClient, FailingIssueTracker)
    refute_receive {:status, _, _, _, _}

    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})
    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :success, _}
  end

  test "convergence republishes success after a transient error while keeping its comment deduplicated" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})
    key = ReviewConvergence.dedup_key(:converged, "issue-160", "head", :technical)

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new([key]),
        fix_rounds: 0,
        head_sha: "head",
        review_requested: false,
        waiting: true,
        last_finding_fingerprint: nil
      }
    }

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :success, _}
    refute_receive {:comment, _, _}
  end

  test "steady convergence does not republish the same head status every poll" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :success, _}

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, "head", :success, _}
  end

  test "previously deduplicated wait still replaces a later success when evidence regresses" do
    wait_key = ReviewConvergence.dedup_key(:wait, "issue-160", "head", :required_checks_not_passed)

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new([wait_key]),
        fix_rounds: 0,
        head_sha: "head",
        last_published_status: {"head", :success},
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{required_checks: [%{name: "make-all", state: :pending}]})}
    )

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :pending, _}
    refute_receive {:comment, _, _}
  end

  test "review, required checks, and actionable threads are independent gates" do
    assert {:converged, _} = ReviewConvergence.evaluate(snapshot(), 0, 3)

    assert {:request_review, _} =
             snapshot(%{reviewed_head_sha: "old"}) |> ReviewConvergence.evaluate(0, 3)

    assert {:wait, %{reason: :required_checks_not_passed}} =
             snapshot(%{required_checks: [%{name: "test", state: :pending}]})
             |> ReviewConvergence.evaluate(0, 3)

    assert {:rework, %{actionable_threads: [_]}} =
             snapshot(%{threads: [%{resolved: false, priority: 2, body: "P2", url: "url"}]})
             |> ReviewConvergence.evaluate(0, 3)
  end

  test "an explicit human wait reason is preserved in the decision evidence" do
    assert {:wait, %{reason: :staging}} =
             snapshot(%{waiting_reason: :staging}) |> ReviewConvergence.evaluate(0, 3)
  end

  test "missing current head fails closed and malformed threads are not actionable" do
    assert {:wait, %{reason: :missing_current_head}} =
             snapshot(%{current_head_sha: nil, threads: [:malformed]})
             |> ReviewConvergence.evaluate(0, 3)

    refute ReviewConvergence.actionable_thread?(:malformed)
  end

  test "structural risk escalates actionable findings before the retry limit" do
    assert {:escalate, %{reason: :review_not_converging}} =
             snapshot(%{
               structural_risk: true,
               threads: [%{resolved: false, priority: 4, body: "P4 architectural expansion"}]
             })
             |> ReviewConvergence.evaluate(0, 3)
  end

  test "an unverified remote base claim fails closed" do
    result =
      snapshot(%{base_verification_required: true, base_verification: :unverified})
      |> ReviewConvergence.evaluate(0, 3)

    assert {:wait, %{reason: :base_unverified, base_ref_oid: "base"}} = result
  end

  test "base-missing claims verify absence rather than presence" do
    base_paths = MapSet.new(["lib/present.ex", "README.md"])

    assert GitHubReviewClient.missing_paths_verified_for_test?(base_paths, ["lib/missing.ex"])
    refute GitHubReviewClient.missing_paths_verified_for_test?(base_paths, ["lib/present.ex"])
  end

  test "base verification resolves a commit payload to its tree oid" do
    assert GitHubReviewClient.base_tree_oid_for_test(%{"tree" => %{"sha" => "tree-sha"}}) ==
             {:ok, "tree-sha"}

    assert {:error, {:missing_base_tree_oid, _}} =
             GitHubReviewClient.base_tree_oid_for_test(%{"sha" => "commit-sha"})
  end

  test "actionable findings comment and return the issue for repair once per head and finding" do
    finding = %{resolved: false, priority: 1, body: "P1 data loss", url: "https://example.test/thread"}
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :failure, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "P1"
    assert_receive {:comment, "issue-160", intent_body}
    assert intent_body =~ "transition-operation: `intent`"
    assert_receive {:state, "issue-160", "In Progress"}
    assert_receive {:comment, "issue-160", transition_body}
    assert transition_body =~ "returned this issue to In Progress"
    assert transition_body =~ "transition-operation: `completed`"

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
  end

  test "persisted rework key prevents duplicate tracker effects after restart" do
    finding = %{resolved: false, priority: 1, body: "P1 data loss", url: "https://example.test/thread"}
    fingerprint = [{1, nil, "P1 data loss"}]
    key = ReviewConvergence.dedup_key(:rework, "issue-160", "head", fingerprint)
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    transition_key = ReviewConvergence.dedup_key(:state_transition, "issue-160", "head", fingerprint)

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, %{dedup: MapSet.new([key, transition_key]), rework_count: 1}}
    )

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :failure, _}
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
  end

  test "state transition retries after the rework comment already persisted" do
    finding = %{resolved: false, priority: 1, body: "P1 state retry", url: "thread"}
    fingerprint = [{1, nil, "P1 state retry"}]
    key = ReviewConvergence.dedup_key(:rework, "issue-160", "head", fingerprint)
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})
    Application.put_env(:symphony_elixir, :review_state_result, {:error, :linear_unavailable})

    first_state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", rework_body}
    assert rework_body =~ "actionable latest-head findings"
    assert_receive {:comment, "issue-160", intent_body}
    assert intent_body =~ "transition-operation: `intent`"
    assert_receive {:state, "issue-160", "In Progress"}
    assert first_state["issue-160"].fix_rounds == 0

    transition_key = ReviewConvergence.dedup_key(:state_transition, "issue-160", "head", fingerprint)
    intent_key = "transition-intent:#{transition_key}"

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, %{dedup: MapSet.new([key, intent_key]), rework_count: 0}}
    )

    Application.put_env(:symphony_elixir, :review_state_result, :ok)

    second_state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:state, "issue-160", "In Progress"}
    assert_receive {:comment, "issue-160", transition_body}
    assert transition_body =~ "returned this issue to In Progress"
    assert second_state["issue-160"].fix_rounds == 1

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, %{dedup: MapSet.new([key, transition_key]), rework_count: 1}}
    )

    restarted = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
    assert restarted["issue-160"].fix_rounds == 1
  end

  test "state transition completion requires authoritative target-state readback" do
    finding = %{resolved: false, priority: 1, body: "P1 state race", url: "thread"}
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})
    Application.put_env(:symphony_elixir, :verified_issue_state, "In Review")

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:comment, "issue-160", _rework}
    assert_receive {:comment, "issue-160", intent}
    assert intent =~ "transition-operation: `intent`"
    assert_receive {:state, "issue-160", "In Progress"}
    refute_receive {:comment, "issue-160", _completion}
    assert state["issue-160"].fix_rounds == 0
  end

  test "pending transition completes after restart even after the issue left review" do
    operation_id = "durable-operation"

    Application.put_env(:symphony_elixir, :review_issues, [
      %{issue() | state: "In Progress"}
    ])

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       %{
         dedup: MapSet.new(["transition-intent:#{operation_id}"]),
         rework_count: 0,
         pending_transitions: %{
           operation_id => %{
             operation_id: operation_id,
             head_sha: String.duplicate("a", 40),
             target_state: "In Progress"
           }
         }
       }}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:comment, "issue-160", completion}
    assert completion =~ "transition-operation: `completed`"
    assert completion =~ "transition-operation-id: `#{operation_id}`"
    refute_receive {:state, _, _}
    refute_receive {:status, _, _, _, _}
    assert state["issue-160"].fix_rounds == 1
  end

  test "pending transition retries the state move before recording completion" do
    operation_id = "retry-operation"

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       %{
         dedup: MapSet.new(["transition-intent:#{operation_id}"]),
         rework_count: 0,
         pending_transitions: %{
           operation_id => %{
             operation_id: operation_id,
             head_sha: String.duplicate("b", 40),
             target_state: "In Progress"
           }
         }
       }}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:state, "issue-160", "In Progress"}
    assert_receive {:comment, "issue-160", completion}
    assert completion =~ "transition-operation: `completed`"
    assert state["issue-160"].fix_rounds == 1
  end

  test "stale pending history does not recount an already deduplicated completion" do
    operation_id = "already-completed-operation"

    Application.put_env(:symphony_elixir, :review_issues, [
      %{issue() | state: "In Progress"}
    ])

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       %{
         dedup: MapSet.new(["transition-intent:#{operation_id}", operation_id]),
         rework_count: 1,
         pending_transitions: %{
           operation_id => %{
             operation_id: operation_id,
             head_sha: String.duplicate("c", 40),
             target_state: "In Progress"
           }
         }
       }}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
    assert state["issue-160"].fix_rounds == 1
  end

  test "ordinary In Progress issue ignores review-history outages" do
    Application.put_env(:symphony_elixir, :review_issues, [
      %{issue() | state: "In Progress"}
    ])

    Application.put_env(:symphony_elixir, :review_history, {:error, :linear_unavailable})

    assert ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker) == %{}
    refute_receive {:comment, _, _}
    refute_receive {:status, _, _, _, _}
    refute_receive {:state, _, _}
  end

  test "known pending transition still fails closed on a history outage" do
    Application.put_env(:symphony_elixir, :review_issues, [
      %{issue() | state: "In Progress"}
    ])

    Application.put_env(:symphony_elixir, :review_history, {:error, :linear_unavailable})
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})

    state = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: "head",
        fetch_failed: false,
        waiting: false,
        review_requested: false,
        last_finding_fingerprint: nil,
        pending_transitions: %{"operation" => %{target_state: "In Progress"}}
      }
    }

    result = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :error, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "linear_unavailable"
    assert result["issue-160"].waiting
  end

  test "waiting on environment or human judgment neither rereviews nor changes state" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{waiting_reason: :staging, reviewed_head_sha: nil, review_result: :missing})}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :pending, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "waiting for team human judgment"
    assert body =~ "staging"
    refute_receive {:review_requested, _, _, _}
    refute_receive {:state, _, _}

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:comment, _, _}
  end

  test "persistent actionable findings escalate instead of scheduling another repair" do
    finding = %{resolved: false, priority: 3, body: "P3 recurring patch", url: "thread"}
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 3,
        head_sha: "head",
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :failure, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "review_not_converging"
    refute_receive {:state, _, _}
  end

  test "persisted rework rounds survive restart and force human escalation" do
    finding = %{resolved: false, priority: 2, body: "P2 recurring patch", url: "thread"}
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})
    Application.put_env(:symphony_elixir, :review_history, {:ok, %{dedup: MapSet.new(), rework_count: 3}})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", body}
    assert body =~ "review_not_converging"
    refute_receive {:state, _, _}
  end

  test "unverifiable persisted rework history fails closed" do
    Application.put_env(:symphony_elixir, :review_history, {:error, :linear_unavailable})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "head", :error, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "linear_unavailable"
    refute_receive {:state, _, _}
  end

  defp settings do
    %{
      repository: "aroakpm-svg/repo",
      review_state: "In Review",
      in_progress_state: "In Progress",
      max_fix_rounds: 3,
      human_owner: "owner"
    }
  end

  defp review_request_comment(head) do
    %{
      "body" => "@codex review\n\ndedup-key: `aro-160-review-#{head}`",
      "created_at" => "2026-07-22T01:00:00Z"
    }
  end

  defp review_event_comment(id, body, commit_sha, timestamp, author_type, author_id) do
    login = if author_type == "Bot", do: "chatgpt-codex-connector[bot]", else: "chatgpt-codex-connector"

    %{
      "id" => id,
      "body" => body,
      "path" => "lib/example.ex",
      "url" => "https://github.test/review/#{id}",
      "commit" => %{"oid" => commit_sha},
      "createdAt" => timestamp,
      "updatedAt" => timestamp,
      "author" => %{
        "login" => login,
        "__typename" => author_type,
        "databaseId" => author_id
      }
    }
  end

  defp review_event_page(comment_overrides \\ %{}) do
    comment =
      Map.merge(
        review_event_comment(
          "review-1",
          "P1 issue",
          String.duplicate("a", 40),
          "2026-08-09T01:00:00Z",
          "Organization",
          261_883_814
        ),
        comment_overrides
      )

    %{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{
            "body" => "",
            "reviewThreads" => %{
              "nodes" => [
                %{
                  "id" => "thread-1",
                  "isResolved" => false,
                  "comments" => %{
                    "nodes" => [comment],
                    "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                  }
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    }
  end

  defp clean_attestation_comment(reviewed_prefix) do
    %{
      "body" => "Codex Review: Didn't find any major issues. Another round soon, please!\n\n**Reviewed commit:** `#{reviewed_prefix}`",
      "created_at" => "2026-07-22T01:05:00Z",
      "user" => %{
        "login" => "chatgpt-codex-connector[bot]",
        "type" => "Bot",
        "id" => 199_175_422
      },
      "performed_via_github_app" => %{
        "slug" => "chatgpt-codex-connector",
        "id" => 1_144_995
      }
    }
  end

  defp issue do
    %Issue{
      id: "issue-160",
      identifier: "ARO-160",
      title: "Review convergence",
      state: "In Review",
      branch_name: "codex/aro-160",
      url: "https://linear.test/ARO-160",
      labels: ["owned"]
    }
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        repository: "aroakpm-svg/repo",
        pull_request_number: 42,
        current_head_sha: "head",
        reviewed_head_sha: "head",
        review_result: :no_major_issues,
        base_ref_oid: "base",
        base_verification_required: false,
        base_verification: :not_required,
        required_checks: [%{name: "test", state: :success}],
        threads: [],
        waiting_reason: nil
      },
      overrides
    )
  end

  defp design3_receipt(finding_key, lineage_key, head) do
    %{
      verified?: true,
      valid?: true,
      readback_capable?: true,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      causal_attempt_fingerprint: String.duplicate("c", 64),
      causal_evidence_digest: String.duplicate("d", 64),
      invariant: "managed writes are exactly once",
      causal_hypothesis: "the earliest authorization boundary accepted stale evidence",
      earliest_incorrect_boundary: "PatchAuthorization exact-head guard",
      boundary_group: "managed-effect-identity",
      causal_progress_reference: "regression:design3:1",
      receipt_provenance: "review-thread:thread-design-3",
      recurrence_count: 1,
      evaluated_head_sha: head,
      authorized_head_sha: head,
      mutation_intent_reference: "bounded-intent:thread-design-3",
      pre_mutation_regression: %{
        phase: :pre_mutation,
        status: :fail,
        command_or_source: "mix test test/symphony_elixir/patch_authorization_test.exs",
        observed_output: "authorization owner was unavailable",
        head_sha: head
      }
    }
  end

  defp rework_body(key) do
    %{"body" => "Review Convergence Gate returned this issue to In Progress for latest-head repair.\n\ndedup-key: `#{key}`"}
  end

  defp transition_intent_body(operation_id, head_sha) do
    %{
      "body" => """
      Review Convergence Gate recorded a durable rework transition intent.

      - currentHeadSha: `#{head_sha}`
      - target-state: `In Progress`
      - transition-operation: `intent`
      - transition-operation-id: `#{operation_id}`
      - dedup-key: `transition-intent:#{operation_id}`

      This operation is safe to resume after timeout or process restart; completion is recorded separately.
      """
    }
  end

  defp transition_completed_body(operation_id, head_sha) do
    %{
      "body" => """
      Review Convergence Gate returned this issue to In Progress for latest-head repair.

      - currentHeadSha: `#{head_sha}`
      - transition-operation: `completed`
      - transition-operation-id: `#{operation_id}`
      - dedup-key: `#{operation_id}`
      """
    }
  end

  defp converged_body(head_sha) do
    %{
      "body" => "Review Convergence Gate reports technical convergence.\ncurrentHeadSha = reviewedHeadSha = `#{head_sha}`\ndedup-key: `converged`"
    }
  end

  defp history_page(nodes, has_next, cursor) do
    %{
      "data" => %{
        "issue" => %{
          "comments" => %{
            "nodes" => nodes,
            "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}
          }
        }
      }
    }
  end

  defp prepare_unloaded_module(module, body) do
    source = "defmodule #{inspect(module)} do\n#{body}\nend\n"
    [{^module, binary}] = Code.compile_string(source, "runtime_module_fixture.exs")
    directory = Path.join(System.tmp_dir!(), "symphony-review-monitor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    beam_path = Path.join(directory, Atom.to_string(module) <> ".beam")
    File.write!(beam_path, binary)
    :code.add_patha(String.to_charlist(directory))
    :code.purge(module)
    :code.delete(module)
    module
  end
end
