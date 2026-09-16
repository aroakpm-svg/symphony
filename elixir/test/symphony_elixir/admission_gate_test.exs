defmodule SymphonyElixir.AdmissionGateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AdmissionGate

  @environment "SYMPHONY_ADMISSION_PAUSE_FILE"

  setup do
    previous = System.get_env(@environment)
    on_exit(fn -> restore_environment(previous) end)
    :ok
  end

  test "legacy runtime remains admitted when no gate is configured" do
    System.delete_env(@environment)
    refute AdmissionGate.paused?()
    assert {:error, :admission_gate_invalid} = AdmissionGate.validate_configuration()
  end

  test "a valid gate pauses admission only while its regular file exists" do
    directory = secure_directory!()
    path = Path.join(directory, "pause")
    System.put_env(@environment, path)

    assert :ok = AdmissionGate.validate_configuration()
    refute AdmissionGate.paused?()

    File.write!(path, "paused\n")
    File.chmod!(path, 0o600)
    assert :ok = AdmissionGate.validate_configuration()
    assert AdmissionGate.paused?()

    File.rm!(path)
    refute AdmissionGate.paused?()
  end

  test "invalid or non-regular gates fail closed" do
    System.put_env(@environment, "relative/pause")
    assert {:error, :admission_gate_invalid} = AdmissionGate.validate_configuration()
    assert AdmissionGate.paused?()

    System.put_env(@environment, System.tmp_dir!())
    assert {:error, :admission_gate_invalid} = AdmissionGate.validate_configuration()
    assert AdmissionGate.paused?()

    missing_parent = Path.join([System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}", "pause"])
    System.put_env(@environment, missing_parent)
    assert {:error, :admission_gate_invalid} = AdmissionGate.validate_configuration()
    assert AdmissionGate.paused?()

    assert :absent = AdmissionGate.gate_entry_for_test("ignored", fn _ -> {:error, :enoent} end)

    assert {:error, :admission_gate_invalid} =
             AdmissionGate.gate_entry_for_test("ignored", fn _ -> {:error, :eacces} end)

    directory = secure_directory!()

    assert {:error, :admission_gate_invalid} =
             AdmissionGate.gate_entry_for_test(directory, &File.lstat/1)
  end

  test "a gate beneath a worker-writable ancestor fails closed" do
    path = Path.join(System.tmp_dir!(), "symphony-admission-#{System.unique_integer([:positive])}")
    System.put_env(@environment, path)

    assert {:error, :admission_gate_invalid} = AdmissionGate.validate_configuration()
    assert AdmissionGate.paused?()
  end

  test "missing ACL inspection tooling fails closed" do
    directory = secure_directory!()
    path = Path.join(directory, "pause")
    empty_path = Path.join(directory, "empty-path")
    File.mkdir!(empty_path)
    System.put_env(@environment, path)

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_environment_variable("PATH", previous_path) end)
    System.put_env("PATH", empty_path)

    assert {:error, :admission_gate_invalid} = AdmissionGate.validate_configuration()
    assert AdmissionGate.paused?()
  end

  test "every gate ancestor is validated and a redirected ancestor fails closed" do
    directory = secure_directory!()
    actual = Path.join(directory, "actual")
    redirected = Path.join(directory, "redirected")
    File.mkdir!(actual)
    File.chmod!(actual, 0o700)
    File.ln_s!(actual, redirected)
    System.put_env(@environment, Path.join(redirected, "pause"))

    assert {:error, :admission_gate_invalid} =
             AdmissionGate.validate_configuration()

    assert AdmissionGate.paused?()
  end

  defp restore_environment(nil), do: System.delete_env(@environment)
  defp restore_environment(value), do: System.put_env(@environment, value)
  defp restore_environment_variable(key, nil), do: System.delete_env(key)
  defp restore_environment_variable(key, value), do: System.put_env(key, value)

  defp secure_directory! do
    path = Path.join(File.cwd!(), ".symphony-gate-test-#{System.unique_integer([:positive])}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
