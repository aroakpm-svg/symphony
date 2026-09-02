defmodule SymphonyElixir.RuntimeHealthTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Application, Orchestrator, PathSafety, RuntimeHealth}

  @stages [
    :candidate_fetch,
    :issue_refresh,
    :routing,
    :profile_resolution,
    :preflight,
    :claim,
    :dispatch
  ]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runtime-health-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(root, "workspaces")
    receipt_root = Path.join(root, "receipts")
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, workspace_root: workspace_root, receipt_root: receipt_root}
  end

  test "application runtime health starts with the active writer code location" do
    assert is_pid(Process.whereis(RuntimeHealth))

    writer_location = :code.which(:symphony_runtime_receipt_writer)
    assert is_list(writer_location) or writer_location == :cover_compiled
  end

  test "consumes one exact watchdog epoch root receipt and restart-attempt contract", context do
    runtime_state_root = Path.join(context.receipt_root, "watchdog-runtime")
    epoch = "watchdog-epoch-286"
    receipt_path = Path.join(runtime_state_root, "stop-#{epoch}.json")

    health =
      start_supervised!(
        {RuntimeHealth,
         name: nil,
         clock: fn -> ~U[2026-08-31 01:02:03Z] end,
         runtime_state_root: runtime_state_root,
         runtime_epoch: epoch,
         receipt_path: receipt_path,
         restart_attempt: 3,
         workspace_root: context.workspace_root}
      )

    snapshot = RuntimeHealth.snapshot(health)
    assert snapshot.runtime_epoch == epoch
    assert snapshot.runtime_state_root == Path.expand(runtime_state_root)
    assert snapshot.receipt_path == Path.expand(receipt_path)
    assert snapshot.restart_attempt == 3

    assert :ok = RuntimeHealth.stop(health, %{category: :unexpected_exit})
    receipt = receipt_path |> File.read!() |> Jason.decode!()
    assert receipt["runtime_epoch"] == epoch
    assert receipt["receipt_path"] == Path.expand(receipt_path)
    assert receipt["restart_attempt"] == 3

    assert {:error, {:unsafe_runtime_state_root, :receipt_path_mismatch}} =
             RuntimeHealth.start_link(
               name: nil,
               runtime_state_root: runtime_state_root,
               runtime_epoch: "different-epoch",
               receipt_path: receipt_path,
               restart_attempt: 1,
               workspace_root: context.workspace_root
             )

    assert {:error, :invalid_restart_attempt} =
             RuntimeHealth.start_link(
               name: nil,
               runtime_state_root: runtime_state_root,
               runtime_epoch: "new-epoch",
               receipt_path: Path.join(runtime_state_root, "stop-new-epoch.json"),
               restart_attempt: 0,
               workspace_root: context.workspace_root
             )

    assert {:error, :invalid_restart_attempt} =
             RuntimeHealth.start_link(
               name: nil,
               runtime_state_root: runtime_state_root,
               runtime_epoch: "overbound-epoch",
               receipt_path: Path.join(runtime_state_root, "stop-overbound-epoch.json"),
               restart_attempt: 9_223_372_036_854_775_808,
               workspace_root: context.workspace_root
             )
  end

  test "application accepts only a complete watchdog contract matching configured runtime state", context do
    runtime_state_root = Path.join(context.receipt_root, "application-runtime") |> Path.expand()
    epoch = "application-epoch-286"
    receipt_path = Path.join(runtime_state_root, "stop-#{epoch}.json")

    environment = %{
      "SYMPHONY_RUNTIME_EPOCH" => epoch,
      "SYMPHONY_RUNTIME_RECEIPT_PATH" => receipt_path,
      "SYMPHONY_RUNTIME_STATE_ROOT" => runtime_state_root,
      "SYMPHONY_RESTART_ATTEMPT" => "2"
    }

    assert {:ok, opts} =
             Application.watchdog_runtime_health_opts_for_test(
               environment,
               [history_limit: 7],
               runtime_state_root
             )

    assert opts[:history_limit] == 7
    assert opts[:runtime_epoch] == epoch
    assert opts[:runtime_state_root] == runtime_state_root
    assert opts[:receipt_path] == receipt_path
    assert opts[:restart_attempt] == 2

    assert {:error, :incomplete_watchdog_runtime_contract} =
             Application.watchdog_runtime_health_opts_for_test(
               Map.delete(environment, "SYMPHONY_RUNTIME_RECEIPT_PATH"),
               [],
               runtime_state_root
             )

    assert {:error, :watchdog_runtime_state_root_mismatch} =
             Application.watchdog_runtime_health_opts_for_test(
               environment,
               [],
               Path.join(context.receipt_root, "other-runtime")
             )
  end

  test "records all typed stages, dependency state, poll success, and an atomic final receipt", context do
    now = ~U[2026-08-28 01:02:03Z]

    health =
      start_runtime_health(context, clock: fn -> now end, runtime_epoch: "test-epoch")

    metadata = %{
      profile_key: "central-brain",
      issue_id: "issue-286",
      issue_identifier: "ARO-286",
      repository: "aroakpm-svg/aroak-central-brain",
      canonical_branch: "main",
      workspace_namespace: "central-brain",
      environment: "local_non_production",
      routing_revision: 7
    }

    for stage <- @stages do
      assert :ok = RuntimeHealth.stage(health, stage, Map.put(metadata, :status, :started))
      assert :ok = RuntimeHealth.stage(health, stage, Map.put(metadata, :status, :succeeded))
    end

    assert :ok = RuntimeHealth.dependency(health, :linear, %{status: :connected})

    assert :ok =
             RuntimeHealth.dependency(health, :claim_store, %{
               status: :failed,
               failure_category: :claim_timeout
             })

    assert :ok = RuntimeHealth.poll_succeeded(health)

    assert :ok =
             RuntimeHealth.stop(health, %{
               category: :normal_shutdown,
               profile_key: "central-brain",
               issue_id: "issue-286",
               issue_identifier: "ARO-286"
             })

    snapshot = RuntimeHealth.snapshot(health)

    assert snapshot.last_successful_poll_at == "2026-08-28T01:02:03Z"
    assert snapshot.dependencies.linear == %{status: :connected, failure_category: nil}
    assert snapshot.dependencies.claim_store == %{status: :failed, failure_category: :claim_timeout}
    assert snapshot.final_stop.category == :normal_shutdown
    assert snapshot.final_stop.issue_id == "issue-286"
    assert snapshot.final_stop.runtime_epoch == "test-epoch"

    assert Enum.map(snapshot.stages, & &1.stage) |> MapSet.new() == MapSet.new(@stages)
    assert Enum.all?(snapshot.stages, &(&1.status == :succeeded))

    receipt_path = snapshot.final_stop.receipt_path
    assert Path.basename(receipt_path) == "stop-test-epoch.json"
    assert File.regular?(receipt_path)
    assert {:ok, receipt} = receipt_path |> File.read!() |> Jason.decode()
    assert receipt["category"] == "normal_shutdown"
    assert receipt["issue_id"] == "issue-286"
    assert receipt["runtime_epoch"] == "test-epoch"
    assert receipt["receipt_path"] == receipt_path
    refute receipt |> inspect() |> String.contains?("credential")
    assert Path.wildcard(Path.join(Path.dirname(receipt_path), ".stop-*.tmp")) == []
  end

  test "orchestrator reports health events to the configured runtime health server", context do
    server = Module.concat(__MODULE__, :ConfiguredRuntimeHealth)

    health_opts = [
      name: server,
      runtime_epoch: "configured-server",
      receipt_root: context.receipt_root,
      workspace_root: context.workspace_root
    ]

    start_supervised!({RuntimeHealth, health_opts})

    previous_server = Elixir.Application.get_env(:symphony_elixir, :runtime_health_server)
    Elixir.Application.put_env(:symphony_elixir, :runtime_health_server, server)

    on_exit(fn ->
      if is_nil(previous_server) do
        Elixir.Application.delete_env(:symphony_elixir, :runtime_health_server)
      else
        Elixir.Application.put_env(:symphony_elixir, :runtime_health_server, previous_server)
      end
    end)

    event = {:stage, :candidate_fetch, %{status: :succeeded, profile_key: "central-brain"}}
    assert :ok = Orchestrator.report_runtime_health_for_test(event)

    assert [%{stage: :candidate_fetch, status: :succeeded}] = RuntimeHealth.snapshot(server).stages
  end

  test "rejects invalid unknown and oversized clock output before accepting a stop", context do
    for {label, clock_value} <- [
          {:invalid_iso8601, "not-a-timestamp"},
          {:unknown_type, {:not, :a_timestamp}},
          {:oversized_iso8601, String.duplicate("2", 65)}
        ] do
      epoch = "invalid-clock-#{label}"

      {:ok, health} =
        RuntimeHealth.start_link(
          name: nil,
          clock: fn -> clock_value end,
          runtime_epoch: epoch,
          receipt_root: context.receipt_root,
          workspace_root: context.workspace_root
        )

      try do
        assert {:error, :invalid_clock} =
                 RuntimeHealth.stop(health, %{category: :normal_shutdown})

        assert RuntimeHealth.snapshot(health).final_stop == :unknown

        refute File.exists?(Path.join([context.receipt_root, "runtime-state", "stop-#{epoch}.json"]))
      after
        GenServer.stop(health)
      end
    end
  end

  test "rejects an invalid clock before every mutable health transition", context do
    health =
      start_runtime_health(context,
        clock: fn -> "invalid" end,
        runtime_epoch: "invalid-transition-clock"
      )

    assert {:error, :invalid_clock} =
             RuntimeHealth.stage(health, :dispatch, %{status: :started})

    assert {:error, :invalid_clock} =
             RuntimeHealth.dependency(health, :linear, %{status: :connected})

    assert {:error, :invalid_clock} = RuntimeHealth.poll_succeeded(health)

    assert %{
             stages: [],
             history: [],
             last_successful_poll_at: :unknown,
             final_stop: :unknown,
             dependencies: %{
               linear: %{status: :unknown, failure_category: nil},
               claim_store: %{status: :unknown, failure_category: nil}
             }
           } = RuntimeHealth.snapshot(health)
  end

  test "normalizes DateTime and ISO8601 offsets at the exact UTC timestamp boundary", context do
    offset_datetime = %DateTime{
      year: 2026,
      month: 8,
      day: 29,
      hour: 14,
      minute: 0,
      second: 0,
      microsecond: {999_999, 6},
      time_zone: "Asia/Taipei",
      zone_abbr: "CST",
      utc_offset: 28_800,
      std_offset: 0
    }

    clocks = [
      {"datetime-offset-clock", offset_datetime, "2026-08-29T06:00:00Z"},
      {"offset-clock", "2026-08-29T14:00:00.999999+08:00", "2026-08-29T06:00:00Z"},
      {"utc-boundary-clock", "9999-12-31T23:59:59.999999+00:00", "9999-12-31T23:59:59Z"}
    ]

    for {epoch, clock_value, expected} <- clocks do
      {:ok, health} =
        RuntimeHealth.start_link(
          name: nil,
          clock: fn -> clock_value end,
          runtime_epoch: epoch,
          receipt_root: context.receipt_root,
          workspace_root: context.workspace_root
        )

      try do
        assert :ok = RuntimeHealth.stop(health, %{category: :normal_shutdown})
        final_stop = RuntimeHealth.snapshot(health).final_stop
        assert final_stop.at == expected
        assert byte_size(final_stop.at) == 20
        assert Jason.decode!(File.read!(final_stop.receipt_path))["at"] == expected
      after
        GenServer.stop(health)
      end
    end
  end

  test "truncates an oversized single grapheme by UTF-8 bytes before receipt publication", context do
    health =
      start_runtime_health(context, runtime_epoch: "oversize-receipt")

    oversized_single_grapheme = "a" <> String.duplicate("́", 9_000)
    expected_detail = "a" <> String.duplicate("́", 4_095)

    assert :ok =
             RuntimeHealth.stop(health, %{
               category: :unexpected_exit,
               detail: oversized_single_grapheme
             })

    receipt_path = Path.join([context.receipt_root, "runtime-state", "stop-oversize-receipt.json"])
    assert File.regular?(receipt_path)
    assert Jason.decode!(File.read!(receipt_path))["detail"] == expected_detail
    assert byte_size(expected_detail) == 8_191
    assert String.valid?(expected_detail)
  end

  test "normalizes stage and stop detail at the exact UTF-8 byte boundary", context do
    health =
      start_runtime_health(context, runtime_epoch: "detail-boundary")

    max_detail = max_detail_with_zwj()
    oversized_detail = max_detail <> "🔥"

    assert byte_size(max_detail) == 8_192
    assert :ok = RuntimeHealth.stage(health, :dispatch, %{status: :failed, detail: oversized_detail})
    assert [%{detail: ^max_detail}] = RuntimeHealth.snapshot(health).stages

    assert :ok =
             RuntimeHealth.stop(health, %{
               category: :unexpected_exit,
               detail: oversized_detail
             })

    receipt_path = RuntimeHealth.snapshot(health).final_stop.receipt_path
    assert Jason.decode!(File.read!(receipt_path))["detail"] == max_detail
  end

  test "accepts signed 64-bit routing revision maximum and rejects the next integer", context do
    max_revision = 9_223_372_036_854_775_807

    health =
      start_runtime_health(context, runtime_epoch: "revision-boundary")

    assert :ok =
             RuntimeHealth.stage(health, :routing, %{
               status: :succeeded,
               routing_revision: max_revision
             })

    assert {:error, {:invalid_field, :routing_revision}} =
             RuntimeHealth.stage(health, :routing, %{
               status: :succeeded,
               routing_revision: max_revision + 1
             })

    assert :ok =
             RuntimeHealth.stop(health, %{
               category: :normal_shutdown,
               routing_revision: max_revision
             })

    receipt_path = RuntimeHealth.snapshot(health).final_stop.receipt_path
    assert Jason.decode!(File.read!(receipt_path))["routing_revision"] == max_revision
  end

  test "publishes the maximum receipt field combination beyond the old 16 KiB ceiling", context do
    epoch = String.duplicate("e", 128)

    health =
      start_runtime_health(context, runtime_epoch: epoch)

    fields = maximum_stop_fields()
    assert :ok = RuntimeHealth.stop(health, fields)

    receipt_path = RuntimeHealth.snapshot(health).final_stop.receipt_path
    encoded = File.read!(receipt_path)
    receipt = Jason.decode!(encoded)

    assert byte_size(encoded) > 16_384
    assert byte_size(encoded) <= 98_304
    assert receipt["detail"] == fields.detail
    assert receipt["canonical_branch"] == fields.canonical_branch
    assert receipt["routing_revision"] == fields.routing_revision
  end

  test "starts with unknown evidence and keeps bounded idempotent history", context do
    {:ok, clock_tick} = Agent.start_link(fn -> 0 end)

    clock = fn ->
      seconds = Agent.get_and_update(clock_tick, &{&1, &1 + 1})
      DateTime.add(~U[2026-08-28 02:00:00Z], seconds, :second)
    end

    health =
      start_runtime_health(context, clock: clock, history_limit: 3)

    initial = RuntimeHealth.snapshot(health)
    assert initial.last_successful_poll_at == :unknown
    assert initial.final_stop == :unknown
    assert initial.stages == []
    assert initial.dependencies.linear == %{status: :unknown, failure_category: nil}
    assert initial.dependencies.claim_store == %{status: :unknown, failure_category: nil}

    event = %{status: :started, profile_key: "central-brain"}
    assert :ok = RuntimeHealth.stage(health, :candidate_fetch, event)
    assert :ok = RuntimeHealth.stage(health, :candidate_fetch, event)
    assert length(RuntimeHealth.snapshot(health).history) == 1
    assert [%{at: "2026-08-28T02:00:00Z"}] = RuntimeHealth.snapshot(health).stages

    assert :ok = RuntimeHealth.stage(health, :candidate_fetch, %{event | status: :succeeded})
    assert :ok = RuntimeHealth.dependency(health, :linear, %{status: :connected})
    assert :ok = RuntimeHealth.poll_succeeded(health)

    snapshot = RuntimeHealth.snapshot(health)
    assert length(snapshot.history) == 3
    refute Enum.any?(snapshot.history, &(&1.status == :started))
  end

  test "rejects unknown stages, fields, and credential-like values before truncation", context do
    health =
      start_runtime_health(context, clock: fn -> ~U[2026-08-28 03:00:00Z] end)

    assert {:error, :unknown_stage} =
             RuntimeHealth.stage(health, :workspace_creation, %{status: :started})

    assert {:error, {:unknown_field, :credential_ref}} =
             RuntimeHealth.stage(health, :dispatch, %{
               status: :started,
               credential_ref: "github-central-brain"
             })

    canary = String.duplicate("x", 300) <> " token=canary-secret"

    assert {:error, :secret_bearing_value} =
             RuntimeHealth.stage(health, :dispatch, %{status: :failed, detail: canary})

    assert {:error, :secret_bearing_value} =
             RuntimeHealth.stage(health, :dispatch, %{
               status: :failed,
               detail: "env:PROJECT_GITHUB_TOKEN"
             })

    secret_shapes = [
      "sk-proj-abcdefghijklmnopqrstuvwxyz012345",
      "gho_abcdefghijklmnopqrstuvwxyz0123456789",
      "github_pat_11AAabcdefghijklmnopqrstuvwxyz012345",
      "AKIAIOSFODNN7EXAMPLE",
      "ASIAIOSFODNN7EXAMPLE",
      "xoxb-" <> "123456789012-123456789012-abcdefghijklmnop",
      "AIzaSyDabcdefghijklmnopqrstuvwxyz012345",
      "rk_" <> "live_abcdefghijklmnopqrstuvwxyz",
      "glpat-abcdefghijklmnopqrstuvwxyz",
      "npm_abcdefghijklmnopqrstuvwxyz0123456789",
      "pypi-abcdefghijklmnopqrstuvwxyz0123456789",
      "hf_abcdefghijklmnopqrstuvwxyz0123456789",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature"
    ]

    for secret <- secret_shapes do
      assert {:error, :secret_bearing_value} =
               RuntimeHealth.stage(health, :dispatch, %{
                 status: :failed,
                 detail: secret
               })
    end

    for field <- [
          :profile_key,
          :issue_id,
          :issue_identifier,
          :repository,
          :canonical_branch,
          :workspace_namespace,
          :environment,
          :detail
        ] do
      assert {:error, :secret_bearing_value} =
               RuntimeHealth.stage(health, :dispatch, %{
                 field => "gho_abcdefghijklmnopqrstuvwxyz0123456789",
                 status: :failed
               })
    end

    assert RuntimeHealth.snapshot(health).history == []
  end

  test "validates every accepted field by key and rejects wrong scalar types", context do
    health =
      start_runtime_health(context)

    invalid_stage_fields = [
      {%{status: "started"}, :status},
      {%{status: :started, profile_key: 7}, :profile_key},
      {%{status: :started, issue_id: nil}, :issue_id},
      {%{status: :started, issue_identifier: "contains whitespace"}, :issue_identifier},
      {%{status: :started, repository: "missing-owner"}, :repository},
      {%{status: :started, canonical_branch: 42}, :canonical_branch},
      {%{status: :started, workspace_namespace: "Bad Namespace"}, :workspace_namespace},
      {%{status: :started, environment: "Production"}, :environment},
      {%{status: :started, routing_revision: 0}, :routing_revision},
      {%{status: :failed, failure_category: "claim_timeout"}, :failure_category},
      {%{status: :failed, failure_category: :credential_leak}, :failure_category},
      {%{status: :failed, detail: 123}, :detail}
    ]

    for {fields, field} <- invalid_stage_fields do
      assert {:error, {:invalid_field, ^field}} =
               RuntimeHealth.stage(health, :dispatch, fields)
    end

    assert {:error, {:invalid_field, :status}} =
             RuntimeHealth.dependency(health, :linear, %{status: "connected"})

    assert {:error, {:invalid_field, :failure_category}} =
             RuntimeHealth.dependency(health, :linear, %{
               status: :failed,
               failure_category: :not_a_health_category
             })

    assert {:error, {:invalid_field, :category}} =
             RuntimeHealth.stop(health, %{category: "normal_shutdown"})
  end

  test "dependency and stop replays are idempotent while every stop replay is revalidated", context do
    {:ok, clock_tick} = Agent.start_link(fn -> 0 end)

    clock = fn ->
      seconds = Agent.get_and_update(clock_tick, &{&1, &1 + 1})
      DateTime.add(~U[2026-08-28 04:00:00Z], seconds, :second)
    end

    health =
      start_runtime_health(context, clock: clock, runtime_epoch: "replay-epoch")

    dependency = %{status: :failed, failure_category: :claim_timeout}
    assert :ok = RuntimeHealth.dependency(health, :claim_store, dependency)
    assert :ok = RuntimeHealth.dependency(health, :claim_store, dependency)

    assert Enum.count(RuntimeHealth.snapshot(health).history, &(&1.type == :dependency)) == 1

    stop = %{category: :normal_shutdown, issue_id: "issue-replay", issue_identifier: "ARO-REPLAY"}
    assert :ok = RuntimeHealth.stop(health, stop)
    assert :ok = RuntimeHealth.stop(health, stop)

    assert {:error, {:unknown_field, :credential_ref}} =
             RuntimeHealth.stop(health, Map.put(stop, :credential_ref, "github-secret"))

    assert {:error, :secret_bearing_value} =
             RuntimeHealth.stop(health, Map.put(stop, :detail, "gho_abcdefghijklmnopqrstuvwxyz0123456789"))

    snapshot = RuntimeHealth.snapshot(health)
    assert Enum.count(snapshot.history, &(&1.type == :stop)) == 1
    assert snapshot.final_stop.issue_id == "issue-replay"

    assert Path.wildcard(Path.join(Path.dirname(snapshot.final_stop.receipt_path), "stop-*.json")) == [
             snapshot.final_stop.receipt_path
           ]

    File.rm!(snapshot.final_stop.receipt_path)
    assert :ok = RuntimeHealth.stop(health, stop)
    refute File.exists?(snapshot.final_stop.receipt_path)
  end

  test "rejects a preexisting canonical runtime-state escape outside the configured root", context do
    runtime_state_path = Path.join(context.receipt_root, "runtime-state") |> Path.expand()
    escaped_path = Path.join(context.root, "escaped-runtime-state") |> Path.expand()
    filesystem_root = context.root |> Path.expand() |> Path.split() |> hd()

    resolver = fn path ->
      expanded = Path.expand(path)

      if expanded == runtime_state_path,
        do: {:ok, escaped_path},
        else: PathSafety.canonicalize(expanded)
    end

    assert {:error, {:unsafe_runtime_state_root, :outside_receipt_root}} =
             RuntimeHealth.start_link(
               name: nil,
               path_resolver: resolver,
               receipt_root: context.receipt_root,
               workspace_root: context.workspace_root
             )

    root_resolver = fn path ->
      if Path.expand(path) == runtime_state_path,
        do: {:ok, filesystem_root},
        else: PathSafety.canonicalize(path)
    end

    assert {:error, {:unsafe_runtime_state_root, :filesystem_root}} =
             RuntimeHealth.start_link(
               name: nil,
               path_resolver: root_resolver,
               receipt_root: context.receipt_root,
               workspace_root: context.workspace_root
             )
  end

  test "fails closed when canonical runtime-state identity drifts between validation and init", context do
    runtime_state_path = Path.join(context.receipt_root, "runtime-state") |> Path.expand()
    drifted_path = Path.join(context.receipt_root, "runtime-state-drift") |> Path.expand()
    {:ok, runtime_state_resolutions} = Agent.start_link(fn -> 0 end)

    resolver = fn path ->
      expanded = Path.expand(path)

      if expanded == runtime_state_path do
        resolution = Agent.get_and_update(runtime_state_resolutions, &{&1, &1 + 1})
        if resolution == 0, do: PathSafety.canonicalize(expanded), else: {:ok, drifted_path}
      else
        PathSafety.canonicalize(expanded)
      end
    end

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:unsafe_runtime_state_root, :path_changed}} =
               RuntimeHealth.start_link(
                 name: nil,
                 path_resolver: resolver,
                 receipt_root: context.receipt_root,
                 workspace_root: context.workspace_root
               )
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end

    assert Agent.get(runtime_state_resolutions, & &1) == 2
    refute File.exists?(drifted_path)
  end

  test "revalidates canonical containment when runtime-state is replaced after startup", context do
    runtime_state_path = Path.join(context.receipt_root, "runtime-state") |> Path.expand()
    escaped_path = Path.join(context.root, "post-validation-escape") |> Path.expand()
    {:ok, resolver_mode} = Agent.start_link(fn -> :safe end)

    resolver = fn path ->
      expanded = Path.expand(path)

      if expanded == runtime_state_path and Agent.get(resolver_mode, & &1) == :escaped,
        do: {:ok, escaped_path},
        else: PathSafety.canonicalize(expanded)
    end

    health =
      start_runtime_health(context, runtime_epoch: "replaced-epoch", path_resolver: resolver)

    Agent.update(resolver_mode, fn _mode -> :escaped end)

    assert {:error, {:unsafe_runtime_state_root, :outside_receipt_root}} =
             RuntimeHealth.stop(health, %{category: :normal_shutdown})

    assert RuntimeHealth.snapshot(health).final_stop == :unknown
    refute File.exists?(Path.join(escaped_path, "stop-replaced-epoch.json"))
  end

  test "publication capability rejects rename recreate and copied-token relocation", context do
    runtime_state_path = Path.join(context.receipt_root, "runtime-state")
    displaced_path = Path.join(context.receipt_root, "runtime-state-displaced")
    workspace_escape = Path.join(context.workspace_root, "escaped-runtime-state")
    filesystem_root = context.root |> Path.expand() |> Path.split() |> hd()
    File.mkdir_p!(workspace_escape)
    {:ok, attack_result} = Agent.start_link(fn -> :not_called end)

    before_receipt_publish = fn validated_runtime_state_dir ->
      guard_name =
        validated_runtime_state_dir
        |> File.ls!()
        |> Enum.find(&String.starts_with?(&1, ".runtime-health-"))

      guard_path = Path.join(validated_runtime_state_dir, guard_name)
      guard_token = File.read!(guard_path)

      result =
        case File.rename(validated_runtime_state_dir, displaced_path) do
          :ok ->
            File.mkdir_p!(runtime_state_path)
            File.write!(Path.join(runtime_state_path, Path.basename(guard_path)), guard_token)
            :replaced_with_copied_token

          {:error, reason} ->
            {:replacement_blocked, reason}
        end

      Agent.update(attack_result, fn _previous -> result end)
    end

    health =
      start_supervised!(
        {RuntimeHealth,
         Keyword.merge(
           [name: nil, receipt_root: context.receipt_root, workspace_root: context.workspace_root],
           runtime_epoch: "boundary-epoch",
           before_receipt_publish: before_receipt_publish
         )}
      )

    result = RuntimeHealth.stop(health, %{category: :normal_shutdown})
    attack = Agent.get(attack_result, & &1)

    assert attack != :not_called, inspect({attack, result})
    assert attack == :replaced_with_copied_token or match?({:replacement_blocked, _reason}, attack)

    if match?({:win32, _}, :os.type()) do
      assert match?({:replacement_blocked, _reason}, attack)
    end

    if attack == :replaced_with_copied_token do
      assert {:error, :receipt_write_failed} = result
      assert RuntimeHealth.snapshot(health).final_stop == :unknown
      refute File.exists?(Path.join(runtime_state_path, "stop-boundary-epoch.json"))
    else
      assert :ok = result
      assert File.regular?(RuntimeHealth.snapshot(health).final_stop.receipt_path)
    end

    refute File.exists?(Path.join(workspace_escape, "stop-boundary-epoch.json"))
    refute File.exists?(Path.join(displaced_path, "stop-boundary-epoch.json"))
    refute File.exists?(Path.join(filesystem_root, "stop-boundary-epoch.json"))
  end

  test "attests the pinned writer after an acquisition-boundary replacement", context do
    escaped_directory = Path.join(context.workspace_root, "acquisition-escape")
    displaced_directory = Path.join(context.receipt_root, "runtime-state-before-acquisition")
    File.mkdir_p!(escaped_directory)
    parent = self()
    {:ok, acquisition_mode} = Agent.start_link(fn -> :not_called end)

    before_receipt_writer_open = fn validated_directory ->
      send(parent, {:acquisition_boundary, validated_directory})

      result =
        case File.rename(validated_directory, displaced_directory) do
          :ok ->
            case File.ln_s(escaped_directory, validated_directory) do
              :ok ->
                {:replaced, validated_directory}

              {:error, reason} ->
                :ok = File.rename(displaced_directory, validated_directory)
                {{:injected_after_unsupported_symlink, reason}, escaped_directory}
            end

          {:error, reason} ->
            {{:injected_after_unsupported_rename, reason}, escaped_directory}
        end

      {mode, acquisition_directory} = result
      Agent.update(acquisition_mode, fn _previous -> mode end)
      {:ok, acquisition_directory}
    end

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:receipt_writer_unavailable, :capability_attestation_failed}} =
               RuntimeHealth.start_link(
                 name: nil,
                 runtime_epoch: "acquisition-epoch",
                 before_receipt_writer_open: before_receipt_writer_open,
                 receipt_root: context.receipt_root,
                 workspace_root: context.workspace_root
               )
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end

    assert_receive {:acquisition_boundary, validated_directory}
    assert Path.basename(validated_directory) == "runtime-state"
    assert Agent.get(acquisition_mode, & &1) != :not_called
    refute File.exists?(Path.join(escaped_directory, ".runtime-health-acquisition-epoch.lock"))
    refute File.exists?(Path.join(escaped_directory, "stop-acquisition-epoch.json"))

    if Agent.get(acquisition_mode, & &1) == :replaced do
      :ok = File.rm(validated_directory)
      :ok = File.rename(displaced_directory, validated_directory)
    end
  end

  test "discovers the trusted bundled ERTS launcher in a release layout", context do
    release_root = Path.join(context.root, "release-root")
    erts_version = "99.88"
    executable_name = if match?({:win32, _}, :os.type()), do: "erl.exe", else: "erl"
    bundled_executable = Path.join([release_root, "erts-#{erts_version}", "bin", executable_name])
    File.mkdir_p!(Path.dirname(bundled_executable))
    File.write!(bundled_executable, "test launcher placeholder")
    {:ok, resolved_paths} = Agent.start_link(fn -> [] end)
    parent = self()

    executable_path_resolver = fn path ->
      Agent.update(resolved_paths, &[Path.expand(path) | &1])
      PathSafety.canonicalize(path)
    end

    port_opener = fn selected_executable, _ebin_path, _runtime_state_dir ->
      send(parent, {:selected_executable, selected_executable})
      {:error, :probe_complete}
    end

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:receipt_writer_unavailable, :probe_complete}} =
               RuntimeHealth.start_link(
                 name: nil,
                 runtime_epoch: "release-layout-epoch",
                 otp_root: release_root,
                 erts_version: erts_version,
                 receipt_writer_executable_path_resolver: executable_path_resolver,
                 receipt_writer_port_opener: port_opener,
                 receipt_root: context.receipt_root,
                 workspace_root: context.workspace_root
               )
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end

    assert_receive {:selected_executable, selected_executable}

    normalize_path = fn path ->
      path |> Path.expand() |> String.replace("\\", "/") |> String.downcase()
    end

    assert normalize_path.(selected_executable) == normalize_path.(bundled_executable)

    assert Enum.any?(Agent.get(resolved_paths, & &1), fn resolved_path ->
             normalize_path.(resolved_path) == normalize_path.(bundled_executable)
           end)

    refute_received {:selected_executable, _other}
  end

  test "fails closed when no trusted OTP launcher exists", context do
    empty_otp_root = Path.join(context.root, "stripped-release")
    File.mkdir_p!(empty_otp_root)
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:receipt_writer_unavailable, :erl_not_found}} =
               RuntimeHealth.start_link(
                 name: nil,
                 runtime_epoch: "missing-launcher-epoch",
                 otp_root: empty_otp_root,
                 erts_version: "99.99",
                 receipt_root: context.receipt_root,
                 workspace_root: context.workspace_root
               )
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end

    refute File.exists?(
             Path.join([
               context.receipt_root,
               "runtime-state",
               ".runtime-health-missing-launcher-epoch.lock"
             ])
           )
  end

  test "retires a timed-out writer so late replies cannot publish or satisfy a retry", context do
    health =
      start_supervised!(
        {RuntimeHealth,
         name: nil,
         runtime_epoch: "timeout-epoch",
         receipt_writer_command_timeout_ms: 20,
         receipt_writer_publish_delay_ms: 200,
         receipt_root: context.receipt_root,
         workspace_root: context.workspace_root}
      )

    assert {:error, :receipt_write_failed} =
             RuntimeHealth.stop(health, %{category: :normal_shutdown})

    assert :sys.get_state(health).receipt_writer.usable == false
    Process.sleep(300)

    receipt_path = Path.join([context.receipt_root, "runtime-state", "stop-timeout-epoch.json"])
    guard_path = Path.join([context.receipt_root, "runtime-state", ".runtime-health-timeout-epoch.lock"])

    refute File.exists?(receipt_path)
    refute File.exists?(guard_path)

    assert {:error, :receipt_write_failed} =
             RuntimeHealth.stop(health, %{category: :normal_shutdown})

    refute File.exists?(receipt_path)
  end

  test "uses immutable epoch receipts so Windows never replaces an existing target", context do
    start_health = fn epoch ->
      {:ok, health} =
        RuntimeHealth.start_link(
          name: nil,
          runtime_epoch: epoch,
          receipt_root: context.receipt_root,
          workspace_root: context.workspace_root
        )

      assert :ok = RuntimeHealth.stop(health, %{category: :normal_shutdown})
      snapshot = RuntimeHealth.snapshot(health)
      GenServer.stop(health)
      snapshot
    end

    first = start_health.("epoch-one")
    second = start_health.("epoch-two")

    assert Path.basename(first.final_stop.receipt_path) == "stop-epoch-one.json"
    assert Path.basename(second.final_stop.receipt_path) == "stop-epoch-two.json"
    assert File.regular?(first.final_stop.receipt_path)
    assert File.regular?(second.final_stop.receipt_path)

    original_receipt = File.read!(first.final_stop.receipt_path)

    {:ok, collision_health} =
      RuntimeHealth.start_link(
        name: nil,
        runtime_epoch: "epoch-one",
        receipt_root: context.receipt_root,
        workspace_root: context.workspace_root
      )

    assert {:error, :receipt_write_failed} =
             RuntimeHealth.stop(collision_health, %{category: :startup_failure})

    assert RuntimeHealth.snapshot(collision_health).final_stop == :unknown
    assert File.read!(first.final_stop.receipt_path) == original_receipt
    GenServer.stop(collision_health)

    receipt_pattern = Path.join(Path.dirname(first.final_stop.receipt_path), "stop-*.json")

    assert Enum.sort(Path.wildcard(receipt_pattern)) ==
             Enum.sort([first.final_stop.receipt_path, second.final_stop.receipt_path])

    assert Path.wildcard(Path.join(Path.dirname(first.final_stop.receipt_path), ".stop-*.tmp")) == []
  end

  test "rejects filesystem roots and workspace-contained receipt targets", context do
    filesystem_root = context.root |> Path.expand() |> Path.split() |> hd()

    assert {:error, {:unsafe_runtime_state_root, :filesystem_root}} =
             RuntimeHealth.start_link(
               name: nil,
               receipt_root: filesystem_root,
               workspace_root: context.workspace_root
             )

    assert {:error, {:unsafe_runtime_state_root, :workspace_target}} =
             RuntimeHealth.start_link(
               name: nil,
               receipt_root: Path.join(context.workspace_root, "diagnostics"),
               workspace_root: context.workspace_root
             )
  end

  defp maximum_stop_fields do
    %{
      category: :unexpected_exit,
      profile_key: String.duplicate("p", 128),
      issue_id: String.duplicate("i", 128),
      issue_identifier: String.duplicate("I", 128),
      repository: String.duplicate("r", 127) <> "/" <> String.duplicate("s", 128),
      canonical_branch: String.duplicate("\"", 256),
      workspace_namespace: String.duplicate("w", 128),
      environment: "local_non_production",
      routing_revision: 9_223_372_036_854_775_807,
      failure_category: :required_check_contract_unreadable,
      detail: max_detail_with_zwj()
    }
  end

  defp max_detail_with_zwj do
    family = "👨‍👩‍👧‍👦"
    family <> String.duplicate("\\", 8_192 - byte_size(family))
  end

  defp start_runtime_health(context, opts \\ []) do
    defaults = [
      name: nil,
      receipt_root: context.receipt_root,
      workspace_root: context.workspace_root
    ]

    start_supervised!({RuntimeHealth, Keyword.merge(defaults, opts)})
  end
end
