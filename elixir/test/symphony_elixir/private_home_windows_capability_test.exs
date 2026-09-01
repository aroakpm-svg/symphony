defmodule SymphonyElixir.PrivateHome.WindowsCapabilityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PrivateHome.WindowsCapability

  test "protocol timeouts and malformed or mismatched replies permanently retire the helper" do
    if windows?() do
      for mode <- ["delay", "malformed", "mismatch"] do
        capability = protocol_fixture_capability(mode, 25)

        assert {:error, :private_home_capability_failed} =
                 WindowsCapability.commit(capability)

        refute WindowsCapability.active_for_test?(capability), "helper remained active for #{mode}"
      end
    else
      assert true
    end
  end

  test "correlated commit and rollback failures permanently retire the helper" do
    if windows?() do
      commit_capability = protocol_fixture_capability("reject", 1_000)

      assert {:error, :private_home_capability_failed} =
               WindowsCapability.commit(commit_capability)

      refute WindowsCapability.active_for_test?(commit_capability)

      rollback_capability = protocol_fixture_capability("reject", 1_000)

      assert {:error, :private_home_capability_failed} =
               WindowsCapability.rollback(rollback_capability)

      refute WindowsCapability.active_for_test?(rollback_capability)
    else
      assert true
    end
  end

  test "every helper command uses a fresh correlation identifier" do
    if windows?() do
      capability = protocol_fixture_capability("unique", 1_000)

      assert :ok = WindowsCapability.verify(capability)
      assert :ok = WindowsCapability.verify(capability)

      eventually(fn -> refute WindowsCapability.active_for_test?(capability) end)
    else
      assert true
    end
  end

  defp protocol_fixture_capability(mode, timeout_ms) do
    executable = windows_powershell!()
    script = Path.expand("../support/private_home_protocol_fixture.ps1", __DIR__)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :hide,
          :use_stdio,
          :stderr_to_stdout,
          args:
            Enum.map(
              [
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                script,
                "-Mode",
                mode
              ],
              &String.to_charlist/1
            ),
          line: 4_096
        ]
      )

    WindowsCapability.from_port_for_test(port, timeout_ms)
  end

  defp eventually(assertion, attempts \\ 50)

  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end

  defp windows?, do: match?({:win32, _name}, :os.type())

  defp windows_powershell! do
    Path.join([
      System.fetch_env!("SystemRoot"),
      "System32",
      "WindowsPowerShell",
      "v1.0",
      "powershell.exe"
    ])
  end
end
