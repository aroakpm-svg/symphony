defmodule SymphonyElixir.RuntimeNotifierTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema.Observability
  alias SymphonyElixir.{RuntimeHealth, RuntimeNotifier}

  @timestamp "2026-08-29T06:00:00Z"

  test "delivers the fixed restart-limit event as one JSON line on stdin" do
    with_runtime_root(fn root ->
      input_path = Path.join(root, "notification-input.json")
      config = config(root, success_command(input_path))
      event = event(root, "epoch-success")

      assert :ok = RuntimeNotifier.notify_restart_limit(config, event)

      assert %{
               "runtime_identity" => "symphony-local",
               "receiver" => "on-call:platform",
               "attempt_count" => 3,
               "stop_category" => "restart_limit",
               "timestamp" => @timestamp,
               "runtime_epoch" => "epoch-success",
               "receipt_path" => receipt_path
             } = Jason.decode!(File.read!(input_path))

      assert receipt_path == Path.join(root, "stop-epoch-success.json")
      assert [delivery_name] = delivery_receipts(root)

      assert delivery_name ==
               Path.basename(new_delivery_path(root, "on-call:platform", "epoch-success"))

      refute File.exists?(legacy_delivery_path(root, "on-call:platform", "epoch-success"))

      delivery = root |> Path.join(delivery_name) |> File.read!() |> Jason.decode!()
      assert delivery["receiver_hash"] == receiver_hash("on-call:platform")
      refute Map.has_key?(delivery, "receiver")
      refute File.read!(Path.join(root, delivery_name)) =~ "on-call:platform"
      refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".restart-limit-"))
    end)
  end

  test "times out without recording delivery" do
    with_runtime_root(fn root ->
      config = config(root, timeout_command(), notification_timeout_ms: 25)

      assert {:error, :notification_timeout} =
               RuntimeNotifier.notify_restart_limit(config, event(root, "epoch-timeout"))

      assert delivery_receipts(root) == []
    end)
  end

  test "returns a bounded error for non-zero exit and records no delivery" do
    with_runtime_root(fn root ->
      config = config(root, failure_command(23))

      assert {:error, :notification_failed} =
               RuntimeNotifier.notify_restart_limit(config, event(root, "epoch-failed"))

      assert delivery_receipts(root) == []
    end)
  end

  test "fails closed when the receiver is missing" do
    with_runtime_root(fn root ->
      config = %{config(root, success_command(Path.join(root, "unexpected.json"))) | notification_receiver: nil}

      assert {:error, :notification_not_configured} =
               RuntimeNotifier.notify_restart_limit(config, event(root, "epoch-no-receiver"))

      refute File.exists?(Path.join(root, "unexpected.json"))
      assert delivery_receipts(root) == []
    end)
  end

  test "same receiver and epoch replay is idempotent" do
    with_runtime_root(fn root ->
      counter_path = Path.join(root, "notification-count.txt")
      config = config(root, increment_command(counter_path))
      event = event(root, "epoch-replay")

      assert :ok = RuntimeNotifier.notify_restart_limit(config, event)
      assert :ok = RuntimeNotifier.notify_restart_limit(config, event)

      assert File.read!(counter_path) == "1"
      assert delivery_receipts(root) |> length() == 1
      refute Enum.any?(delivery_receipts(root), &String.contains?(&1, "on-call"))
    end)
  end

  test "a valid legacy delivery suppresses a new hashed notification" do
    with_runtime_root(fn root ->
      epoch = "epoch-legacy-delivery"
      output_path = Path.join(root, "unexpected-legacy-delivery.json")
      notification_event = event(root, epoch)
      write_legacy_delivery!(root, "on-call:platform", epoch)

      assert :ok =
               RuntimeNotifier.notify_restart_limit(
                 config(root, success_command(output_path)),
                 notification_event
               )

      refute File.exists?(output_path)
      refute File.exists?(new_delivery_path(root, "on-call:platform", epoch))
      refute File.exists?(new_claim_path(root, "on-call:platform", epoch))
    end)
  end

  test "a valid legacy orphan claim preserves crash ambiguity" do
    with_runtime_root(fn root ->
      epoch = "epoch-legacy-claim"
      output_path = Path.join(root, "unexpected-legacy-claim.json")
      notification_event = event(root, epoch)
      write_legacy_claim!(root, "on-call:platform", epoch)

      assert {:error, :notification_delivery_ambiguous} =
               RuntimeNotifier.notify_restart_limit(
                 config(root, success_command(output_path)),
                 notification_event
               )

      refute File.exists?(output_path)
      refute File.exists?(new_delivery_path(root, "on-call:platform", epoch))
      refute File.exists?(new_claim_path(root, "on-call:platform", epoch))
    end)
  end

  test "an unrepresentable legacy path preserves delivery ambiguity" do
    with_runtime_root(fn base ->
      epoch = String.duplicate("e", 128)
      root = long_runtime_root!(base)
      output_path = Path.join(base, "unexpected-unrepresentable-legacy.json")

      assert byte_size(Path.join(root, "stop-#{epoch}.json")) <= 4_096
      assert byte_size(new_delivery_path(root, "on-call:platform", epoch)) <= 4_096
      assert byte_size(legacy_delivery_path(root, "on-call:platform", epoch)) > 4_096

      assert {:error, :notification_delivery_ambiguous} =
               RuntimeNotifier.notify_restart_limit(
                 config(root, success_command(output_path)),
                 event(root, epoch)
               )

      refute File.exists?(output_path)
      refute File.exists?(new_delivery_path(root, "on-call:platform", epoch))
      refute File.exists?(new_claim_path(root, "on-call:platform", epoch))
    end)
  end

  test "malformed colliding and overlong legacy artifacts fail closed" do
    with_runtime_root(fn root ->
      cases = [
        {"legacy-malformed-delivery",
         fn path ->
           write_immutable_json!(path, %{
             version: 1,
             delivered: true,
             receiver_hash: String.duplicate("0", 64),
             runtime_epoch: "legacy-malformed-delivery",
             stop_category: "restart_limit"
           })
         end},
        {"legacy-malformed-claim",
         fn path ->
           write_immutable_json!(path, %{
             version: 1,
             state: "inflight",
             receiver_hash: receiver_hash("on-call:platform"),
             runtime_epoch: "other-epoch",
             stop_category: "restart_limit"
           })
         end},
        {"legacy-path-collision", fn path -> File.mkdir!(path) end},
        {"legacy-overlong-artifact",
         fn path ->
           File.write!(path, String.duplicate("x", 1_025))
         end}
      ]

      for {epoch, seed_artifact} <- cases do
        output_path = Path.join(root, "unexpected-#{epoch}.json")
        notification_event = event(root, epoch)

        legacy_path =
          if epoch == "legacy-malformed-claim" do
            legacy_claim_path(root, "on-call:platform", epoch)
          else
            legacy_delivery_path(root, "on-call:platform", epoch)
          end

        seed_artifact.(legacy_path)

        assert {:error, :invalid_delivery_receipt} =
                 RuntimeNotifier.notify_restart_limit(
                   config(root, success_command(output_path)),
                   notification_event
                 )

        refute File.exists?(output_path)
        refute File.exists?(new_delivery_path(root, "on-call:platform", epoch))
        refute File.exists?(new_claim_path(root, "on-call:platform", epoch))
      end
    end)
  end

  test "distinct epochs deliver independently" do
    with_runtime_root(fn root ->
      counter_path = Path.join(root, "notification-count.txt")
      config = config(root, increment_command(counter_path))

      assert :ok = RuntimeNotifier.notify_restart_limit(config, event(root, "epoch-one"))
      assert :ok = RuntimeNotifier.notify_restart_limit(config, event(root, "epoch-two"))

      assert File.read!(counter_path) == "2"
      assert delivery_receipts(root) |> length() == 2
    end)
  end

  test "never returns, logs, or prints notification command output" do
    with_runtime_root(fn root ->
      canary = "CANARY_SECRET_FROM_NOTIFIER_OUTPUT"
      config = config(root, output_command(canary, 0))

      result =
        capture_log(fn ->
          output =
            capture_io(fn ->
              error_output =
                capture_io(:stderr, fn ->
                  send(self(), {:result, RuntimeNotifier.notify_restart_limit(config, event(root, "epoch-canary"))})
                end)

              send(self(), {:error_output, error_output})
            end)

          send(self(), {:output, output})
        end)

      assert_receive {:result, :ok}
      assert_receive {:error_output, error_output}
      assert_receive {:output, output}

      refute result =~ canary
      refute output =~ canary
      refute error_output =~ canary
      assert delivery_receipts(root) |> length() == 1
    end)
  end

  test "rejects a receipt path that is not the immutable stop receipt for the epoch" do
    with_runtime_root(fn root ->
      config = config(root, success_command(Path.join(root, "unexpected.json")))
      unsafe_event = %{event(root, "epoch-path") | receipt_path: Path.join(root, "stop-other.json")}

      assert {:error, :invalid_stop_receipt} =
               RuntimeNotifier.notify_restart_limit(config, unsafe_event)

      refute File.exists?(Path.join(root, "unexpected.json"))
    end)
  end

  test "rejects secret-bearing runtime identities before command execution" do
    with_runtime_root(fn root ->
      for {identity, epoch} <- [
            {"token:canary", "identity-token"},
            {"sk-proj-abcdefghijklmnop", "identity-prefix"}
          ] do
        output_path = Path.join(root, "unexpected-#{epoch}.json")
        config = config(root, success_command(output_path))
        unsafe_event = %{event(root, epoch) | runtime_identity: identity}

        assert {:error, :invalid_notification_event} =
                 RuntimeNotifier.notify_restart_limit(config, unsafe_event)

        refute File.exists?(output_path)
      end
    end)
  end

  test "requires the bounded immutable Task 5 receipt contract" do
    with_runtime_root(fn root ->
      invalid_receipts = [
        {"wrong-path", %{"receipt_path" => Path.join(root, "stop-other.json")}},
        {"wrong-timestamp", %{"at" => "2026-08-29T06:00:00+00:00"}},
        {"wrong-category", %{"category" => "operator_defined"}},
        {"extra-key", %{"receiver" => "on-call:platform"}},
        {"wrong-environment", %{"environment" => "Local"}},
        {"wrong-repository", %{"repository" => "not-a-repository"}},
        {"wrong-failure", %{"failure_category" => "credential_leak"}},
        {"wrong-revision", %{"routing_revision" => 0}},
        {"overbound-revision", %{"routing_revision" => 9_223_372_036_854_775_808}},
        {"wrong-restart-attempt", %{"restart_attempt" => 0}},
        {"overbound-restart-attempt", %{"restart_attempt" => 9_223_372_036_854_775_808}},
        {"oversize-unicode-branch", %{"canonical_branch" => String.duplicate("🔥", 65)}},
        {"oversize-detail", %{"detail" => String.duplicate("x", 8_193)}},
        {"oversize-total", %{"detail" => String.duplicate("x", 17_000)}},
        {"missing-at", %{drop: "at"}}
      ]

      for {epoch, receipt_changes} <- invalid_receipts do
        output_path = Path.join(root, "unexpected-#{epoch}.json")
        config = config(root, success_command(output_path))
        invalid_event = event(root, epoch, receipt_changes)

        assert {:error, :invalid_stop_receipt} =
                 RuntimeNotifier.notify_restart_limit(config, invalid_event)

        refute File.exists?(output_path)
      end
    end)
  end

  test "accepts a maximum-combination RuntimeHealth receipt at exact field boundaries" do
    fields = maximum_stop_fields()

    with_runtime_health_receipt(fields, fn runtime_root, receipt_path, epoch ->
      output_path = Path.join(runtime_root, "runtime-health-event.json")

      assert :ok =
               RuntimeNotifier.notify_restart_limit(
                 config(runtime_root, success_command(output_path)),
                 notification_event(receipt_path, epoch)
               )

      assert File.exists?(output_path)
      encoded = File.read!(receipt_path)
      receipt = Jason.decode!(encoded)
      assert byte_size(encoded) > 16_384
      assert receipt["detail"] == fields.detail
      assert receipt["routing_revision"] == 9_223_372_036_854_775_807
    end)
  end

  test "accepts a RuntimeHealth receipt after offset clock normalization" do
    with_runtime_health_receipt(
      %{category: :unexpected_exit},
      fn runtime_root, receipt_path, epoch ->
        output_path = Path.join(runtime_root, "normalized-timestamp-event.json")
        assert Jason.decode!(File.read!(receipt_path))["at"] == @timestamp

        assert :ok =
                 RuntimeNotifier.notify_restart_limit(
                   config(runtime_root, success_command(output_path)),
                   notification_event(receipt_path, epoch)
                 )

        assert File.exists?(output_path)
      end,
      clock: fn -> "2026-08-29T14:00:00.999999+08:00" end
    )
  end

  test "accepts the watchdog restart attempt on the shared RuntimeHealth receipt" do
    with_runtime_health_receipt(
      %{category: :unexpected_exit},
      fn runtime_root, receipt_path, epoch ->
        output_path = Path.join(runtime_root, "watchdog-attempt-event.json")
        assert Jason.decode!(File.read!(receipt_path))["restart_attempt"] == 3

        assert :ok =
                 RuntimeNotifier.notify_restart_limit(
                   config(runtime_root, success_command(output_path)),
                   notification_event(receipt_path, epoch)
                 )

        assert File.exists?(output_path)
      end,
      restart_attempt: 3
    )
  end

  @tag skip:
         if(match?({:win32, _}, :os.type()),
           do: false,
           else: "POSIX public OTP cannot attest another same-UID writable handle"
         )
  test "fails closed while a writable handle mutates the Task 5 receipt during consumption" do
    with_runtime_root(fn root ->
      epoch = "epoch-write-race"
      notification_event = event(root, epoch)
      ready_path = Path.join(root, "writer.ready")
      release_path = Path.join(root, "writer.release")
      holder = hold_receipt_writable(notification_event.receipt_path, ready_path, release_path)

      try do
        assert :ok = wait_for_file(ready_path, 5_000)

        assert {:error, :invalid_stop_receipt} =
                 RuntimeNotifier.notify_restart_limit(
                   config(root, success_command(Path.join(root, "unexpected-race.json"))),
                   notification_event
                 )

        refute File.exists?(Path.join(root, "unexpected-race.json"))
      after
        File.write!(release_path, "release")
        assert {"", 0} = Task.await(holder, 5_000)
      end
    end)
  end

  test "removes runner material when the injected command port opener fails or raises" do
    with_runtime_root(fn root ->
      previous_opener = Application.get_env(:symphony_elixir, :runtime_notifier_port_opener)

      on_exit(fn ->
        if is_nil(previous_opener) do
          Application.delete_env(:symphony_elixir, :runtime_notifier_port_opener)
        else
          Application.put_env(:symphony_elixir, :runtime_notifier_port_opener, previous_opener)
        end
      end)

      for {suffix, opener} <- [
            {"error", fn _target, _options -> {:error, :injected} end},
            {"raise", fn _target, _options -> raise "injected opener failure" end}
          ] do
        canary = "COMMAND_MATERIAL_CANARY_#{suffix}"

        Application.put_env(:symphony_elixir, :runtime_notifier_port_opener, opener)

        assert {:error, :notification_delivery_ambiguous} =
                 RuntimeNotifier.notify_restart_limit(
                   config(root, "$null = '#{canary}'; exit 0"),
                   event(root, "epoch-opener-#{suffix}")
                 )

        refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".restart-limit-runner-"))

        root
        |> File.ls!()
        |> Enum.each(fn name -> refute File.read!(Path.join(root, name)) =~ canary end)
      end
    end)
  end

  test "command ports clear ambient secrets and retain only runtime allowlist keys" do
    with_runtime_root(fn root ->
      previous_opener = Application.get_env(:symphony_elixir, :runtime_notifier_port_opener)
      previous_secret = System.get_env("LINEAR_API_KEY")
      owner = self()

      on_exit(fn ->
        if is_nil(previous_opener) do
          Application.delete_env(:symphony_elixir, :runtime_notifier_port_opener)
        else
          Application.put_env(:symphony_elixir, :runtime_notifier_port_opener, previous_opener)
        end

        restore_env("LINEAR_API_KEY", previous_secret)
      end)

      System.put_env("LINEAR_API_KEY", "ambient-notifier-secret")

      Application.put_env(
        :symphony_elixir,
        :runtime_notifier_port_opener,
        fn _target, options ->
          send(owner, {:port_options, options})
          {:error, :injected}
        end
      )

      assert {:error, :notification_delivery_ambiguous} =
               RuntimeNotifier.notify_restart_limit(
                 config(root, success_command(Path.join(root, "unexpected.json"))),
                 event(root, "epoch-isolated-environment")
               )

      assert_receive {:port_options, options}
      environment = options |> Keyword.fetch!(:env) |> Map.new()

      assert environment[~c"LINEAR_API_KEY"] == false
      assert is_list(environment[~c"PATH"])
      assert is_list(environment[~c"SYMPHONY_TASK6_EVENT_B64"])
    end)
  end

  test "concurrent receiver and epoch calls reserve before the notification side effect" do
    with_runtime_root(fn root ->
      log_path = Path.join(root, "notification-calls.jsonl")
      config = config(root, delayed_append_command(log_path, 300))
      notification_event = event(root, "epoch-concurrent")

      results =
        1..2
        |> Enum.map(fn _index ->
          Task.async(fn -> RuntimeNotifier.notify_restart_limit(config, notification_event) end)
        end)
        |> Task.await_many(20_000)

      assert Enum.count(results, &(&1 == :ok)) == 1

      assert Enum.count(results, &(&1 == {:error, :notification_delivery_ambiguous})) ==
               1

      assert log_path |> File.read!() |> String.split(~r/\R/, trim: true) |> length() == 1
    end)
  end

  test "an orphaned inflight claim is crash-ambiguous and never replays the side effect" do
    with_runtime_root(fn root ->
      epoch = "epoch-crash-window"
      output_path = Path.join(root, "unexpected-crash-replay.json")
      config = config(root, success_command(output_path))
      notification_event = event(root, epoch)
      write_claim!(root, "on-call:platform", epoch)

      assert {:error, :notification_delivery_ambiguous} =
               RuntimeNotifier.notify_restart_limit(config, notification_event)

      refute File.exists?(output_path)
      assert claim_receipts(root) |> length() == 1
    end)
  end

  test "verified non-zero termination clears the claim and permits one safe retry" do
    with_runtime_root(fn root ->
      epoch = "epoch-safe-retry"
      observed_claim_path = Path.join(root, "claim-observed.txt")
      notification_event = event(root, epoch)

      assert {:error, :notification_failed} =
               RuntimeNotifier.notify_restart_limit(
                 config(root, observe_claim_and_fail_command(root, observed_claim_path, epoch)),
                 notification_event
               )

      assert File.read!(observed_claim_path) == "present"
      assert claim_receipts(root) == []

      success_path = Path.join(root, "safe-retry.json")

      assert :ok =
               RuntimeNotifier.notify_restart_limit(
                 config(root, success_command(success_path)),
                 notification_event
               )

      assert File.exists?(success_path)
      assert delivery_receipts(root) |> length() == 1
    end)
  end

  test "timeout terminates notifier descendants before clearing the retry claim" do
    with_runtime_root(fn root ->
      marker_path = Path.join(root, "descendant-survived.txt")

      assert {:error, :notification_timeout} =
               RuntimeNotifier.notify_restart_limit(
                 config(root, descendant_timeout_command(marker_path), notification_timeout_ms: 100),
                 event(root, "epoch-descendant-timeout")
               )

      Process.sleep(800)
      refute File.exists?(marker_path)
      assert claim_receipts(root) == []
    end)
  end

  defp with_runtime_root(test) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runtime-notifier-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    try do
      test.(root)
    after
      File.rm_rf(root)
    end
  end

  defp long_runtime_root!(base) do
    root = grow_path_to_bytes(Path.join(base, "long-runtime-root"), 3_900)
    File.mkdir_p!(root)
    root
  end

  defp grow_path_to_bytes(path, target_bytes) when byte_size(path) >= target_bytes, do: path

  defp grow_path_to_bytes(path, target_bytes) do
    remaining = target_bytes - byte_size(path) - 1
    grow_path_to_bytes(Path.join(path, String.duplicate("x", min(120, remaining))), target_bytes)
  end

  defp config(root, command, overrides \\ []) do
    struct!(
      Observability,
      Keyword.merge(
        [
          runtime_state_root: root,
          notification_command: command,
          notification_receiver: "on-call:platform",
          restart_limit: 3,
          notification_timeout_ms: 15_000
        ],
        overrides
      )
    )
  end

  defp event(root, epoch, receipt_changes \\ %{}) do
    receipt_path = Path.join(root, "stop-#{epoch}.json")

    receipt = %{
      "at" => @timestamp,
      "category" => "unexpected_exit",
      "receipt_path" => receipt_path,
      "runtime_epoch" => epoch
    }

    receipt =
      case Map.pop(receipt_changes, :drop) do
        {nil, changes} -> Map.merge(receipt, changes)
        {key, changes} -> receipt |> Map.delete(key) |> Map.merge(changes)
      end

    write_immutable_json!(receipt_path, receipt)

    %{
      runtime_identity: "symphony-local",
      attempt_count: 3,
      timestamp: @timestamp,
      runtime_epoch: epoch,
      receipt_path: receipt_path
    }
  end

  defp notification_event(receipt_path, epoch) do
    %{
      runtime_identity: "symphony-local",
      attempt_count: 3,
      timestamp: @timestamp,
      runtime_epoch: epoch,
      receipt_path: receipt_path
    }
  end

  defp with_runtime_health_receipt(fields, test, opts \\ []) do
    base =
      Path.join(
        System.tmp_dir!(),
        "symphony-runtime-notifier-health-#{System.unique_integer([:positive])}"
      )

    receipt_root = Path.join(base, "receipts")
    workspace_root = Path.join(base, "workspaces")
    epoch = String.duplicate("e", 128)
    File.mkdir_p!(workspace_root)

    {:ok, health} =
      RuntimeHealth.start_link(
        name: nil,
        clock: Keyword.get(opts, :clock, fn -> ~U[2026-08-29 06:00:00Z] end),
        runtime_epoch: epoch,
        restart_attempt: Keyword.get(opts, :restart_attempt),
        receipt_root: receipt_root,
        workspace_root: workspace_root
      )

    try do
      assert :ok = RuntimeHealth.stop(health, fields)
      receipt_path = RuntimeHealth.snapshot(health).final_stop.receipt_path
      test.(Path.dirname(receipt_path), receipt_path, epoch)
    after
      GenServer.stop(health)
      File.rm_rf(base)
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

  defp wait_for_file(path, remaining_ms) when remaining_ms <= 0 do
    if File.exists?(path), do: :ok, else: {:error, :timeout}
  end

  defp wait_for_file(path, remaining_ms) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      wait_for_file(path, remaining_ms - 20)
    end
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

  defp write_claim!(root, receiver, epoch) do
    receiver_hash = receiver_hash(receiver)
    path = Path.join(root, "restart-limit-claim-#{notification_key(receiver_hash, epoch)}.json")

    write_immutable_json!(path, %{
      version: 1,
      state: "inflight",
      receiver_hash: receiver_hash,
      runtime_epoch: epoch,
      stop_category: "restart_limit"
    })
  end

  defp write_legacy_claim!(root, receiver, epoch) do
    write_immutable_json!(legacy_claim_path(root, receiver, epoch), %{
      version: 1,
      state: "inflight",
      receiver_hash: receiver_hash(receiver),
      runtime_epoch: epoch,
      stop_category: "restart_limit"
    })
  end

  defp write_legacy_delivery!(root, receiver, epoch) do
    write_immutable_json!(legacy_delivery_path(root, receiver, epoch), %{
      version: 1,
      delivered: true,
      receiver_hash: receiver_hash(receiver),
      runtime_epoch: epoch,
      stop_category: "restart_limit"
    })
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

  defp success_command(path) do
    "$payload = [Console]::In.ReadToEnd(); " <>
      "[IO.File]::WriteAllText(#{ps_literal(path)}, $payload.Trim()); exit 0"
  end

  defp timeout_command do
    "$null = [Console]::In.ReadToEnd(); Start-Sleep -Milliseconds 500; exit 0"
  end

  defp failure_command(status) do
    "$null = [Console]::In.ReadToEnd(); exit #{status}"
  end

  defp increment_command(path) do
    "$null = [Console]::In.ReadToEnd(); $path = #{ps_literal(path)}; " <>
      "$count = if (Test-Path -LiteralPath $path) { [int][IO.File]::ReadAllText($path) } else { 0 }; " <>
      "[IO.File]::WriteAllText($path, [string]($count + 1)); exit 0"
  end

  defp delayed_append_command(path, delay_ms) do
    "$null = [Console]::In.ReadToEnd(); Start-Sleep -Milliseconds #{delay_ms}; " <>
      "[IO.File]::AppendAllText(#{ps_literal(path)}, \"called`n\"); exit 0"
  end

  defp observe_claim_and_fail_command(root, observed_path, epoch) do
    receiver_hash = receiver_hash("on-call:platform")

    claim_path =
      Path.join(
        root,
        "restart-limit-claim-#{notification_key(receiver_hash, epoch)}.json"
      )

    "$null = [Console]::In.ReadToEnd(); " <>
      "$observed = if (Test-Path -LiteralPath #{ps_literal(claim_path)}) { 'present' } else { 'missing' }; " <>
      "[IO.File]::WriteAllText(#{ps_literal(observed_path)}, $observed); exit 23"
  end

  defp descendant_timeout_command(marker_path) do
    child_command =
      "Start-Sleep -Milliseconds 500; " <>
        "[IO.File]::WriteAllText(#{ps_literal(marker_path)}, 'survived')"

    encoded_child = child_command |> :unicode.characters_to_binary(:utf8, {:utf16, :little}) |> Base.encode64()

    "$null = [Console]::In.ReadToEnd(); " <>
      "Start-Process -FilePath (Get-Process -Id $PID).Path " <>
      "-ArgumentList '-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand','#{encoded_child}' | Out-Null; " <>
      "Start-Sleep -Seconds 5; exit 0"
  end

  defp output_command(canary, status) do
    encoded = Base.encode64(canary)

    "$null = [Console]::In.ReadToEnd(); $value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(#{ps_literal(encoded)})); " <>
      "[Console]::Out.WriteLine($value); [Console]::Error.WriteLine($value); exit #{status}"
  end

  defp powershell_executable do
    case System.find_executable("pwsh") || System.find_executable("powershell.exe") do
      nil -> {:error, :powershell_not_found}
      executable -> {:ok, executable}
    end
  end

  defp ps_literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp receiver_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp notification_key(receiver_hash, epoch) do
    :crypto.hash(:sha256, receiver_hash <> ":" <> epoch)
    |> Base.encode16(case: :lower)
  end
end
