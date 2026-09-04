defmodule SymphonyElixir.AgentRunnerRollbackReportingTest do
  use SymphonyElixir.TestSupport

  for cleanup_fails? <- [false, true] do
    @tag cleanup_fails?: cleanup_fails?
    test "post-claim transient failure reports completed private-home rollback, failure=#{cleanup_fails?}", %{cleanup_fails?: cleanup_fails?} do
      root = Path.join(System.tmp_dir!(), "rollback-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

      profile = %{
        key: "central-brain",
        linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
        repository: "aroakpm-svg/aroak-central-brain",
        canonical_branch: "main",
        workspace_namespace: "central-brain",
        credential_ref: "github-central-brain",
        environment: "local_non_production"
      }

      issue = %Issue{
        id: "rollback-issue",
        identifier: "ARO-196-ROLLBACK",
        title: "Rollback reporting",
        state: "In Progress",
        branch_name: "codex/rollback",
        project_id: profile.linear_project_id,
        project_profile: profile,
        repository: profile.repository,
        routing_revision: 1,
        readiness_base: :canonical,
        labels: []
      }

      secret = "synthetic-rollback-secret"

      request = fn request ->
        body =
          case request[:url] do
            "https://api.github.com/installation/repositories?per_page=2" -> %{"total_count" => 1, "repositories" => [%{"full_name" => profile.repository}]}
            "https://api.github.com/graphql" -> %{"data" => %{"viewer" => %{"login" => "aroak-automation[bot]"}}}
            "https://api.github.com/repos/aroakpm-svg/aroak-central-brain" -> %{"full_name" => profile.repository, "default_branch" => "main", "permissions" => %{"pull" => true, "push" => true}}
            "https://api.github.com/repos/aroakpm-svg/aroak-central-brain/git/ref/heads/main" -> %{"ref" => "refs/heads/main", "object" => %{"sha" => String.duplicate("a", 40)}}
          end

        {:ok, %{status: 200, body: body}}
      end

      runner = fn args, _credential, runtime ->
        capability = runtime[:private_home_capability]
        Process.put(:rollback_capability, capability)

        if "fetch" in args do
          if cleanup_fails? do
            home = capability.identities |> Map.keys() |> Enum.max_by(&String.length/1)
            foreign_file = Path.join(home, "foreign-file")
            File.write!(foreign_file, secret)
            Process.put(:rollback_foreign_file, foreign_file)
          end

          {:error, {:git_command_failed, "git fetch", 128, "connection reset #{secret}"}}
        else
          {:ok, ""}
        end
      end

      assert :ok =
               AgentRunner.run(issue, self(),
                 credential_source: fn ref -> {:ok, %{credential_ref: ref, token: secret, expires_at: nil}} end,
                 expected_actor: "aroak-automation[bot]",
                 request_fun: request,
                 repository_bootstrap_command_runner: runner,
                 codex_session_starter: fn _, _ -> flunk("Codex started") end
               )

      assert_receive {:agent_hard_blocker, _, blocker}
      expected = if cleanup_fails?, do: :subprocess_home_rollback_failed, else: :repository_bootstrap_unavailable
      assert blocker.kind == {:project_credential_unavailable, expected}
      refute_received {:agent_hard_blocker, _, _}
      assert :atomics.get(Process.get(:rollback_capability).lifecycle, 1) == 1
      refute File.exists?(Path.join([root, "central-brain", issue.identifier]))

      state = %Orchestrator.State{
        running: %{issue.id => %{pid: self(), ref: nil, identifier: issue.identifier, issue: issue, worker_host: nil, started_at: DateTime.utc_now(), retry_attempt: 0, distributed_claim: nil}},
        claimed: MapSet.new([issue.id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      {:noreply, state} = Orchestrator.handle_info({:agent_hard_blocker, issue.id, blocker}, state)
      assert state.running == %{}
      refute :erlang.term_to_binary(state) =~ secret

      if cleanup_fails? do
        assert state.blocked[issue.id].error =~ "subprocess_home_rollback_failed"
        refute Map.has_key?(state.retry_attempts, issue.id)
        assert File.read!(Process.get(:rollback_foreign_file)) == secret
      else
        assert state.blocked == %{}
        assert state.retry_attempts[issue.id].ownership == :unowned_backoff
        Process.cancel_timer(state.retry_attempts[issue.id].timer_ref)
        for path <- Map.keys(Process.get(:rollback_capability).identities), do: refute(File.exists?(path))
      end
    end
  end
end
