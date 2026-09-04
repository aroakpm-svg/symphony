defmodule SymphonyElixir.ProjectRepoPreflightTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require Logger

  alias SymphonyElixir.ProjectRepoPreflight

  @actor "aroak-symphony[bot]"
  @head_sha "0123456789abcdef0123456789abcdef01234567"
  @token "preclaim-token-must-not-escape"
  @profile %{
    key: "project-management",
    linear_project_id: "708053e0-f42c-4e93-bec4-7abbb37e74af",
    repository: "aroakpm-svg/aroak-project-management",
    canonical_branch: "main",
    workspace_namespace: "project-management",
    credential_ref: "github-project-management",
    environment: "local_non_production"
  }
  @central_profile %{
    key: "central-brain",
    linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
    repository: "aroakpm-svg/aroak-central-brain",
    canonical_branch: "main",
    workspace_namespace: "central-brain",
    credential_ref: "github-central-brain",
    environment: "local_non_production"
  }

  test "resolves before GitHub requests and returns only secret-free authority evidence" do
    parent = self()

    source = fn ref ->
      send(parent, {:event, :resolved, ref})
      credential(ref)
    end

    assert {:ok, receipt} =
             ProjectRepoPreflight.check(@profile,
               credential_source: source,
               expected_actor: @actor,
               request_fun: request_fun(parent),
               command_runner: fn _, _ -> flunk("ambient gh must never run") end
             )

    assert_receive {:event, :resolved, "github-project-management"}
    assert_receive {:event, :requested, "https://api.github.com/graphql"}

    assert receipt == %{
             actor: @actor,
             default_branch: "main",
             head_sha: @head_sha,
             project: "project-management",
             pull?: true,
             push?: true,
             repository: "aroakpm-svg/aroak-project-management",
             required_scripts: ["typecheck", "build", "db:test"]
           }

    refute inspect(receipt) =~ @token
  end

  test "reads package.json at the verified immutable head with the same credential" do
    assert {:ok, _receipt} = ProjectRepoPreflight.check(@profile, valid_options(self()))

    assert_receive {:package_request, request_evidence}
    assert request_evidence.url =~ "/contents/package.json?ref=#{@head_sha}"
    assert request_evidence.authorized?
    assert request_evidence.redirect == false
    refute inspect(request_evidence) =~ @token
  end

  test "preserves the central-brain quality contract" do
    options =
      valid_options(self(),
        profile: @central_profile,
        package_body: %{
          "scripts" => %{"typecheck" => "tsc", "build" => "build", "test" => "test"}
        }
      )

    assert {:ok, %{required_scripts: ["typecheck", "build", "test"]}} =
             ProjectRepoPreflight.check(@central_profile, options)
  end

  test "maps resolver and authority failures to exact stable blocker codes" do
    cases = [
      {:credential_source_unconfigured, []},
      {:credential_source_missing, [credential_source: fn _ -> {:error, :missing} end]},
      {:credential_source_conflict, [credential_source: fn _ -> {:error, {:conflict, @token}} end]},
      {:credential_expired, [credential_source: fn ref -> credential(ref, DateTime.add(DateTime.utc_now(), -60)) end]},
      {:github_unexpected_actor, valid_options(self(), actor: "human")},
      {:github_pull_authority_missing, valid_options(self(), pull?: false)},
      {:github_push_authority_missing, valid_options(self(), push?: false)},
      {:github_unauthorized, valid_options(self(), status: 401)},
      {:github_forbidden, valid_options(self(), status: 403)}
    ]

    for {code, options} <- cases do
      assert {:blocked, %{code: ^code, detail: nil, next_step: next_step}} =
               ProjectRepoPreflight.check(@profile, options)

      assert is_binary(next_step) and next_step != ""
    end
  end

  test "keeps every remaining public resolver and authority failure mapping secret-safe" do
    sentinel = "credential-mapping-secret-sentinel"

    cases = [
      {:credential_reference_mismatch,
       [
         credential_source: fn _ref ->
           {:ok,
            %{
              credential_ref: "github-central-brain",
              token: sentinel,
              expires_at: nil
            }}
         end
       ]},
      {:credential_resolver_failed, [credential_source: fn _ref -> raise "resolver failed with #{sentinel}" end]},
      {:github_repository_not_allowed,
       [profile: %{@profile | linear_project_id: "not-approved"}] ++
         valid_options(self(), profile: %{@profile | linear_project_id: "not-approved"})},
      {:github_response_invalid,
       [
         credential_source: fn ref -> credential(ref) end,
         expected_actor: @actor,
         request_fun: fn _request ->
           {:ok, %{status: 200, body: %{"unexpected" => sentinel}}}
         end
       ]},
      {:github_authority_invalid,
       [
         credential_source: fn ref -> credential(ref) end,
         request_fun: request_fun(self())
       ]}
    ]

    for {code, options} <- cases do
      profile = Keyword.get(options, :profile, @profile)
      options = Keyword.delete(options, :profile)

      log =
        capture_log(fn ->
          result = ProjectRepoPreflight.check(profile, options)
          Logger.error("preflight=#{inspect(result)}")
          send(self(), {:mapped_failure, code, result})
        end)

      assert_receive {:mapped_failure, ^code, {:blocked, %{code: ^code, detail: nil, next_step: next_step}} = result}

      assert is_binary(next_step) and next_step != ""
      refute inspect(result) =~ sentinel
      refute inspect(result) =~ @token
      refute log =~ sentinel
      refute log =~ @token
    end
  end

  test "quality failures stay bounded and secret-safe" do
    options =
      valid_options(self(), package_body: %{"scripts" => %{"typecheck" => "tsc"}})

    log =
      capture_log(fn ->
        result = ProjectRepoPreflight.check(@profile, options)
        Logger.error("preflight=#{inspect(result)}")
        send(self(), {:result, result})
      end)

    assert_receive {:result, {:blocked, %{code: :required_check_contract_missing, detail: ["build", "db:test"]}} = result}

    refute inspect(result) =~ @token
    refute log =~ @token
  end

  test "malformed or unavailable package responses map to bounded quality blockers" do
    assert {:blocked, %{code: :required_check_contract_invalid}} =
             ProjectRepoPreflight.check(@profile, valid_options(self(), package_body: %{"scripts" => []}))

    assert {:blocked, %{code: :required_check_contract_unreadable}} =
             ProjectRepoPreflight.check(@profile, valid_options(self(), package_status: 404))

    assert {:blocked, %{code: :github_unavailable}} =
             ProjectRepoPreflight.check(@profile, valid_options(self(), package_status: 500))
  end

  test "drops secret-bearing package request exceptions before returning or logging" do
    base_request = request_fun(self())

    request_fun = fn request ->
      if Keyword.fetch!(request, :url) =~ "/contents/package.json" do
        raise "#{@token}: raw request failure"
      else
        base_request.(request)
      end
    end

    options = [
      credential_source: fn ref -> credential(ref) end,
      expected_actor: @actor,
      request_fun: request_fun
    ]

    log =
      capture_log(fn ->
        result = ProjectRepoPreflight.check(@profile, options)
        Logger.error("preflight=#{inspect(result)}")
        send(self(), {:exception_result, result})
      end)

    assert_receive {:exception_result, {:blocked, %{code: :github_unavailable}} = result}
    refute inspect(result) =~ @token
    refute log =~ @token
  end

  test "unknown and incomplete profiles fail before resolving credentials" do
    source = fn _ -> flunk("invalid profiles must not resolve credentials") end

    assert {:blocked, %{code: :project_mapping_missing}} =
             ProjectRepoPreflight.check(%{@profile | key: "unknown"}, credential_source: source)

    assert {:blocked, %{code: :project_mapping_missing}} =
             ProjectRepoPreflight.check(%{key: "project-management"}, credential_source: source)
  end

  for stage <- [:resolver, :authority, :package] do
    test "bounds the complete preflight when #{stage} hangs" do
      assert_bounded_preflight(unquote(stage))
    end
  end

  test "caller termination also terminates a hung credential source" do
    parent = self()

    caller =
      spawn(fn ->
        ProjectRepoPreflight.check(@profile,
          credential_source: fn _ ->
            send(parent, {:hung_source, self()})
            Process.sleep(:infinity)
          end
        )
      end)

    assert_receive {:hung_source, worker}
    monitor = Process.monitor(worker)
    on_exit(fn -> Process.exit(worker, :kill) end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 500
  end

  test "an uncatchable callback exit is sanitized and leaves the caller alive" do
    assert {:blocked, %{code: :github_unavailable, detail: nil}} =
             ProjectRepoPreflight.check(@profile,
               credential_source: fn _ -> Process.exit(self(), :kill) end
             )

    refute_received {:DOWN, _, _, _, _}
    assert {:ok, _receipt} = ProjectRepoPreflight.check(@profile, valid_options(self()))
  end

  defp assert_bounded_preflight(stage) do
    parent = self()
    base = request_fun(parent)

    hang = fn ->
      send(parent, {:hung, self()})
      Process.sleep(:infinity)
    end

    opts = [
      timeout: 25,
      credential_source: fn ref -> if stage == :resolver, do: hang.(), else: credential(ref) end,
      expected_actor: @actor,
      request_fun: fn request ->
        if stage == :authority or (stage == :package and request[:url] =~ "/contents/") do
          hang.()
        else
          base.(request)
        end
      end
    ]

    task = Task.async(fn -> ProjectRepoPreflight.check(@profile, opts) end)
    assert_receive {:hung, worker}, 1_000
    result = Task.yield(task, 500) || Task.shutdown(task, :brutal_kill)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    assert {:ok, {:blocked, %{code: :github_unavailable, detail: nil}}} = result
    refute Process.alive?(worker)
    refute_received {_, {:blocked, _}}
    assert {:ok, _} = ProjectRepoPreflight.check(@profile, valid_options(parent))
  end

  defp valid_options(parent, overrides \\ []) do
    [
      credential_source: fn ref -> credential(ref) end,
      expected_actor: @actor,
      request_fun: request_fun(parent, overrides)
    ]
  end

  defp credential(ref, expires_at \\ nil) do
    {:ok, %{credential_ref: ref, token: @token, expires_at: expires_at}}
  end

  defp request_fun(parent, overrides \\ []) do
    profile = Keyword.get(overrides, :profile, @profile)
    actor = Keyword.get(overrides, :actor, @actor)
    pull? = Keyword.get(overrides, :pull?, true)
    push? = Keyword.get(overrides, :push?, true)
    status = Keyword.get(overrides, :status, 200)
    package_status = Keyword.get(overrides, :package_status, 200)

    package_body =
      Keyword.get(overrides, :package_body, %{
        "scripts" => %{
          "typecheck" => "tsc --noEmit",
          "build" => "next build",
          "db:test" => "bash scripts/db-test.sh"
        }
      })

    fn request ->
      url = Keyword.fetch!(request, :url)
      send(parent, {:event, :requested, url})

      case url do
        "https://api.github.com/graphql" ->
          {:ok, %{status: status, body: %{"data" => %{"viewer" => %{"login" => actor}}}}}

        "https://api.github.com/repos/" <> repository when repository == profile.repository ->
          {:ok,
           %{
             status: status,
             body: %{
               "full_name" => profile.repository,
               "default_branch" => "main",
               "permissions" => %{"pull" => pull?, "push" => push?}
             }
           }}

        "https://api.github.com/repos/" <> repository_and_ref
        when repository_and_ref == profile.repository <> "/git/ref/heads/main" ->
          {:ok,
           %{
             status: status,
             body: %{"ref" => "refs/heads/main", "object" => %{"sha" => @head_sha}}
           }}

        "https://api.github.com/repos/" <> repository_and_path
        when repository_and_path == profile.repository <> "/contents/package.json?ref=#{@head_sha}" ->
          send(
            parent,
            {:package_request,
             %{
               url: url,
               authorized?: {"authorization", "Bearer " <> @token} in Keyword.fetch!(request, :headers),
               redirect: Keyword.get(request, :redirect)
             }}
          )

          {:ok, %{status: package_status, body: package_body}}
      end
    end
  end
end
