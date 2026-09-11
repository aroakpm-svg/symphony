defmodule SymphonyElixir.WindowsNodeInstallerTest do
  use ExUnit.Case, async: true

  @powershell System.find_executable("powershell.exe")
  @installer Path.expand("../../priv/install_aro_197_windows.ps1", __DIR__)
  @sha String.duplicate("a", 40)

  @tag skip: if(is_nil(@powershell), do: "powershell.exe unavailable", else: false)
  test "plan is secret-free, node-bound, immutable, and makes no filesystem changes" do
    root = tmp_root()
    legacy = Path.join(root, "runtime")
    File.mkdir_p!(legacy)
    File.write!(Path.join(legacy, "dirty.txt"), "keep")

    {output, 0} = run_installer("Plan", root)
    receipt = Jason.decode!(output)

    assert receipt == %{
             "changed" => false,
             "mode" => "Plan",
             "node" => "Amy",
             "result" => "PASS",
             "runtime_commit" => @sha,
             "service_state" => "Stopped"
           }

    assert File.read!(Path.join(legacy, "dirty.txt")) == "keep"
    refute File.exists?(Path.join(root, "runtime-#{@sha}"))
    refute output =~ "PRIVATE_KEY"
    refute output =~ "INSTALLATION_ID"
  end

  @tag skip: if(is_nil(@powershell), do: "powershell.exe unavailable", else: false)
  test "mutation modes fail closed without an elevated token" do
    root = tmp_root()
    {output, status} = run_installer("Install", root)
    assert status != 0
    assert Jason.decode!(output) == %{"changed" => false, "result" => "FAIL", "reason" => "elevation_required"}
    refute File.exists?(Path.join(root, "runtime-#{@sha}"))
  end

  test "installer retains one broker-only identity boundary" do
    installer = File.read!(@installer)
    assert installer =~ "ValidateSet('Amy', 'Matt')"
    assert installer =~ "ValidateSet('Plan', 'Install', 'Rollback')"
    assert installer =~ "AreAllAccessRulesProtected"
    assert installer =~ "SYMPHONY_GITHUB_APP_PRIVATE_KEY_FILE"
    assert installer =~ "private_key_reader_not_allowed"
    assert installer =~ "Get-RuleSid"
    assert installer =~ "New-Service"
    assert installer =~ "-StartupType Manual"
    assert installer =~ "NT SERVICE\\$serviceName"
    assert installer =~ "controller_sid"
    assert installer =~ "codex.command"
    refute installer =~ "Register-ScheduledTask"
    refute installer =~ "New-ScheduledTask"
    refute installer =~ "codex_worker_windows.ps1"
    refute installer =~ "New-LocalUser"
    refute installer =~ "-Credential"
  end

  test "state manifest and rollback are limited to resources created by this install" do
    installer = File.read!(@installer)

    assert installer =~ "created.runtime"
    assert installer =~ "created.broker"
    assert installer =~ "created.config"
    assert installer =~ "created.service"
    assert installer =~ "created.state"
    assert installer =~ "Stop-Service"
    assert installer =~ "sc.exe delete"
    assert installer =~ "Remove-CreatedResources $saved.created"
    refute installer =~ "Unregister-ScheduledTask"
    refute installer =~ "Disable-ScheduledTask"
    refute installer =~ "Stop-ScheduledTask"
    refute installer =~ "Remove-LocalUser"
  end

  test "installed broker configuration is secret-free and node-bound" do
    installer = File.read!(@installer)

    assert installer =~ "broker-settings.json"
    assert installer =~ "controller_sid"
    assert installer =~ "pipe_name"
    assert installer =~ "workspace_root"
    assert installer =~ "private_home_root"
    assert installer =~ "codex_home_root"
    assert installer =~ "codex_exe"
    assert installer =~ "codex_copy_attestation_failed"
    assert installer =~ "Set-ProtectedAcl $WorkspaceRoot"
    assert installer =~ "Set-ProtectedAcl $PrivateHomeRoot"
    assert installer =~ "Set-ProtectedAcl $CodexHomeRoot"
    assert installer =~ "ConvertTo-Json"
    refute installer =~ "installation_id ="
    refute installer =~ "private_key ="
  end

  defp run_installer(mode, root) do
    System.cmd(
      @powershell,
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", @installer, "-Node", "Amy", "-RuntimeCommit", @sha, "-Mode", mode, "-InstallRoot", root],
      stderr_to_stdout: true
    )
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "aro197-installer-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
