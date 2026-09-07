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
    path = Path.join(System.tmp_dir!(), "symphony-admission-#{System.unique_integer([:positive])}")
    System.put_env(@environment, path)
    on_exit(fn -> File.rm(path) end)

    assert :ok = AdmissionGate.validate_configuration()
    refute AdmissionGate.paused?()

    File.write!(path, "paused\n")
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
  end

  defp restore_environment(nil), do: System.delete_env(@environment)
  defp restore_environment(value), do: System.put_env(@environment, value)
end
