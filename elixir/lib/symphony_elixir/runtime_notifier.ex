defmodule SymphonyElixir.RuntimeNotifier do
  @moduledoc """
  Delivers one bounded local restart-limit notification per receiver and runtime epoch.
  """

  alias SymphonyElixir.Config.Schema.Observability
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.RuntimeReceiptContract

  @event_keys [:attempt_count, :receipt_path, :runtime_epoch, :runtime_identity, :timestamp]
  @stop_receipt_required_keys ["at", "category", "receipt_path", "runtime_epoch"]
  @stop_receipt_optional_keys [
    "canonical_branch",
    "detail",
    "environment",
    "failure_category",
    "issue_id",
    "issue_identifier",
    "profile_key",
    "repository",
    "restart_attempt",
    "routing_revision",
    "workspace_namespace"
  ]
  @stop_categories ["normal_shutdown", "startup_failure", "unexpected_exit", "restart_limit"]
  @max_idempotency_receipt_bytes 1_024
  @max_portable_filename_bytes 255
  @max_portable_path_bytes 4_096
  @failure_categories ~w(
    callback_exception callback_failure candidate_fetch_failed claim_rejected
    claim_service_unavailable claim_timeout default_branch_mismatch default_branch_unresolvable
    dispatch_exception dispatch_failure inactive_state linear_forbidden linear_identity_missing
    linear_response_invalid linear_unauthorized linear_workspace_mismatch linear_unavailable missing missing_routing
    missing_worker_label non_exclusive_routing poll_error poll_timeout preflight_unavailable
    project_changed project_mapping_missing refresh_unavailable repository_metadata_invalid
    repository_mismatch repository_unavailable required_check_contract_invalid
    required_check_contract_missing required_check_contract_unreadable routing_unavailable
    stale_issue unknown_project wrong_node
  )
  @type reason ::
          :notification_not_configured
          | :invalid_notification_config
          | :invalid_notification_event
          | :invalid_runtime_state_root
          | :invalid_stop_receipt
          | :invalid_delivery_receipt
          | :notification_command_unavailable
          | :notification_failed
          | :notification_timeout
          | :notification_delivery_ambiguous
          | :delivery_receipt_write_failed

  @spec notify_restart_limit(Observability.t(), map()) :: :ok | {:error, reason()}
  def notify_restart_limit(%Observability{} = config, attrs) when is_map(attrs) do
    with {:ok, runtime_root} <- validate_config(config),
         {:ok, event} <- build_event(config, attrs, runtime_root),
         receiver_hash = receiver_hash(config.notification_receiver),
         paths = notification_paths(runtime_root, receiver_hash, event.runtime_epoch),
         :reserved <- reserve_delivery(paths, receiver_hash, event.runtime_epoch),
         command_result <-
           run_notification_command(
             config.notification_command,
             Jason.encode!(event),
             config.notification_timeout_ms,
             runtime_root
           ),
         :ok <- finish_delivery(command_result, paths, receiver_hash, event.runtime_epoch) do
      :ok
    else
      :delivered -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :notification_failed}
  catch
    _kind, _reason -> {:error, :notification_failed}
  end

  def notify_restart_limit(_config, _attrs), do: {:error, :invalid_notification_config}

  defp validate_config(%Observability{
         runtime_state_root: root,
         notification_command: command,
         notification_receiver: receiver,
         restart_limit: restart_limit,
         notification_timeout_ms: timeout_ms
       }) do
    cond do
      not is_binary(command) or String.trim(command) == "" or not is_binary(receiver) or
          String.trim(receiver) == "" ->
        {:error, :notification_not_configured}

      not safe_command?(command) or not safe_receiver?(receiver) or
        not is_integer(restart_limit) or restart_limit <= 0 or not is_integer(timeout_ms) or
          timeout_ms <= 0 ->
        {:error, :invalid_notification_config}

      true ->
        validate_runtime_root(root)
    end
  end

  defp validate_runtime_root(root) when is_binary(root) do
    with true <- Path.type(root) == :absolute,
         false <- filesystem_root?(root),
         false <- production_path?(root),
         false <- secret_bearing?(root),
         :ok <- File.mkdir_p(root),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         false <- filesystem_root?(canonical_root),
         false <- production_path?(canonical_root),
         false <- secret_bearing?(canonical_root),
         true <- File.dir?(canonical_root) do
      {:ok, canonical_root}
    else
      _invalid -> {:error, :invalid_runtime_state_root}
    end
  end

  defp validate_runtime_root(_root), do: {:error, :invalid_runtime_state_root}

  defp build_event(config, attrs, runtime_root) do
    with true <- Enum.sort(Map.keys(attrs)) == @event_keys,
         runtime_identity when is_binary(runtime_identity) <- Map.get(attrs, :runtime_identity),
         true <- Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, runtime_identity),
         false <- secret_bearing?(runtime_identity),
         attempt_count when is_integer(attempt_count) and attempt_count > 0 <- Map.get(attrs, :attempt_count),
         true <- attempt_count >= config.restart_limit,
         timestamp when is_binary(timestamp) <- Map.get(attrs, :timestamp),
         true <- RuntimeReceiptContract.valid_utc_timestamp?(timestamp),
         runtime_epoch when is_binary(runtime_epoch) <- Map.get(attrs, :runtime_epoch),
         true <- valid_epoch?(runtime_epoch),
         receipt_path when is_binary(receipt_path) <- Map.get(attrs, :receipt_path),
         :ok <- validate_stop_receipt(runtime_root, runtime_epoch, receipt_path) do
      {:ok,
       %{
         runtime_identity: runtime_identity,
         receiver: config.notification_receiver,
         attempt_count: attempt_count,
         stop_category: "restart_limit",
         timestamp: timestamp,
         runtime_epoch: runtime_epoch,
         receipt_path: receipt_path
       }}
    else
      {:error, :invalid_stop_receipt} = error -> error
      _invalid -> {:error, :invalid_notification_event}
    end
  end

  defp validate_stop_receipt(runtime_root, runtime_epoch, receipt_path) do
    expected_path = Path.join(runtime_root, "stop-#{runtime_epoch}.json")

    with true <- same_path?(receipt_path, expected_path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(receipt_path),
         {:ok, canonical_receipt} <- PathSafety.canonicalize(receipt_path),
         true <- strictly_inside?(canonical_receipt, runtime_root),
         {:ok, payload} <-
           stable_read_receipt(receipt_path, RuntimeReceiptContract.max_encoded_bytes()),
         {:ok, receipt} when is_map(receipt) <- Jason.decode(payload),
         true <- valid_stop_receipt?(receipt, runtime_epoch, expected_path) do
      :ok
    else
      _invalid -> {:error, :invalid_stop_receipt}
    end
  end

  defp valid_stop_receipt?(receipt, runtime_epoch, expected_path) do
    keys = Map.keys(receipt)
    allowed_keys = @stop_receipt_required_keys ++ @stop_receipt_optional_keys

    Enum.all?(@stop_receipt_required_keys, &Map.has_key?(receipt, &1)) and
      Enum.all?(keys, &(&1 in allowed_keys)) and
      receipt["runtime_epoch"] == runtime_epoch and
      is_binary(receipt["receipt_path"]) and
      same_path?(receipt["receipt_path"], expected_path) and
      receipt["category"] in @stop_categories and
      valid_utc_timestamp?(receipt["at"]) and
      Enum.all?(receipt, &valid_stop_receipt_field?/1)
  end

  defp valid_stop_receipt_field?({"at", value}) do
    is_binary(value) and RuntimeReceiptContract.valid_string_size?(:at, value) and
      valid_utc_timestamp?(value)
  end

  defp valid_stop_receipt_field?({"category", value}) do
    is_binary(value) and RuntimeReceiptContract.valid_string_size?(:category, value) and
      value in @stop_categories
  end

  defp valid_stop_receipt_field?({"runtime_epoch", value}), do: valid_epoch?(value)

  defp valid_stop_receipt_field?({"receipt_path", value}) do
    is_binary(value) and RuntimeReceiptContract.valid_string_size?(:receipt_path, value) and
      String.valid?(value) and not secret_bearing?(value)
  end

  defp valid_stop_receipt_field?({"routing_revision", value}),
    do: RuntimeReceiptContract.valid_routing_revision?(value)

  defp valid_stop_receipt_field?({"restart_attempt", value}),
    do: RuntimeReceiptContract.valid_restart_attempt?(value)

  defp valid_stop_receipt_field?({"failure_category", nil}), do: true

  defp valid_stop_receipt_field?({"failure_category", value}),
    do:
      is_binary(value) and
        RuntimeReceiptContract.valid_string_size?(:failure_category, value) and
        value in @failure_categories

  defp valid_stop_receipt_field?({"environment", "local_non_production" = value}),
    do: RuntimeReceiptContract.valid_string_size?(:environment, value)

  defp valid_stop_receipt_field?({"profile_key", value}) do
    valid_receipt_string?(
      value,
      RuntimeReceiptContract.max_string_bytes(:profile_key),
      ~r/\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/
    )
  end

  defp valid_stop_receipt_field?({"issue_id", value}) do
    valid_receipt_string?(
      value,
      RuntimeReceiptContract.max_string_bytes(:issue_id),
      ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/
    )
  end

  defp valid_stop_receipt_field?({"issue_identifier", value}) do
    valid_receipt_string?(
      value,
      RuntimeReceiptContract.max_string_bytes(:issue_identifier),
      ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
    )
  end

  defp valid_stop_receipt_field?({"repository", value}) do
    valid_receipt_string?(
      value,
      RuntimeReceiptContract.max_string_bytes(:repository),
      ~r|\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z|
    )
  end

  defp valid_stop_receipt_field?({"workspace_namespace", value}) do
    valid_receipt_string?(
      value,
      RuntimeReceiptContract.max_string_bytes(:workspace_namespace),
      ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    )
  end

  defp valid_stop_receipt_field?({"canonical_branch", value}) do
    is_binary(value) and
      RuntimeReceiptContract.valid_string_size?(:canonical_branch, value) and
      String.valid?(value) and not secret_bearing?(value) and
      not Regex.match?(~r/[\x00-\x20\x7F\\]/, value) and
      not String.starts_with?(value, "/") and not String.ends_with?(value, "/") and
      not String.contains?(value, ["..", "@{"]) and not String.ends_with?(value, ".lock")
  end

  defp valid_stop_receipt_field?({"detail", value}) do
    is_binary(value) and RuntimeReceiptContract.within_string_limit?(:detail, value) and
      String.valid?(value) and not secret_bearing?(value) and
      not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, value)
  end

  defp valid_stop_receipt_field?(_field), do: false

  defp valid_utc_timestamp?(value) when is_binary(value) do
    RuntimeReceiptContract.valid_utc_timestamp?(value)
  end

  defp valid_utc_timestamp?(_value), do: false

  defp valid_receipt_string?(value, max_bytes, pattern) do
    is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
      not secret_bearing?(value) and Regex.match?(pattern, value)
  end

  defp stable_read_receipt(path, max_bytes) do
    if match?({:win32, _}, :os.type()) do
      stable_read_windows_receipt(path, max_bytes)
    else
      stable_read_portable_receipt(path, max_bytes)
    end
  end

  defp stable_read_windows_receipt(path, max_bytes) do
    with powershell when is_binary(powershell) <-
           System.find_executable("pwsh") || System.find_executable("powershell.exe"),
         command = windows_stable_read_command(path, max_bytes),
         encoded = command |> :unicode.characters_to_binary(:utf8, {:utf16, :little}) |> Base.encode64(),
         {:ok, port} <- open_stable_reader_port(powershell, encoded),
         {:ok, payload} <- await_stable_reader(port, System.monotonic_time(:millisecond) + 5_000, "", max_bytes) do
      {:ok, payload}
    else
      _error -> {:error, :unstable_receipt}
    end
  end

  defp windows_stable_read_command(path, max_bytes) do
    encoded_path = Base.encode64(path)

    """
    $ErrorActionPreference = 'Stop'
    Add-Type -TypeDefinition @'
    using System;
    using System.IO;
    using System.Runtime.InteropServices;
    using Microsoft.Win32.SafeHandles;

    public static class SymphonyTask6StableReceipt
    {
      [StructLayout(LayoutKind.Sequential)] private struct FILETIME { public uint Low; public uint High; }
      [StructLayout(LayoutKind.Sequential)] private struct INFO
      {
        public uint Attributes; public FILETIME Creation; public FILETIME Access; public FILETIME Write;
        public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links;
        public uint IndexHigh; public uint IndexLow;
      }
      [DllImport("kernel32.dll", SetLastError = true)]
      private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out INFO info);
      private static string Identity(SafeFileHandle handle)
      {
        INFO info;
        if (!GetFileInformationByHandle(handle, out info)) throw new IOException("identity");
        return info.Volume.ToString("X8") + ":" + info.IndexHigh.ToString("X8") + info.IndexLow.ToString("X8");
      }
      public static byte[] Read(string path, int maxBytes)
      {
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan))
        {
          string identity = Identity(stream.SafeFileHandle);
          long length = stream.Length;
          if (length < 1 || length > maxBytes) throw new IOException("size");
          byte[] payload = new byte[(int)length];
          int offset = 0;
          while (offset < payload.Length)
          {
            int count = stream.Read(payload, offset, payload.Length - offset);
            if (count == 0) throw new EndOfStreamException();
            offset += count;
          }
          stream.Position = 0;
          byte[] verification = new byte[payload.Length];
          offset = 0;
          while (offset < verification.Length)
          {
            int count = stream.Read(verification, offset, verification.Length - offset);
            if (count == 0) throw new EndOfStreamException();
            offset += count;
          }
          for (int index = 0; index < payload.Length; index++)
          {
            if (payload[index] != verification[index]) throw new IOException("content changed");
          }
          if (stream.Length != length || Identity(stream.SafeFileHandle) != identity) throw new IOException("changed");
          using (FileStream current = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
          {
            if (current.Length != length || Identity(current.SafeFileHandle) != identity) throw new IOException("replaced");
          }
          return payload;
        }
      }
    }
    '@ | Out-Null
    try {
      $path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('#{encoded_path}'))
      $payload = [SymphonyTask6StableReceipt]::Read($path, #{max_bytes})
      [Console]::Out.Write('OK:' + [Convert]::ToBase64String($payload))
      exit 0
    }
    catch { exit 2 }
    """
  end

  defp open_stable_reader_port(powershell, encoded) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(powershell)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: [~c"-NoLogo", ~c"-NoProfile", ~c"-NonInteractive", ~c"-EncodedCommand", String.to_charlist(encoded)]
        ]
      )

    {:ok, port}
  rescue
    _exception -> {:error, :reader_unavailable}
  catch
    _kind, _reason -> {:error, :reader_unavailable}
  end

  defp await_stable_reader(port, deadline_ms, output, max_bytes) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= max_bytes * 2 ->
        await_stable_reader(port, deadline_ms, output <> data, max_bytes)

      {^port, {:data, _oversize}} ->
        close_port(port)
        {:error, :reader_output_too_large}

      {^port, {:exit_status, 0}} ->
        with "OK:" <> encoded <- output,
             {:ok, payload} when byte_size(payload) >= 1 and byte_size(payload) <= max_bytes <-
               Base.decode64(encoded) do
          {:ok, payload}
        else
          _invalid -> {:error, :invalid_reader_output}
        end

      {^port, {:exit_status, _status}} ->
        {:error, :unstable_receipt}
    after
      remaining_ms ->
        close_port(port)
        {:error, :reader_timeout}
    end
  end

  defp stable_read_portable_receipt(path, max_bytes) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        with {:ok, before_handle} <- :file.read_file_info(file),
             {:ok, before_path} <- :file.read_file_info(String.to_charlist(path)),
             true <- stable_file_identity(before_handle) == stable_file_identity(before_path),
             size when is_integer(size) and size >= 1 and size <= max_bytes <- elem(before_handle, 1),
             payload when is_binary(payload) and byte_size(payload) == size <- IO.binread(file, max_bytes + 1),
             {:ok, after_handle} <- :file.read_file_info(file),
             {:ok, after_path} <- :file.read_file_info(String.to_charlist(path)),
             true <- stable_file_identity(before_handle) == stable_file_identity(after_handle),
             true <- stable_file_identity(after_handle) == stable_file_identity(after_path),
             true <- elem(after_handle, 1) == size do
          {:ok, payload}
        else
          _unstable -> {:error, :unstable_receipt}
        end
      after
        File.close(file)
      end
    end
  end

  # POSIX keeps the opened inode stable, but a same-user namespace relocation can still move that
  # inode after the final path check without an openat-style directory capability in public OTP.
  defp stable_file_identity(file_info) when is_tuple(file_info) and tuple_size(file_info) >= 13 do
    {elem(file_info, 2), elem(file_info, 9), elem(file_info, 10), elem(file_info, 11)}
  end

  defp stable_file_identity(_file_info), do: :invalid

  defp notification_paths(runtime_root, receiver_hash, runtime_epoch) do
    notification_key = notification_key(receiver_hash, runtime_epoch)

    %{
      claim: Path.join(runtime_root, "restart-limit-claim-#{notification_key}.json"),
      delivery: Path.join(runtime_root, "restart-limit-delivery-#{notification_key}.json"),
      legacy_claim: legacy_notification_path(runtime_root, "claim", receiver_hash, runtime_epoch),
      legacy_delivery: legacy_notification_path(runtime_root, "delivery", receiver_hash, runtime_epoch)
    }
  end

  defp legacy_notification_path(runtime_root, kind, receiver_hash, runtime_epoch)
       when kind in ["claim", "delivery"] do
    filename = "restart-limit-#{kind}-#{receiver_hash}-#{runtime_epoch}.json"
    path = Path.join(runtime_root, filename)

    if Regex.match?(~r/\A[a-f0-9]{64}\z/, receiver_hash) and valid_epoch?(runtime_epoch) and
         String.valid?(filename) and byte_size(filename) <= @max_portable_filename_bytes and
         Path.basename(filename) == filename and String.valid?(path) and
         byte_size(path) <= @max_portable_path_bytes and
         same_path?(Path.dirname(path), runtime_root) do
      path
    end
  end

  defp notification_key(receiver_hash, runtime_epoch) do
    :crypto.hash(:sha256, receiver_hash <> ":" <> runtime_epoch)
    |> Base.encode16(case: :lower)
  end

  defp reserve_delivery(paths, receiver_hash, runtime_epoch) do
    case delivery_status(paths.delivery, receiver_hash, runtime_epoch) do
      :delivered ->
        :delivered

      :missing ->
        reserve_legacy_delivery(paths, receiver_hash, runtime_epoch)

      {:error, _reason} = error ->
        error
    end
  end

  defp reserve_legacy_delivery(paths, receiver_hash, runtime_epoch) do
    case delivery_status(paths.legacy_delivery, receiver_hash, runtime_epoch) do
      :delivered ->
        :delivered

      :missing ->
        reserve_legacy_claim(paths, receiver_hash, runtime_epoch)

      {:error, _reason} = error ->
        error
    end
  end

  defp reserve_legacy_claim(paths, receiver_hash, runtime_epoch) do
    case claim_status(paths.legacy_claim, receiver_hash, runtime_epoch) do
      :inflight -> {:error, :notification_delivery_ambiguous}
      :missing -> write_claim(paths.claim, receiver_hash, runtime_epoch)
      {:error, _reason} = error -> error
    end
  end

  defp write_claim(path, receiver_hash, runtime_epoch) do
    claim = %{
      version: 1,
      state: "inflight",
      receiver_hash: receiver_hash,
      runtime_epoch: runtime_epoch,
      stop_category: "restart_limit"
    }

    case publish_immutable_json(path, claim) do
      :ok ->
        :reserved

      {:error, :eexist} ->
        case claim_status(path, receiver_hash, runtime_epoch) do
          :inflight -> {:error, :notification_delivery_ambiguous}
          _invalid -> {:error, :invalid_delivery_receipt}
        end

      _error ->
        {:error, :delivery_receipt_write_failed}
    end
  end

  defp claim_status(path, receiver_hash, runtime_epoch) when is_binary(path) do
    with {:ok, payload} <- read_idempotency_receipt(path),
         {:ok,
          %{
            "version" => 1,
            "state" => "inflight",
            "receiver_hash" => ^receiver_hash,
            "runtime_epoch" => ^runtime_epoch,
            "stop_category" => "restart_limit"
          } = claim} <- Jason.decode(payload),
         true <- map_size(claim) == 5 do
      :inflight
    else
      :missing -> :missing
      _invalid -> {:error, :invalid_delivery_receipt}
    end
  end

  defp claim_status(nil, _receiver_hash, _runtime_epoch),
    do: {:error, :notification_delivery_ambiguous}

  defp delivery_status(path, receiver_hash, runtime_epoch) when is_binary(path) do
    with {:ok, payload} <- read_idempotency_receipt(path),
         {:ok,
          %{
            "version" => 1,
            "delivered" => true,
            "receiver_hash" => ^receiver_hash,
            "runtime_epoch" => ^runtime_epoch,
            "stop_category" => "restart_limit"
          } = receipt} <- Jason.decode(payload),
         true <- map_size(receipt) == 5 do
      :delivered
    else
      :missing -> :missing
      _invalid -> {:error, :invalid_delivery_receipt}
    end
  end

  defp delivery_status(nil, _receiver_hash, _runtime_epoch),
    do: {:error, :notification_delivery_ambiguous}

  defp read_idempotency_receipt(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}}
      when size in 1..@max_idempotency_receipt_bytes ->
        case stable_read_receipt(path, @max_idempotency_receipt_bytes) do
          {:ok, payload} when byte_size(payload) == size -> {:ok, payload}
          _invalid -> {:error, :invalid_delivery_receipt}
        end

      {:error, :enoent} ->
        :missing

      _invalid ->
        {:error, :invalid_delivery_receipt}
    end
  end

  defp finish_delivery({:ok, :terminated}, paths, receiver_hash, runtime_epoch) do
    with :ok <- write_delivery_receipt(paths.delivery, receiver_hash, runtime_epoch),
         :ok <- remove_claim(paths.claim) do
      :ok
    end
  end

  defp finish_delivery({:error, reason, :terminated}, paths, _receiver_hash, _runtime_epoch) do
    case remove_claim(paths.claim) do
      :ok -> {:error, reason}
      {:error, _reason} -> {:error, :notification_delivery_ambiguous}
    end
  end

  defp finish_delivery({:error, _reason, :unverified}, _paths, _receiver_hash, _runtime_epoch),
    do: {:error, :notification_delivery_ambiguous}

  defp finish_delivery(_unexpected, _paths, _receiver_hash, _runtime_epoch),
    do: {:error, :notification_delivery_ambiguous}

  defp remove_claim(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :claim_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_notification_command(command, payload, timeout_ms, runtime_root) do
    try do
      case local_shell(command, payload, runtime_root, timeout_ms) do
        {:ok, executable, args, environment, cleanup_paths} ->
          try do
            with {:ok, port} <- open_command_port(executable, args, environment) do
              await_command(port, System.monotonic_time(:millisecond) + timeout_ms + 5_000)
            else
              _unavailable -> {:error, :notification_command_unavailable}
            end
          after
            Enum.each(cleanup_paths, &File.rm/1)
          end

        _unavailable ->
          {:error, :notification_command_unavailable}
      end
    rescue
      _exception -> {:error, :notification_command_unavailable}
    catch
      _kind, _reason -> {:error, :notification_command_unavailable}
    end
  end

  defp local_shell(command, payload, runtime_root, timeout_ms) do
    event_environment = [{"SYMPHONY_TASK6_EVENT_B64", Base.encode64(payload)}]

    if match?({:win32, _}, :os.type()) do
      powershell = System.find_executable("pwsh") || System.find_executable("powershell.exe")

      case powershell do
        nil ->
          {:error, :notification_command_unavailable}

        powershell ->
          wrapper = windows_command_wrapper(command, timeout_ms)

          wrapper_path =
            Path.join(
              runtime_root,
              ".restart-limit-runner-#{System.unique_integer([:positive, :monotonic])}.ps1"
            )

          case write_temporary_receipt(wrapper_path, wrapper) do
            :ok ->
              {:ok, powershell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", wrapper_path], event_environment, [wrapper_path]}

            {:error, _reason} ->
              {:error, :notification_command_unavailable}
          end
      end
    else
      case System.find_executable("sh") do
        nil ->
          {:error, :notification_command_unavailable}

        executable ->
          wrapper =
            ~s(event="$SYMPHONY_TASK6_EVENT_B64"; unset SYMPHONY_TASK6_EVENT_B64; printf '%s' "$event" | base64 -d | sh -lc "$1" >/dev/null 2>&1)

          {:ok, executable, ["-c", wrapper, "symphony-notifier", command], event_environment, []}
      end
    end
  end

  defp windows_command_wrapper(command, timeout_ms) do
    encoded_command = Base.encode64(command)
    gate_nonce = Base.encode64(:crypto.strong_rand_bytes(24))

    gate_wrapper =
      windows_gate_wrapper(encoded_command, gate_nonce)
      |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
      |> Base.encode64()

    """
    $ErrorActionPreference = 'Stop'
    if (-not ('SymphonyTask6Job' -as [type])) {
      Add-Type -TypeDefinition @'
    using System;
    using System.Diagnostics;
    using System.Runtime.InteropServices;
    using System.Threading;

    public sealed class SymphonyTask6Job : IDisposable
    {
      private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
      private const int JobObjectBasicAccountingInformation = 1;
      private const int JobObjectExtendedLimitInformation = 9;
      private IntPtr handle;

      [StructLayout(LayoutKind.Sequential)]
      private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
      {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
      }

      [StructLayout(LayoutKind.Sequential)]
      private struct IO_COUNTERS
      {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
      }

      [StructLayout(LayoutKind.Sequential)]
      private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
      {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
      }

      [StructLayout(LayoutKind.Sequential)]
      private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
      {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
      }

      [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
      private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

      [DllImport("kernel32.dll", SetLastError = true)]
      private static extern bool SetInformationJobObject(
        IntPtr job,
        int informationClass,
        IntPtr information,
        uint informationLength
      );

      [DllImport("kernel32.dll", SetLastError = true)]
      private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

      [DllImport("kernel32.dll", SetLastError = true)]
      private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

      [DllImport("kernel32.dll", SetLastError = true)]
      private static extern bool QueryInformationJobObject(
        IntPtr job,
        int informationClass,
        out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION information,
        uint informationLength,
        IntPtr returnLength
      );

      [DllImport("kernel32.dll", SetLastError = true)]
      private static extern bool CloseHandle(IntPtr handle);

      private SymphonyTask6Job(IntPtr jobHandle)
      {
        handle = jobHandle;
      }

      public static SymphonyTask6Job Create()
      {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) { return null; }

        JOBOBJECT_EXTENDED_LIMIT_INFORMATION information = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(size);

        try
        {
          Marshal.StructureToPtr(information, buffer, false);
          if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
          {
            CloseHandle(job);
            return null;
          }
        }
        finally
        {
          Marshal.FreeHGlobal(buffer);
        }

        return new SymphonyTask6Job(job);
      }

      public bool Assign(Process process)
      {
        return handle != IntPtr.Zero && AssignProcessToJobObject(handle, process.Handle);
      }

      public bool TerminateAndWait(int timeoutMs)
      {
        if (handle == IntPtr.Zero || !TerminateJobObject(handle, 1)) { return false; }

        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds <= timeoutMs)
        {
          JOBOBJECT_BASIC_ACCOUNTING_INFORMATION information;
          if (!QueryInformationJobObject(
                handle,
                JobObjectBasicAccountingInformation,
                out information,
                (uint)Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)),
                IntPtr.Zero))
          {
            return false;
          }

          if (information.ActiveProcesses == 0) { return true; }
          Thread.Sleep(10);
        }

        return false;
      }

      public void Dispose()
      {
        if (handle != IntPtr.Zero)
        {
          CloseHandle(handle);
          handle = IntPtr.Zero;
        }
      }
    }
    '@ | Out-Null
    }

    $payloadEncoded = [Environment]::GetEnvironmentVariable('SYMPHONY_TASK6_EVENT_B64')
    [Environment]::SetEnvironmentVariable('SYMPHONY_TASK6_EVENT_B64', $null, 'Process')
    if ([string]::IsNullOrWhiteSpace($payloadEncoded)) { exit 125 }
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadEncoded))
    $enginePath = (Get-Process -Id $PID).Path
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $enginePath
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand #{gate_wrapper}'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $job = [SymphonyTask6Job]::Create()
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timedOut = $false
    $treeStopped = $false
    $drainsStopped = $false
    try {
      if ($null -eq $job -or -not $process.Start()) { exit 125 }
      if (-not $job.Assign($process)) {
        try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
        $null = $process.WaitForExit(1000)
        exit 125
      }
      $outputDrain = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
      $errorDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
      $process.StandardInput.WriteLine('#{gate_nonce}')
      $process.StandardInput.Write($payload)
      $process.StandardInput.Close()
      if (-not $process.WaitForExit(#{timeout_ms})) {
        $timedOut = $true
      }
      else {
        $exitCode = $process.ExitCode
      }
      $treeStopped = $job.TerminateAndWait(2000)
      $null = $process.WaitForExit(2000)
      $drainsStopped = $outputDrain.Wait(2000) -and $errorDrain.Wait(2000)
      if (-not $treeStopped -or -not $drainsStopped) { exit 126 }
      if ($timedOut) { exit 124 }
      if ($exitCode -eq 0) { exit 0 }
      exit 123
    }
    catch {
      if ($null -ne $job) { $treeStopped = $job.TerminateAndWait(2000) }
      if ($treeStopped) { exit 123 }
      exit 126
    }
    finally {
      $process.Dispose()
      if ($null -ne $job) { $job.Dispose() }
    }
    """
  end

  defp windows_gate_wrapper(encoded_command, gate_nonce) do
    """
    $ErrorActionPreference = 'Stop'
    if ([Console]::In.ReadLine() -ne '#{gate_nonce}') { exit 125 }
    $payload = [Console]::In.ReadToEnd()
    $enginePath = (Get-Process -Id $PID).Path
    $command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('#{encoded_command}'))
    $childCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $enginePath
    $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $childCommand"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
      if (-not $process.Start()) { exit 125 }
      $outputDrain = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
      $errorDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
      $process.StandardInput.Write($payload)
      $process.StandardInput.Close()
      $process.WaitForExit()
      $exitCode = $process.ExitCode
      $outputStopped = $outputDrain.Wait(250)
      $errorStopped = $errorDrain.Wait(250)
      if (-not $outputStopped -or -not $errorStopped) { exit 126 }
      exit $exitCode
    }
    catch { exit 125 }
    finally { $process.Dispose() }
    """
  end

  defp open_command_port(executable, args, environment) do
    target = {:spawn_executable, String.to_charlist(executable)}

    options = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      :hide,
      env:
        Enum.map(environment, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end),
      args: Enum.map(args, &String.to_charlist/1)
    ]

    opener = Application.get_env(:symphony_elixir, :runtime_notifier_port_opener, &Port.open/2)

    case opener.(target, options) do
      port when is_port(port) -> {:ok, port}
      _invalid -> {:error, :notification_command_unavailable}
    end
  rescue
    _exception -> {:error, :notification_command_unavailable}
  catch
    _kind, _reason -> {:error, :notification_command_unavailable}
  end

  defp await_command(port, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _discarded_output}} ->
        await_command(port, deadline_ms)

      {^port, {:exit_status, 0}} ->
        {:ok, :terminated}

      {^port, {:exit_status, 123}} ->
        {:error, :notification_failed, :terminated}

      {^port, {:exit_status, 124}} ->
        {:error, :notification_timeout, :terminated}

      {^port, {:exit_status, 125}} ->
        {:error, :notification_command_unavailable, :unverified}

      {^port, {:exit_status, 126}} ->
        {:error, :notification_failed, :unverified}

      {^port, {:exit_status, _status}} ->
        {:error, :notification_failed, :unverified}
    after
      remaining_ms ->
        close_port(port)
        {:error, :notification_timeout, :unverified}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp write_delivery_receipt(path, receiver_hash, runtime_epoch) do
    receipt = %{
      version: 1,
      delivered: true,
      receiver_hash: receiver_hash,
      runtime_epoch: runtime_epoch,
      stop_category: "restart_limit"
    }

    case publish_immutable_json(path, receipt) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case delivery_status(path, receiver_hash, runtime_epoch) do
          :delivered -> :ok
          _invalid -> {:error, :delivery_receipt_write_failed}
        end

      _error ->
        {:error, :delivery_receipt_write_failed}
    end
  end

  defp publish_immutable_json(path, value) do
    receipt = Jason.encode!(value)
    temporary_path = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- write_temporary_receipt(temporary_path, receipt),
           :ok <- File.ln(temporary_path, path),
           :ok <- File.rm(temporary_path) do
        :ok
      else
        {:error, reason} ->
          _cleanup = File.rm(temporary_path)
          {:error, reason}
      end
    rescue
      _exception ->
        _cleanup = File.rm(temporary_path)
        {:error, :publish_failed}
    end
  end

  defp write_temporary_receipt(path, receipt) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- IO.binwrite(file, receipt),
               :ok <- :file.sync(file) do
            :ok
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_command?(value) do
    is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
      String.trim(value) != "" and not String.contains?(value, <<0>>) and not secret_bearing?(value)
  end

  defp safe_receiver?(value) do
    is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:@+-]*\z/, value) and not secret_bearing?(value)
  end

  defp valid_epoch?(value) do
    is_binary(value) and RuntimeReceiptContract.valid_string_size?(:runtime_epoch, value) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, value) and not secret_bearing?(value)
  end

  defp receiver_hash(receiver) do
    :crypto.hash(:sha256, receiver)
    |> Base.encode16(case: :lower)
  end

  defp secret_bearing?(value), do: SymphonyElixir.SecretSafety.contains_secret?(value)

  defp production_path?(path) do
    path
    |> Path.expand()
    |> String.split(~r{[\\/]}, trim: true)
    |> Enum.any?(&(String.downcase(&1) |> String.contains?("production")))
  end

  defp filesystem_root?(path) do
    case path |> Path.expand() |> Path.split() do
      [_root] -> true
      _parts -> false
    end
  end

  defp strictly_inside?(path, root), do: inside?(path, root) and not same_path?(path, root)

  defp inside?(path, root) do
    path = normalized_path(path)
    root = root |> normalized_path() |> String.trim_trailing("/")
    path == root or String.starts_with?(path, root <> "/")
  end

  defp same_path?(left, right), do: normalized_path(left) == normalized_path(right)

  defp normalized_path(path) do
    normalized = path |> Path.expand() |> String.replace("\\", "/")
    if match?({:win32, _}, :os.type()), do: String.downcase(normalized), else: normalized
  end
end
