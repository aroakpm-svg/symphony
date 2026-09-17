defmodule SymphonyElixir.WindowsNodeInstallerTest do
  use ExUnit.Case, async: true

  @powershell System.find_executable("powershell.exe")
  @installer Path.expand("../../priv/install_aro_197_windows.ps1", __DIR__)
  @broker_project Path.expand("../../priv/windows-service/Symphony.WindowsBroker/Symphony.WindowsBroker.csproj", __DIR__)
  @workflow Path.expand("../../../.github/workflows/windows-broker.yml", __DIR__)
  @sha String.duplicate("a", 40)

  @tag skip: if(is_nil(@powershell), do: "powershell.exe unavailable", else: false)
  test "plan is secret-free, fail-closed, and makes no filesystem changes" do
    root = tmp_root()
    legacy = Path.join(root, "runtime")
    File.mkdir_p!(legacy)
    File.write!(Path.join(legacy, "dirty.txt"), "keep")

    {output, status} = run_installer("Plan", root)
    assert status != 0
    receipt = Jason.decode!(output)

    assert receipt["changed"] == false
    assert receipt["mode"] == "Plan"
    assert receipt["node"] == "Amy"
    assert receipt["runtime_commit"] == @sha
    assert receipt["computer_name"] == System.get_env("COMPUTERNAME")
    assert is_binary(receipt["identity"])
    assert receipt["administrators_sid"] == "S-1-5-32-544"
    assert is_boolean(receipt["elevated"])
    assert is_boolean(receipt["administrators_enabled"])
    assert is_boolean(receipt["administrators_deny_only"])
    assert is_list(receipt["blockers"])
    assert receipt["result"] == "FAIL"
    assert receipt["blockers"] != []

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

  test "broker service artifact is self-contained for Windows hosts without global dotnet" do
    project = File.read!(@broker_project)
    workflow = File.read!(@workflow)

    assert project =~ "<RuntimeIdentifier>win-x64</RuntimeIdentifier>"
    assert project =~ "<SelfContained>true</SelfContained>"
    assert project =~ "<PublishSingleFile>true</PublishSingleFile>"
    assert project =~ "<IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>"
    assert workflow =~ "--self-contained true"
    refute workflow =~ "--self-contained false"
    assert workflow =~ "Verify self-contained single-file broker artifact"
    assert workflow =~ "DOTNET_ROOT_X64"

    probe = :binary.match(workflow, "$output = (& $binary --service 2>&1 | Out-String).Trim()")
    restoration = :binary.match(workflow, "$env:DOTNET_MULTILEVEL_LOOKUP = $savedLookup")
    explicit_success = :binary.match(workflow, "exit 0")

    assert probe != :nomatch
    assert restoration != :nomatch
    assert explicit_success != :nomatch
    assert elem(probe, 0) < elem(restoration, 0)
    assert elem(restoration, 0) < elem(explicit_success, 0)
  end

  test "installer retains one broker-only identity boundary" do
    installer = File.read!(@installer)
    assert installer =~ "ValidateSet('Amy', 'Matt')"
    assert installer =~ "ValidateSet('Plan', 'Install', 'Rollback')"
    assert installer =~ "AreAllAccessRulesProtected"
    assert installer =~ "SYMPHONY_GITHUB_APP_PRIVATE_KEY_FILE"
    assert installer =~ "private_key_reader_not_allowed"
    assert installer =~ "private_key_codex_owner"
    assert installer =~ "private_key_codex_acl_control"
    assert installer =~ "private_key_owner_not_allowed"
    assert installer =~ "ChangePermissions"
    assert installer =~ "TakeOwnership"
    assert installer =~ "Get-RuleSid"
    assert installer =~ "if (-not ('ARO197.NativeToken' -as [type]))"
    assert installer =~ "Assert-AdministrativeExecutionContext"
    refute installer =~ "if (-not (Test-Elevated))"
    assert installer =~ "New-Service"
    assert installer =~ "-StartupType Manual"
    assert installer =~ "NT SERVICE\\$serviceName"
    assert installer =~ "sc.exe config $serviceName obj= $serviceIdentity"
    assert installer =~ "sc.exe sidtype $serviceName restricted"
    assert installer =~ "service_account_mismatch"
    assert installer =~ "task_not_disabled"
    assert installer =~ "admission_not_paused"
    assert installer =~ "Assert-InstallReadiness"
    assert installer =~ "Assert-ControllerOnlyBoundary"
    assert installer =~ "Get-ScheduledTask"
    assert installer =~ "StartName"
    assert installer =~ "StartMode"
    assert installer =~ "Set-ProtectedAclRules"
    assert installer =~ "Set-ProtectedAclRules $InstallRoot"
    assert installer =~ "@{ Principal = $serviceIdentity; Rights = 'ReadAndExecute' }"
    assert installer =~ "Rights = 'FullControl'"
    assert installer =~ "Rights = 'ReadAndExecute'"
    assert installer =~ "controller_sid"
    assert installer =~ "codex.command"
    assert installer =~ "codex-command.ps1"
    assert installer =~ "broker_service_not_running"
    assert installer =~ "Get-Service -Name"
    refute installer =~ "Register-ScheduledTask"
    refute installer =~ "New-ScheduledTask"
    refute installer =~ "codex_worker_windows.ps1"
    refute installer =~ "New-LocalUser"
    refute installer =~ "-Credential"

    readiness = :binary.match(installer, "Assert-InstallReadiness $controllerSid")
    first_mutation = :binary.match(installer, "$stage = 'runtime'")
    assert readiness != :nomatch
    assert first_mutation != :nomatch
    assert elem(readiness, 0) < elem(first_mutation, 0)
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
    assert installer =~ "Save-RecoveryState"
    assert installer =~ "created.service = $false"
    assert installer =~ "Set-ProtectedAcl $state"
    assert installer =~ "broker_profile_root_missing"
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
    assert installer =~ "service_name"
    assert installer =~ "service_name = $serviceName"
    assert installer =~ "workspace_root"
    assert installer =~ "private_home_root"
    assert installer =~ "codex_home_root"
    assert installer =~ "codex_exe"
    assert installer =~ "codex_copy_attestation_failed"
    assert installer =~ "Assert-BrokerArtifactSelfContained"
    assert installer =~ "broker_artifact_not_self_contained"
    assert installer =~ "missing_config"
    assert installer =~ "previousErrorActionPreference"
    assert installer =~ "$ErrorActionPreference = 'Continue'"
    assert installer =~ "probeExitCode"
    assert installer =~ "Set-ProtectedAclRules $WorkspaceRoot"
    assert installer =~ "Set-ProtectedAclRules $PrivateHomeRoot"
    assert installer =~ "Set-ProtectedAclRules $CodexHomeRoot"
    assert installer =~ "profileAclRoots"
    assert installer =~ "ConvertTo-PowerShellSingleQuotedLiteral"
    assert installer =~ "$workspaceRootLiteral"
    assert installer =~ "$brokerExeLiteral"
    assert installer =~ "$pipeNameLiteral"
    assert installer =~ "@{ Principal = $serviceIdentity; Rights = 'Modify' }"
    assert installer =~ "ConvertTo-Json"
    refute installer =~ "--private-home"
    refute installer =~ "--codex-home"
    refute installer =~ "icacls.exe `$grantPath /grant"
    refute installer =~ "icacls.exe `$grantPath /remove:g"
    refute installer =~ "SYMPHONY_BROKER_CLEANUP_ACK"
    refute installer =~ "<profile>"
    refute installer =~ "<issue-workspace>"
    refute installer =~ "installation_id ="
    refute installer =~ "private_key ="
  end

  test "recovery manifest is persisted before protecting the install root" do
    installer = File.read!(@installer)
    state_write = :binary.match(installer, "$created.state = $true; Save-RecoveryState $created $previousAcl")
    root_acl = :binary.match(installer, "Set-ProtectedAcl $InstallRoot")

    assert state_write != :nomatch
    assert root_acl != :nomatch
    assert elem(state_write, 0) < elem(root_acl, 0)
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
