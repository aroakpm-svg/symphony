defmodule SymphonyElixir.SymphonyWatchdogTest do
  use ExUnit.Case

  @moduletag skip:
               if(match?({:win32, _}, :os.type()),
                 do: false,
                 else: "Windows watchdog requires Win32 handle and job-object capabilities"
               )

  import SymphonyElixir.TestSupport, only: [create_directory_link!: 2]

  alias SymphonyElixir.RuntimeHealth

  @watchdog Path.expand("../../bin/symphony-watchdog.ps1", __DIR__)
  @pwsh if(match?({:win32, _}, :os.type()), do: System.find_executable("pwsh"), else: nil)
  @windows_powershell System.find_executable("powershell.exe")

  @tag skip: if(is_nil(@pwsh), do: "pwsh unavailable", else: false)
  test "pwsh parser accepts the watchdog script" do
    assert_watchdog_parser!(@pwsh)
  end

  @tag skip: if(is_nil(@windows_powershell), do: "powershell.exe unavailable", else: false)
  test "Windows PowerShell parser accepts the watchdog script" do
    assert_watchdog_parser!(@windows_powershell)
  end

  defp assert_watchdog_parser!(powershell) do
    parse_command =
      "$tokens = $null; $errors = $null; " <>
        "[System.Management.Automation.Language.Parser]::ParseFile(#{ps_literal(@watchdog)}, [ref]$tokens, [ref]$errors) | Out-Null; " <>
        "if ($errors.Count -ne 0) { exit 1 }"

    assert {"", 0} =
             System.cmd(powershell, [
               "-NoLogo",
               "-NoProfile",
               "-NonInteractive",
               "-ExecutionPolicy",
               "Bypass",
               "-Command",
               parse_command
             ])
  end

  test "restart attempts increment with one retained epoch and success clears state" do
    with_fixture(fn fixture ->
      write_plan!(fixture.plan_path, [9, 0])

      assert {output, 0} = run_watchdog(fixture, restart_limit: 3)
      assert output == ""

      [first, second] = read_json_lines(fixture.child_log_path)
      assert Enum.map([first, second], & &1["attempt_count"]) == [1, 2]
      assert first["runtime_epoch"] == second["runtime_epoch"]

      assert same_path?(
               first["receipt_path"],
               Path.join(fixture.root, "stop-#{first["runtime_epoch"]}.json")
             )

      refute File.exists?(fixture.state_path)
      assert read_json_lines(fixture.notification_log_path) == []
    end)
  end

  test "a successful run resets the epoch used by the next launcher invocation" do
    with_fixture(fn fixture ->
      write_plan!(fixture.plan_path, [7, 0])
      assert {"", 0} = run_watchdog(fixture, restart_limit: 3)
      [first_failure, first_success] = read_json_lines(fixture.child_log_path)
      assert first_failure["runtime_epoch"] == first_success["runtime_epoch"]

      write_plan!(fixture.plan_path, [0])
      assert {"", 0} = run_watchdog(fixture, restart_limit: 3)
      [_first_failure, _first_success, next_success] = read_json_lines(fixture.child_log_path)

      refute next_success["runtime_epoch"] == first_success["runtime_epoch"]
      refute File.exists?(fixture.state_path)
    end)
  end

  test "restart limit invokes exactly one receiver-bound notification for the epoch" do
    with_fixture(fn fixture ->
      write_plan!(fixture.plan_path, [8, 8, 8])

      assert {"", 1} = run_watchdog(fixture, restart_limit: 2)
      assert {"", 1} = run_watchdog(fixture, restart_limit: 2)

      [event] = read_json_lines(fixture.notification_log_path)
      [first, second] = read_json_lines(fixture.child_log_path)

      assert event == %{
               "runtime_identity" => "symphony-watchdog-test",
               "receiver" => "on-call:platform",
               "attempt_count" => 2,
               "stop_category" => "restart_limit",
               "timestamp" => event["timestamp"],
               "runtime_epoch" => first["runtime_epoch"],
               "receipt_path" => first["receipt_path"]
             }

      assert second["runtime_epoch"] == first["runtime_epoch"]
      assert File.regular?(event["receipt_path"])

      assert fixture.root
             |> File.ls!()
             |> Enum.count(
               &(String.starts_with?(&1, "restart-limit-delivery-") and
                   String.ends_with?(&1, ".json"))
             ) == 1

      [delivery_name] =
        Enum.filter(File.ls!(fixture.root), &String.starts_with?(&1, "restart-limit-delivery-"))

      assert delivery_name ==
               Path.basename(new_delivery_path(fixture.root, "on-call:platform", first["runtime_epoch"]))

      refute File.exists?(legacy_delivery_path(fixture.root, "on-call:platform", first["runtime_epoch"]))

      delivery = fixture.root |> Path.join(delivery_name) |> File.read!() |> Jason.decode!()
      assert delivery["receiver_hash"] == receiver_hash("on-call:platform")
      refute Map.has_key?(delivery, "receiver")
      refute File.read!(Path.join(fixture.root, delivery_name)) =~ "on-call:platform"

      root_names = fixture.root |> File.ls!() |> Enum.join("\n")
      refute root_names =~ "on-call"
      refute root_names =~ "platform"
    end)
  end

  test "a real RuntimeHealth child crash reaches the shared receipt and notification contract" do
    with_fixture(fn fixture ->
      child_script = Path.join(fixture.control_root, "runtime-health-crash.exs")
      snapshot_path = Path.join(fixture.control_root, "runtime-health-snapshot.json")
      mix = System.find_executable("mix")
      project_root = Path.expand("../..", __DIR__)

      File.write!(child_script, """
      runtime_state_root = System.fetch_env!("SYMPHONY_RUNTIME_STATE_ROOT")
      epoch = System.fetch_env!("SYMPHONY_RUNTIME_EPOCH")
      receipt_path = System.fetch_env!("SYMPHONY_RUNTIME_RECEIPT_PATH")
      attempt = System.fetch_env!("SYMPHONY_RESTART_ATTEMPT") |> String.to_integer()

      {:ok, health} =
        SymphonyElixir.RuntimeHealth.start_link(
          name: nil,
          runtime_state_root: runtime_state_root,
          runtime_epoch: epoch,
          receipt_path: receipt_path,
          restart_attempt: attempt,
          workspace_root: #{inspect(Path.join(fixture.control_root, "workspaces"))}
        )

      snapshot = SymphonyElixir.RuntimeHealth.snapshot(health)
      File.write!(#{inspect(snapshot_path)}, Jason.encode!(snapshot))
      System.halt(17)
      """)

      child_command =
        "Set-Location -LiteralPath #{ps_literal(project_root)}; " <>
          "& #{ps_literal(mix)} run --no-start #{ps_literal(child_script)}"

      assert {"", 1} =
               run_watchdog(fixture,
                 restart_limit: 1,
                 child_command: child_command
               )

      snapshot = snapshot_path |> File.read!() |> Jason.decode!()
      receipt_path = snapshot["receipt_path"]
      assert same_path?(snapshot["runtime_state_root"], fixture.root)
      assert same_path?(receipt_path, Path.join(fixture.root, "stop-#{snapshot["runtime_epoch"]}.json"))
      assert snapshot["restart_attempt"] == 1

      receipt = receipt_path |> File.read!() |> Jason.decode!()
      assert receipt["category"] == "restart_limit"
      assert receipt["runtime_epoch"] == snapshot["runtime_epoch"]
      assert receipt["restart_attempt"] == 1
      assert same_path?(receipt["receipt_path"], receipt_path)

      [notification] = read_json_lines(fixture.notification_log_path)
      assert notification["runtime_epoch"] == snapshot["runtime_epoch"]
      assert notification["attempt_count"] == 1
      assert same_path?(notification["receipt_path"], receipt_path)
    end)
  end

  test "child environment values and all child and notifier output are discarded" do
    with_fixture(fn fixture ->
      canary = "CANARY_SECRET_CHILD_ENV_AND_OUTPUT"
      write_plan!(fixture.plan_path, [6])

      assert {output, 1} =
               run_watchdog(fixture,
                 restart_limit: 1,
                 child_canary: canary,
                 notifier_canary: canary
               )

      refute output =~ canary
      refute output =~ "SYMPHONY_RUNTIME_EPOCH"
      refute output =~ "SYMPHONY_RUNTIME_RECEIPT_PATH"
    end)
  end

  test "an undelivered terminal notification replays the identical epoch event" do
    with_fixture(fn fixture ->
      write_plan!(fixture.plan_path, [5])
      write_plan!(fixture.notification_plan_path, [19, 0])

      assert {"", 1} = run_watchdog(fixture, restart_limit: 1)
      Process.sleep(1_100)
      assert {"", 1} = run_watchdog(fixture, restart_limit: 1)

      [first_event, replayed_event] = read_json_lines(fixture.notification_log_path)
      assert replayed_event == first_event

      assert fixture.root
             |> File.ls!()
             |> Enum.count(&String.starts_with?(&1, "restart-limit-delivery-")) == 1
    end)
  end

  test "notifications may be fully disabled while partial config fails closed without binding output" do
    with_fixture(fn fixture ->
      write_plan!(fixture.plan_path, [4])

      assert {"", 1} =
               run_watchdog(fixture, restart_limit: 1, notifications: :disabled)

      assert read_json_lines(fixture.notification_log_path) == []
      assert delivery_receipts(fixture.root) == []

      for mode <- [:command_only, :receiver_only] do
        File.rm(fixture.state_path)
        write_plan!(fixture.plan_path, [0])
        assert {"", 2} = run_watchdog(fixture, notifications: mode)
      end

      assert read_json_lines(fixture.notification_log_path) == []
    end)
  end

  test "secret-bearing runtime identities fail closed before child execution" do
    with_fixture(fn fixture ->
      for identity <- ["token:canary", "sk-proj-abcdefghijklmnop"] do
        write_plan!(fixture.plan_path, [0])
        assert {"", 2} = run_watchdog(fixture, runtime_identity: identity)
      end

      assert read_json_lines(fixture.child_log_path) == []
      assert read_json_lines(fixture.notification_log_path) == []
    end)
  end

  test "watchdog rejects a malformed Task 5 receipt without notification" do
    with_fixture(fn fixture ->
      for mode <- [
            "extra_key",
            "wrong_timestamp",
            "wrong_environment",
            "wrong_repository",
            "wrong_failure",
            "wrong_revision",
            "oversize_unicode_branch",
            "oversize_total"
          ] do
        File.rm(fixture.state_path)
        write_plan!(fixture.plan_path, [5])

        assert {"", 2} =
                 run_watchdog(fixture, restart_limit: 1, receipt_mode: mode)
      end

      assert read_json_lines(fixture.notification_log_path) == []
      assert delivery_receipts(fixture.root) == []
    end)
  end

  @tag skip: if(is_nil(@pwsh), do: "pwsh unavailable", else: false)
  test "pwsh rejects forged receipt fields beyond the shared contract" do
    assert_forged_receipt_boundaries!(@pwsh)
  end

  @tag skip: if(is_nil(@windows_powershell), do: "powershell.exe unavailable", else: false)
  test "Windows PowerShell rejects forged receipt fields beyond the shared contract" do
    assert_forged_receipt_boundaries!(@windows_powershell)
  end

  defp assert_forged_receipt_boundaries!(powershell) do
    with_fixture(fn fixture ->
      for {epoch, changes} <- [
            {"forged-extra-key", %{receiver: "forged"}},
            {"forged-detail-size", %{detail: String.duplicate("x", 8_193)}},
            {"forged-routing-revision", %{routing_revision: 9_223_372_036_854_775_808}},
            {"forged-restart-attempt-zero", %{restart_attempt: 0}},
            {"forged-restart-attempt-overbound", %{restart_attempt: 9_223_372_036_854_775_808}}
          ] do
        seed_terminal_state!(fixture, epoch, 1)
        write_task5_receipt!(fixture.root, epoch, changes)

        assert {"", 2} =
                 run_watchdog(fixture,
                   restart_limit: 1,
                   powershell: powershell
                 )
      end

      assert read_json_lines(fixture.notification_log_path) == []
      assert delivery_receipts(fixture.root) == []
    end)
  end

  @tag skip: if(is_nil(@pwsh), do: "pwsh unavailable", else: false)
  test "pwsh accepts a maximum-combination RuntimeHealth receipt at exact field boundaries" do
    assert_maximum_receipt_runtime!(@pwsh)
  end

  @tag skip: if(is_nil(@windows_powershell), do: "powershell.exe unavailable", else: false)
  test "Windows PowerShell accepts a maximum-combination RuntimeHealth receipt at exact field boundaries" do
    assert_maximum_receipt_runtime!(@windows_powershell)
  end

  defp assert_maximum_receipt_runtime!(powershell) do
    with_fixture(fn fixture ->
      fields = maximum_stop_fields()

      with_runtime_health_receipt(fixture, fields, fn runtime_root, receipt_path, epoch ->
        state_path = Path.join(runtime_root, "watchdog-state.json")
        seed_terminal_state_path!(state_path, epoch, 1)

        assert {"", 1} =
                 run_watchdog(fixture,
                   restart_limit: 1,
                   runtime_root: runtime_root,
                   state_path: state_path,
                   powershell: powershell
                 )

        assert read_json_lines(fixture.notification_log_path) |> length() == 1
        encoded = File.read!(receipt_path)
        receipt = Jason.decode!(encoded)
        assert byte_size(encoded) > 16_384
        assert receipt["detail"] == fields.detail
        assert receipt["routing_revision"] == 9_223_372_036_854_775_807
      end)
    end)
  end

  @tag skip: if(is_nil(@pwsh), do: "pwsh unavailable", else: false)
  test "pwsh honors validated legacy receiver-hash idempotency artifacts" do
    assert_legacy_idempotency_contract!(@pwsh)
  end

  @tag skip: if(is_nil(@windows_powershell), do: "powershell.exe unavailable", else: false)
  test "Windows PowerShell honors validated legacy receiver-hash idempotency artifacts" do
    assert_legacy_idempotency_contract!(@windows_powershell)
  end

  @tag skip: if(is_nil(@pwsh), do: "pwsh unavailable", else: false)
  test "pwsh suppresses notification when the legacy idempotency path is unrepresentable" do
    assert_unrepresentable_legacy_path!(@pwsh)
  end

  @tag skip: if(is_nil(@windows_powershell), do: "powershell.exe unavailable", else: false)
  test "Windows PowerShell suppresses notification when the legacy idempotency path is unrepresentable" do
    assert_unrepresentable_legacy_path!(@windows_powershell)
  end

  defp assert_unrepresentable_legacy_path!(powershell) do
    with_fixture(fn fixture ->
      receiver = "on-call:platform"
      epoch = String.duplicate("e", 128)
      runtime_root = long_runtime_root!(fixture.control_root, powershell)
      state_path = Path.join(runtime_root, "watchdog-state.json")
      expected_exit = if pwsh_on_windows?(powershell), do: 2, else: 1

      assert byte_size(Path.join(runtime_root, "stop-#{epoch}.json")) <= 4_096
      assert byte_size(new_delivery_path(runtime_root, receiver, epoch)) <= 4_096
      assert byte_size(legacy_delivery_path(runtime_root, receiver, epoch)) > 4_096

      seed_terminal_state_path!(state_path, epoch, 1)
      write_task5_receipt!(runtime_root, epoch)

      assert {"", ^expected_exit} =
               run_watchdog(fixture,
                 restart_limit: 1,
                 runtime_root: runtime_root,
                 state_path: state_path,
                 powershell: powershell
               )

      assert read_json_lines(fixture.notification_log_path) == []
      refute File.exists?(new_delivery_path(runtime_root, receiver, epoch))
      refute File.exists?(new_claim_path(runtime_root, receiver, epoch))
    end)
  end

  defp assert_legacy_idempotency_contract!(powershell) do
    with_fixture(fn fixture ->
      receiver = "on-call:platform"

      delivery_epoch = "legacy-delivery-epoch"
      seed_terminal_state!(fixture, delivery_epoch, 1)
      write_task5_receipt!(fixture.root, delivery_epoch)
      write_legacy_delivery!(fixture.root, receiver, delivery_epoch)
      assert {"", 1} = run_watchdog(fixture, restart_limit: 1, powershell: powershell)
      refute File.exists?(new_delivery_path(fixture.root, receiver, delivery_epoch))
      refute File.exists?(new_claim_path(fixture.root, receiver, delivery_epoch))

      claim_epoch = "legacy-claim-epoch"
      seed_terminal_state!(fixture, claim_epoch, 1)
      write_task5_receipt!(fixture.root, claim_epoch)
      write_legacy_claim!(fixture.root, receiver, claim_epoch)
      assert {"", 1} = run_watchdog(fixture, restart_limit: 1, powershell: powershell)
      refute File.exists?(new_delivery_path(fixture.root, receiver, claim_epoch))
      refute File.exists?(new_claim_path(fixture.root, receiver, claim_epoch))

      malformed_epoch = "legacy-malformed-epoch"
      seed_terminal_state!(fixture, malformed_epoch, 1)
      write_task5_receipt!(fixture.root, malformed_epoch)

      write_immutable_json!(legacy_delivery_path(fixture.root, receiver, malformed_epoch), %{
        version: 1,
        delivered: true,
        receiver_hash: String.duplicate("0", 64),
        runtime_epoch: malformed_epoch,
        stop_category: "restart_limit"
      })

      assert {"", 1} = run_watchdog(fixture, restart_limit: 1, powershell: powershell)
      refute File.exists?(new_delivery_path(fixture.root, receiver, malformed_epoch))
      refute File.exists?(new_claim_path(fixture.root, receiver, malformed_epoch))

      collision_epoch = "legacy-collision-epoch"
      seed_terminal_state!(fixture, collision_epoch, 1)
      write_task5_receipt!(fixture.root, collision_epoch)
      File.mkdir!(legacy_delivery_path(fixture.root, receiver, collision_epoch))
      assert {"", 1} = run_watchdog(fixture, restart_limit: 1, powershell: powershell)
      refute File.exists?(new_delivery_path(fixture.root, receiver, collision_epoch))
      refute File.exists?(new_claim_path(fixture.root, receiver, collision_epoch))

      overlong_epoch = "legacy-overlong-epoch"
      seed_terminal_state!(fixture, overlong_epoch, 1)
      write_task5_receipt!(fixture.root, overlong_epoch)

      File.write!(
        legacy_delivery_path(fixture.root, receiver, overlong_epoch),
        String.duplicate("x", 1_025)
      )

      assert {"", 1} = run_watchdog(fixture, restart_limit: 1, powershell: powershell)
      refute File.exists?(new_delivery_path(fixture.root, receiver, overlong_epoch))
      refute File.exists?(new_claim_path(fixture.root, receiver, overlong_epoch))

      assert read_json_lines(fixture.notification_log_path) == []
    end)
  end

  @tag skip: if(is_nil(@pwsh), do: "pwsh unavailable", else: false)
  test "pwsh consumes a RuntimeHealth receipt after offset clock normalization" do
    assert_normalized_timestamp_runtime!(@pwsh)
  end

  @tag skip: if(is_nil(@windows_powershell), do: "powershell.exe unavailable", else: false)
  test "Windows PowerShell consumes a RuntimeHealth receipt after offset clock normalization" do
    assert_normalized_timestamp_runtime!(@windows_powershell)
  end

  defp assert_normalized_timestamp_runtime!(powershell) do
    with_fixture(fn fixture ->
      with_runtime_health_receipt(
        fixture,
        %{category: :unexpected_exit},
        fn runtime_root, receipt_path, epoch ->
          assert Jason.decode!(File.read!(receipt_path))["at"] == "2026-08-29T06:00:00Z"
          state_path = Path.join(runtime_root, "watchdog-state.json")
          seed_terminal_state_path!(state_path, epoch, 1)

          assert {"", 1} =
                   run_watchdog(fixture,
                     restart_limit: 1,
                     runtime_root: runtime_root,
                     state_path: state_path,
                     powershell: powershell
                   )

          assert read_json_lines(fixture.notification_log_path) |> length() == 1
        end,
        clock: fn -> "2026-08-29T14:00:00.999999+08:00" end
      )
    end)
  end

  test "watchdog fails closed while a writable handle mutates the Task 5 receipt during consumption" do
    with_fixture(fn fixture ->
      epoch = "watchdog-write-race"
      seed_terminal_state!(fixture, epoch, 1)
      write_task5_receipt!(fixture.root, epoch)
      ready_path = Path.join(fixture.control_root, "writer.ready")
      release_path = Path.join(fixture.control_root, "writer.release")
      holder = hold_receipt_writable(Path.join(fixture.root, "stop-#{epoch}.json"), ready_path, release_path)

      try do
        assert :ok = wait_for_file(ready_path, 5_000)
        assert {"", 2} = run_watchdog(fixture, restart_limit: 1)
        assert read_json_lines(fixture.notification_log_path) == []
        assert delivery_receipts(fixture.root) == []
      after
        File.write!(release_path, "release")
        assert {"", 0} = Task.await(holder, 5_000)
      end
    end)
  end

  test "an orphaned receiver-hash epoch claim suppresses crash-ambiguous replay" do
    with_fixture(fn fixture ->
      epoch = "watchdog-crash-epoch"
      seed_terminal_state!(fixture, epoch, 1)
      write_task5_receipt!(fixture.root, epoch)
      write_claim!(fixture.root, "on-call:platform", epoch)

      assert {"", 1} = run_watchdog(fixture, restart_limit: 1)
      assert read_json_lines(fixture.notification_log_path) == []
      assert claim_receipts(fixture.root) |> length() == 1
    end)
  end

  test "concurrent terminal watchdogs reserve one receiver-hash epoch side effect" do
    with_fixture(fn fixture ->
      epoch = "watchdog-concurrent-epoch"
      seed_terminal_state!(fixture, epoch, 1)
      write_task5_receipt!(fixture.root, epoch)

      results =
        1..2
        |> Enum.map(fn _index ->
          Task.async(fn ->
            run_watchdog(fixture, restart_limit: 1, notification_delay_ms: 2_000)
          end)
        end)
        |> Task.await_many(10_000)

      assert results == [{"", 1}, {"", 1}]
      assert read_json_lines(fixture.notification_log_path) |> length() == 1
      assert delivery_receipts(fixture.root) |> length() == 1
    end)
  end

  test "notification timeout kills descendants before a retry claim is cleared" do
    with_fixture(fn fixture ->
      marker_path = Path.join(fixture.control_root, "notifier-descendant-survived.txt")
      write_plan!(fixture.plan_path, [6])

      assert {"", 1} =
               run_watchdog(fixture,
                 restart_limit: 1,
                 notification_timeout_ms: 100,
                 notifier_descendant_marker: marker_path
               )

      Process.sleep(800)
      refute File.exists?(marker_path)
      assert claim_receipts(fixture.root) == []
    end)
  end

  test "runtime-state root rejects junction targets even when state uses the physical path" do
    with_fixture(fn fixture ->
      physical_root = Path.join(fixture.control_root, "physical-root")
      junction_root = Path.join(fixture.control_root, "junction-root")
      File.mkdir_p!(physical_root)
      create_directory_link!(physical_root, junction_root)

      try do
        write_plan!(fixture.plan_path, [0])

        assert {"", 2} =
                 run_watchdog(fixture,
                   runtime_root: junction_root,
                   state_path: Path.join(physical_root, "watchdog-state.json")
                 )

        assert read_json_lines(fixture.child_log_path) == []
      after
        _cleanup_link = File.rmdir(junction_root)
      end
    end)
  end

  test "a missing runtime-state root fails closed without creating an unpinned path" do
    with_fixture(fn fixture ->
      missing_root = Path.join(fixture.control_root, "missing-root")
      write_plan!(fixture.plan_path, [0])

      assert {"", 2} =
               run_watchdog(fixture,
                 runtime_root: missing_root,
                 state_path: Path.join(missing_root, "watchdog-state.json")
               )

      refute File.exists?(missing_root)
      assert read_json_lines(fixture.child_log_path) == []
    end)
  end

  test "retained root handle prevents directory replacement during a child attempt" do
    with_fixture(fn fixture ->
      release_path = Path.join(fixture.control_root, "release-child")
      ready_path = release_path <> ".ready"
      moved_root = fixture.root <> "-moved"
      replacement_target = Path.join(fixture.control_root, "replacement-target")
      File.mkdir_p!(replacement_target)
      write_plan!(fixture.plan_path, [7])

      task =
        Task.async(fn ->
          run_watchdog(fixture,
            restart_limit: 1,
            child_block_path: release_path
          )
        end)

      assert :ok = wait_for_file(ready_path, 5_000)
      rename_result = File.rename(fixture.root, moved_root)

      if rename_result == :ok do
        create_directory_link!(replacement_target, fixture.root)
      end

      File.write!(release_path, "release")
      result = Task.await(task, 10_000)

      try do
        assert rename_result in [{:error, :eacces}, {:error, :eperm}, {:error, :einval}]
        assert result == {"", 1}
        assert File.ls!(replacement_target) == []
      after
        if rename_result == :ok do
          _cleanup_link = File.rmdir(fixture.root)
          File.rename(moved_root, fixture.root)
        end
      end
    end)
  end

  test "explicit watchdog state path must stay directly below the validated runtime-state root" do
    with_fixture(fn fixture ->
      outside_state = Path.join(Path.dirname(fixture.root), "outside-watchdog-state.json")
      write_plan!(fixture.plan_path, [0])

      assert {outside_output, 2} = run_watchdog(fixture, state_path: outside_state)
      assert outside_output == ""

      assert {relative_output, 2} =
               run_watchdog(fixture, state_path: "watchdog-state.json", cd: fixture.root)

      assert relative_output == ""

      refute File.exists?(outside_state)
      assert read_json_lines(fixture.child_log_path) == []
    end)
  end

  defp with_fixture(test) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-watchdog-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    control_root = root <> "-control"
    File.mkdir_p!(control_root)

    fixture = %{
      root: root,
      control_root: control_root,
      state_path: Path.join(root, "watchdog-state.json"),
      plan_path: Path.join(root, "child-plan.json"),
      child_log_path: Path.join(root, "child-events.jsonl"),
      notification_log_path: Path.join(root, "notification-events.jsonl"),
      notification_plan_path: Path.join(root, "notification-plan.json"),
      child_script: Path.join(root, "child-fixture.ps1"),
      notification_script: Path.join(root, "notification-fixture.ps1")
    }

    File.write!(fixture.child_script, child_fixture_script())
    File.write!(fixture.notification_script, notification_fixture_script())
    write_plan!(fixture.notification_plan_path, [0])

    try do
      test.(fixture)
    after
      File.rm_rf(root)
      File.rm_rf(control_root)
    end
  end

  defp long_runtime_root!(base, powershell) do
    prefix_bytes = if pwsh_on_windows?(powershell), do: 4, else: 0
    physical_root = grow_path_to_bytes(Path.join(base, "long-runtime-root"), 3_900 - prefix_bytes)
    File.mkdir_p!(physical_root)

    if pwsh_on_windows?(powershell) do
      "\\\\?\\" <> String.replace(physical_root, "/", "\\")
    else
      physical_root
    end
  end

  defp pwsh_on_windows?(powershell) do
    match?({:win32, _}, :os.type()) and
      String.downcase(Path.basename(powershell)) == "pwsh.exe"
  end

  defp grow_path_to_bytes(path, target_bytes) when byte_size(path) >= target_bytes, do: path

  defp grow_path_to_bytes(path, target_bytes) do
    remaining = target_bytes - byte_size(path) - 1
    grow_path_to_bytes(Path.join(path, String.duplicate("x", min(120, remaining))), target_bytes)
  end

  defp run_watchdog(fixture, opts) do
    pwsh = Keyword.get_lazy(opts, :powershell, fn -> elem(powershell_executable(), 1) end)
    state_path = Keyword.get(opts, :state_path, fixture.state_path)
    child_canary = Keyword.get(opts, :child_canary, "")
    notifier_canary = Keyword.get(opts, :notifier_canary, "")
    receipt_mode = Keyword.get(opts, :receipt_mode, "valid")
    child_block_path = Keyword.get(opts, :child_block_path, "")
    descendant_marker = Keyword.get(opts, :notifier_descendant_marker, "")
    notification_delay_ms = Keyword.get(opts, :notification_delay_ms, 0)
    child_canary_base64 = Base.encode64(child_canary)
    notifier_canary_base64 = Base.encode64(notifier_canary)

    child_command =
      Keyword.get_lazy(opts, :child_command, fn ->
        "& #{ps_literal(fixture.child_script)} " <>
          "-PlanPath #{ps_literal(fixture.plan_path)} " <>
          "-LogPath #{ps_literal(fixture.child_log_path)} " <>
          "-CanaryBase64 #{ps_literal(child_canary_base64)} " <>
          "-ReceiptMode #{ps_literal(receipt_mode)} " <>
          "-BlockPath #{ps_literal(child_block_path)}"
      end)

    notification_command =
      "& #{ps_literal(fixture.notification_script)} " <>
        "-LogPath #{ps_literal(fixture.notification_log_path)} " <>
        "-PlanPath #{ps_literal(fixture.notification_plan_path)} " <>
        "-CanaryBase64 #{ps_literal(notifier_canary_base64)} " <>
        "-DescendantMarker #{ps_literal(descendant_marker)} " <>
        "-DelayMs #{notification_delay_ms}"

    runtime_root = Keyword.get(opts, :runtime_root, fixture.root)

    args = [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      @watchdog,
      "-ChildCommand",
      child_command,
      "-RuntimeIdentity",
      Keyword.get(opts, :runtime_identity, "symphony-watchdog-test"),
      "-RuntimeStateRoot",
      runtime_root,
      "-StatePath",
      state_path,
      "-RestartLimit",
      to_string(Keyword.get(opts, :restart_limit, 3)),
      "-NotificationTimeoutMs",
      to_string(Keyword.get(opts, :notification_timeout_ms, 5_000))
    ]

    args =
      case Keyword.get(opts, :notifications, :enabled) do
        :enabled ->
          args ++
            [
              "-NotificationCommand",
              notification_command,
              "-NotificationReceiver",
              "on-call:platform"
            ]

        :disabled ->
          args

        :command_only ->
          args ++ ["-NotificationCommand", notification_command]

        :receiver_only ->
          args ++ ["-NotificationReceiver", "on-call:platform"]
      end

    System.cmd(pwsh, args,
      stderr_to_stdout: true,
      cd: Keyword.get(opts, :cd, File.cwd!())
    )
  end

  defp write_plan!(path, exit_codes) do
    File.write!(path, Jason.encode!(%{index: 0, exit_codes: exit_codes}))
  end

  defp read_json_lines(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end

  defp powershell_executable do
    case System.find_executable("pwsh") || System.find_executable("powershell.exe") do
      nil -> {:error, :powershell_not_found}
      executable -> {:ok, executable}
    end
  end

  defp child_fixture_script do
    oversize_unicode_branch = String.duplicate("🔥", 65)
    oversize_total = String.duplicate("x", 17_000)

    """
    param(
      [Parameter(Mandatory = $true)][string] $PlanPath,
      [Parameter(Mandatory = $true)][string] $LogPath,
      [string] $CanaryBase64 = "",
      [string] $ReceiptMode = "valid",
      [string] $BlockPath = ""
    )
    $ErrorActionPreference = "Stop"
    $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
    $index = [int]$plan.index
    if ($index -ge $plan.exit_codes.Count) { $index = $plan.exit_codes.Count - 1 }
    $status = [int]$plan.exit_codes[$index]
    $plan.index = [int]$plan.index + 1
    [IO.File]::WriteAllText($PlanPath, ($plan | ConvertTo-Json -Compress))
    $event = [ordered]@{
      runtime_epoch = $env:SYMPHONY_RUNTIME_EPOCH
      attempt_count = [int]$env:SYMPHONY_RESTART_ATTEMPT
      receipt_path = $env:SYMPHONY_RUNTIME_RECEIPT_PATH
    }
    [IO.File]::AppendAllText($LogPath, (($event | ConvertTo-Json -Compress) + [Environment]::NewLine))
    if ($BlockPath -ne "") {
      [IO.File]::WriteAllText("$BlockPath.ready", "ready")
      while (-not [IO.File]::Exists($BlockPath)) { Start-Sleep -Milliseconds 20 }
    }
    if ($status -ne 0) {
      $receipt = [ordered]@{
        at = "2026-08-29T06:00:00Z"
        category = "unexpected_exit"
        receipt_path = $env:SYMPHONY_RUNTIME_RECEIPT_PATH
        runtime_epoch = $env:SYMPHONY_RUNTIME_EPOCH
      }
      if ($ReceiptMode -eq "extra_key") { $receipt.receiver = "on-call:platform" }
      if ($ReceiptMode -eq "wrong_timestamp") { $receipt.at = "2026-08-29T06:00:00+00:00" }
      if ($ReceiptMode -eq "wrong_environment") { $receipt.environment = "Local" }
      if ($ReceiptMode -eq "wrong_repository") { $receipt.repository = "not-a-repository" }
      if ($ReceiptMode -eq "wrong_failure") { $receipt.failure_category = "credential_leak" }
      if ($ReceiptMode -eq "wrong_revision") { $receipt.routing_revision = 0 }
      if ($ReceiptMode -eq "oversize_unicode_branch") { $receipt.canonical_branch = "#{oversize_unicode_branch}" }
      if ($ReceiptMode -eq "oversize_total") { $receipt.detail = "#{oversize_total}" }
      if (-not [IO.File]::Exists($env:SYMPHONY_RUNTIME_RECEIPT_PATH)) {
        $temporaryPath = "$($env:SYMPHONY_RUNTIME_RECEIPT_PATH).tmp-$([Guid]::NewGuid().ToString('N'))"
        $stream = [IO.FileStream]::new($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
          $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Compress))
          $stream.Write($bytes, 0, $bytes.Length)
          $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        New-Item -ItemType HardLink -Path $env:SYMPHONY_RUNTIME_RECEIPT_PATH -Target $temporaryPath | Out-Null
        [IO.File]::Delete($temporaryPath)
      }
    }
    $Canary = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CanaryBase64))
    if ($Canary -ne "") {
      Write-Output "$Canary $env:SYMPHONY_RUNTIME_EPOCH $env:SYMPHONY_RUNTIME_RECEIPT_PATH"
      [Console]::Error.WriteLine("$Canary $env:SYMPHONY_RUNTIME_STATE_ROOT")
    }
    exit $status
    """
  end

  defp notification_fixture_script do
    """
    param(
      [Parameter(Mandatory = $true)][string] $LogPath,
      [Parameter(Mandatory = $true)][string] $PlanPath,
      [string] $CanaryBase64 = "",
      [string] $DescendantMarker = "",
      [int] $DelayMs = 0
    )
    $line = [Console]::In.ReadLine()
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    [IO.File]::AppendAllText($LogPath, ($line + [Environment]::NewLine))
    $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
    $index = [int]$plan.index
    if ($index -ge $plan.exit_codes.Count) { $index = $plan.exit_codes.Count - 1 }
    $status = [int]$plan.exit_codes[$index]
    $plan.index = [int]$plan.index + 1
    [IO.File]::WriteAllText($PlanPath, ($plan | ConvertTo-Json -Compress))
    if ($DescendantMarker -ne "") {
      $child = "Start-Sleep -Milliseconds 500; [IO.File]::WriteAllText('$($DescendantMarker.Replace("'", "''"))', 'survived')"
      $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
      Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encodedChild | Out-Null
      Start-Sleep -Seconds 5
    }
    $Canary = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CanaryBase64))
    if ($Canary -ne "") {
      Write-Output $Canary
      [Console]::Error.WriteLine($Canary)
    }
    exit $status
    """
  end

  defp delivery_receipts(root) do
    root
    |> File.ls!()
    |> Enum.filter(&(String.starts_with?(&1, "restart-limit-delivery-") and String.ends_with?(&1, ".json")))
  end

  defp claim_receipts(root) do
    root
    |> File.ls!()
    |> Enum.filter(&(String.starts_with?(&1, "restart-limit-claim-") and String.ends_with?(&1, ".json")))
  end

  defp seed_terminal_state!(fixture, epoch, attempt_count) do
    seed_terminal_state_path!(fixture.state_path, epoch, attempt_count)
  end

  defp seed_terminal_state_path!(state_path, epoch, attempt_count) do
    File.write!(
      state_path,
      Jason.encode!(%{
        version: 1,
        runtime_epoch: epoch,
        attempt_count: attempt_count,
        receiver_hash: receiver_hash("on-call:platform"),
        runtime_identity: "symphony-watchdog-test",
        terminal_timestamp: "2026-08-29T06:00:00Z"
      })
    )
  end

  defp with_runtime_health_receipt(fixture, fields, test, opts \\ []) do
    receipt_root = Path.join(fixture.control_root, "health-receipts")
    workspace_root = Path.join(fixture.control_root, "health-workspaces")
    epoch = String.duplicate("e", 128)
    File.mkdir_p!(workspace_root)

    {:ok, health} =
      RuntimeHealth.start_link(
        name: nil,
        clock: Keyword.get(opts, :clock, fn -> ~U[2026-08-29 06:00:00Z] end),
        runtime_epoch: epoch,
        receipt_root: receipt_root,
        workspace_root: workspace_root
      )

    try do
      assert :ok = RuntimeHealth.stop(health, fields)
      receipt_path = RuntimeHealth.snapshot(health).final_stop.receipt_path
      test.(Path.dirname(receipt_path), receipt_path, epoch)
    after
      GenServer.stop(health)
    end
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

  defp hold_receipt_writable(receipt_path, ready_path, release_path) do
    {:ok, powershell} = powershell_executable()

    command = """
    $stream = [IO.FileStream]::new(
      #{ps_literal(receipt_path)},
      [IO.FileMode]::Open,
      [IO.FileAccess]::ReadWrite,
      [IO.FileShare]::ReadWrite
    )
    try {
      [IO.File]::WriteAllText(#{ps_literal(ready_path)}, 'ready')
      while (-not [IO.File]::Exists(#{ps_literal(release_path)})) {
        $stream.Position = 0
        $stream.WriteByte(123)
        $stream.Flush()
        Start-Sleep -Milliseconds 10
      }
    }
    finally { $stream.Dispose() }
    """

    Task.async(fn ->
      System.cmd(powershell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command], stderr_to_stdout: true)
    end)
  end

  defp write_task5_receipt!(root, epoch, changes \\ %{}) do
    receipt_path = Path.join(root, "stop-#{epoch}.json")

    receipt =
      Map.merge(
        %{
          at: "2026-08-29T06:00:00Z",
          category: "unexpected_exit",
          receipt_path: receipt_path,
          runtime_epoch: epoch
        },
        changes
      )

    write_immutable_json!(receipt_path, receipt)
  end

  defp write_claim!(root, receiver, epoch) do
    receiver_hash = receiver_hash(receiver)

    write_immutable_json!(
      Path.join(root, "restart-limit-claim-#{notification_key(receiver_hash, epoch)}.json"),
      %{
        version: 1,
        state: "inflight",
        receiver_hash: receiver_hash,
        runtime_epoch: epoch,
        stop_category: "restart_limit"
      }
    )
  end

  defp write_legacy_claim!(root, receiver, epoch) do
    write_immutable_json!(
      legacy_claim_path(root, receiver, epoch),
      %{
        version: 1,
        state: "inflight",
        receiver_hash: receiver_hash(receiver),
        runtime_epoch: epoch,
        stop_category: "restart_limit"
      }
    )
  end

  defp write_legacy_delivery!(root, receiver, epoch) do
    write_immutable_json!(
      legacy_delivery_path(root, receiver, epoch),
      %{
        version: 1,
        delivered: true,
        receiver_hash: receiver_hash(receiver),
        runtime_epoch: epoch,
        stop_category: "restart_limit"
      }
    )
  end

  defp legacy_claim_path(root, receiver, epoch) do
    Path.join(root, "restart-limit-claim-#{receiver_hash(receiver)}-#{epoch}.json")
  end

  defp legacy_delivery_path(root, receiver, epoch) do
    Path.join(root, "restart-limit-delivery-#{receiver_hash(receiver)}-#{epoch}.json")
  end

  defp new_claim_path(root, receiver, epoch) do
    Path.join(root, "restart-limit-claim-#{notification_key(receiver_hash(receiver), epoch)}.json")
  end

  defp new_delivery_path(root, receiver, epoch) do
    Path.join(root, "restart-limit-delivery-#{notification_key(receiver_hash(receiver), epoch)}.json")
  end

  defp write_immutable_json!(path, value) do
    temporary_path = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"
    encoded = Jason.encode!(value)
    {:ok, file} = File.open(temporary_path, [:write, :binary, :exclusive])

    try do
      :ok = IO.binwrite(file, encoded)
      :ok = :file.sync(file)
    after
      File.close(file)
    end

    :ok = File.ln(temporary_path, path)
    :ok = File.rm(temporary_path)
  end

  defp wait_for_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_file_until(path, deadline)
  end

  defp wait_for_file_until(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(20)
        wait_for_file_until(path, deadline)
    end
  end

  defp receiver_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp notification_key(receiver_hash, epoch) do
    :crypto.hash(:sha256, receiver_hash <> ":" <> epoch)
    |> Base.encode16(case: :lower)
  end

  defp ps_literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp same_path?(left, right) do
    normalize = fn path -> path |> Path.expand() |> String.replace("\\", "/") |> String.downcase() end
    normalize.(left) == normalize.(right)
  end
end
