[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Amy', 'Matt')][string]$Node,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$RuntimeCommit,
  [Parameter(Mandatory)][ValidateSet('Plan', 'Install', 'Rollback')][string]$Mode,
  [string]$InstallRoot = "$env:ProgramData\AROAK\Symphony",
  [string]$RuntimeSource, [string]$BrokerArtifacts, [string]$CodexExe,
  [string]$WorkspaceRoot, [string]$PrivateHomeRoot, [string]$CodexHomeRoot,
  [string]$ScheduledTaskName, [string]$ScheduledTaskPath, [string]$AdmissionPauseFile
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$serviceName = "AROAKSymphonyCodex$Node"
$controller = "SymphonyCtl$Node"
$runtime = Join-Path $InstallRoot "runtime-$RuntimeCommit"
$brokerRoot = Join-Path $InstallRoot "broker-$RuntimeCommit"
$brokerExe = Join-Path $brokerRoot 'Symphony.WindowsBroker.exe'
$installedCodexExe = Join-Path $brokerRoot 'codex.exe'
$brokerConfig = Join-Path $brokerRoot 'broker-settings.json'
$commandWrapper = Join-Path $brokerRoot 'codex-command.ps1'
$commandExample = Join-Path $brokerRoot 'codex-command.example.txt'
$state = Join-Path $InstallRoot "aro197-$($Node.ToLowerInvariant()).json"
$serviceIdentity = "NT SERVICE\$serviceName"

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace ARO197 {
  public sealed class TokenSnapshot {
    public bool Elevated { get; set; }
    public bool AdministratorsEnabled { get; set; }
    public bool AdministratorsDenyOnly { get; set; }
  }

  public static class NativeToken {
    const uint TOKEN_QUERY = 0x0008;
    const uint SE_GROUP_ENABLED = 0x00000004;
    const uint SE_GROUP_USE_FOR_DENY_ONLY = 0x00000010;

    [StructLayout(LayoutKind.Sequential)] struct TOKEN_ELEVATION { public uint TokenIsElevated; }
    [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }

    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int tokenInformationClass, IntPtr information, int length, out int returnLength);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);

    public static TokenSnapshot Capture() {
      IntPtr token = IntPtr.Zero;
      IntPtr buffer = IntPtr.Zero;
      try {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out token)) throw new Win32Exception();
        int size;
        var elevation = new TOKEN_ELEVATION();
        buffer = Marshal.AllocHGlobal(Marshal.SizeOf<TOKEN_ELEVATION>());
        if (!GetTokenInformation(token, 20, buffer, Marshal.SizeOf<TOKEN_ELEVATION>(), out size)) throw new Win32Exception();
        elevation = Marshal.PtrToStructure<TOKEN_ELEVATION>(buffer);
        Marshal.FreeHGlobal(buffer); buffer = IntPtr.Zero;

        GetTokenInformation(token, 2, IntPtr.Zero, 0, out size);
        if (size <= 0) throw new Win32Exception();
        buffer = Marshal.AllocHGlobal(size);
        if (!GetTokenInformation(token, 2, buffer, size, out size)) throw new Win32Exception();
        int count = Marshal.ReadInt32(buffer);
        int offset = IntPtr.Size == 8 ? 8 : 4;
        int stride = Marshal.SizeOf<SID_AND_ATTRIBUTES>();
        bool enabled = false, denyOnly = false;
        for (int index = 0; index < count; index++) {
          var entry = Marshal.PtrToStructure<SID_AND_ATTRIBUTES>(IntPtr.Add(buffer, offset + index * stride));
          var sid = new SecurityIdentifier(entry.Sid).Value;
          if (sid == "S-1-5-32-544") {
            enabled = (entry.Attributes & SE_GROUP_ENABLED) != 0;
            denyOnly = (entry.Attributes & SE_GROUP_USE_FOR_DENY_ONLY) != 0;
          }
        }
        return new TokenSnapshot { Elevated = elevation.TokenIsElevated != 0, AdministratorsEnabled = enabled, AdministratorsDenyOnly = denyOnly };
      } finally {
        if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
        if (token != IntPtr.Zero && !CloseHandle(token)) throw new Win32Exception();
      }
    }
  }
}
'@

function Write-Receipt([string]$result, [bool]$changed, [string]$reason = '') {
  $receipt = [ordered]@{ result = $result; changed = $changed }
  if ($reason) { $receipt.reason = $reason } else {
    $receipt.mode = $Mode; $receipt.node = $Node; $receipt.runtime_commit = $RuntimeCommit
    $receipt.service_state = 'Stopped'
  }
  [Console]::Out.WriteLine(($receipt | ConvertTo-Json -Compress))
}
function Save-RecoveryState($created, $previousAcl) {
  $document = [ordered]@{ schema = 3; node = $Node; runtime_commit = $RuntimeCommit; created = $created; previous_acl = $previousAcl }
  $document | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $state -Encoding UTF8
  Set-ProtectedAcl $state @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller")
}
function Test-Elevated {
  (Get-ExecutionContext).elevated
}
function Get-ExecutionContext {
  $snapshot = [ARO197.NativeToken]::Capture()
  [ordered]@{
    computer_name = [Environment]::MachineName
    identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    elevated = [bool]$snapshot.Elevated
    administrators_sid = 'S-1-5-32-544'
    administrators_enabled = [bool]$snapshot.AdministratorsEnabled
    administrators_deny_only = [bool]$snapshot.AdministratorsDenyOnly
  }
}
function Assert-PlainAbsolutePath([string]$path) {
  if (-not $path -or -not [IO.Path]::IsPathRooted($path)) { throw 'absolute_path_required' }
  $full = [IO.Path]::GetFullPath($path); $cursor = [IO.Path]::GetPathRoot($full)
  foreach ($part in $full.Substring($cursor.Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
    $cursor = Join-Path $cursor $part
    if (Test-Path -LiteralPath $cursor) {
      $item = Get-Item -LiteralPath $cursor -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse_path' }
    }
  }
}
function Assert-AreAllAccessRulesProtected([string]$path) {
  if (-not (Get-Acl -LiteralPath $path).AreAccessRulesProtected) { throw 'acl_inheritance_enabled' }
}
function Set-ProtectedAcl([string]$path, [string[]]$principals, [string]$rights = 'FullControl') {
  $acl = Get-Acl -LiteralPath $path; $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRuleAll($rule) }
  $inheritance = if ((Get-Item -LiteralPath $path -Force) -is [IO.DirectoryInfo]) { 'ContainerInherit,ObjectInherit' } else { 'None' }
  foreach ($name in $principals) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($name, $rights, $inheritance, 'None', 'Allow'))
  }
  Set-Acl -LiteralPath $path -AclObject $acl; Assert-AreAllAccessRulesProtected $path
}
function Set-ProtectedAclRules([string]$path, [object[]]$rules) {
  $acl = Get-Acl -LiteralPath $path; $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRuleAll($rule) }
  $inheritance = if ((Get-Item -LiteralPath $path -Force) -is [IO.DirectoryInfo]) { 'ContainerInherit,ObjectInherit' } else { 'None' }
  foreach ($rule in $rules) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([string]$rule.Principal, [string]$rule.Rights, $inheritance, 'None', 'Allow'))
  }
  Set-Acl -LiteralPath $path -AclObject $acl; Assert-ProtectedAclRules $path $rules
}
function Assert-ProtectedAclRules([string]$path, [object[]]$rules) {
  $acl = Get-Acl -LiteralPath $path
  if (-not $acl.AreAccessRulesProtected) { throw 'acl_inheritance_enabled' }
  $expected = @{}
  foreach ($rule in $rules) {
    $sid = Resolve-AccountSid ([string]$rule.Principal)
    $rights = [int]([Enum]::Parse([Security.AccessControl.FileSystemRights], [string]$rule.Rights))
    $expected[$sid] = $rights
  }
  $actual = @{}
  foreach ($rule in @($acl.Access)) {
    if ($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { throw 'acl_rule_unexpected' }
    $sid = Get-RuleSid $rule.IdentityReference
    if (-not $expected.ContainsKey($sid) -or $actual.ContainsKey($sid)) { throw 'acl_principal_unexpected' }
    $actual[$sid] = ([int]$rule.FileSystemRights -band (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize))
  }
  if ($actual.Count -ne $expected.Count) { throw 'acl_rule_missing' }
  foreach ($sid in $expected.Keys) {
    $expectedRights = ($expected[$sid] -band (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize))
    if (-not $actual.ContainsKey($sid) -or $actual[$sid] -ne $expectedRights) { throw 'acl_rights_mismatch' }
  }
}
function Resolve-AccountSid([string]$name) {
  try { ([Security.Principal.NTAccount]::new($name)).Translate([Security.Principal.SecurityIdentifier]).Value }
  catch { throw 'controller_principal_missing' }
}
function Assert-BrokerArtifactSelfContained([string]$candidateBrokerExe) {
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $probeOutput = (& $candidateBrokerExe --service 2>&1 | Out-String).Trim()
    $probeExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($probeExitCode -ne 1 -or $probeOutput -notmatch 'missing_config') { throw 'broker_artifact_not_self_contained' }
}
function ConvertTo-PowerShellSingleQuotedLiteral([string]$value) {
  "'" + $value.Replace("'", "''") + "'"
}

function Get-RuleSid([Security.Principal.IdentityReference]$identity) {
  try { $identity.Translate([Security.Principal.SecurityIdentifier]).Value }
  catch { throw 'private_key_acl_unresolvable' }
}
function Assert-ControllerSecretBoundary([string]$controllerSid) {
  $keyPath = [Environment]::GetEnvironmentVariable('SYMPHONY_GITHUB_APP_PRIVATE_KEY_FILE', 'Machine')
  if (-not $keyPath -or -not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw 'private_key_missing' }
  Assert-PlainAbsolutePath $keyPath
  $keyParent = Split-Path -Parent $keyPath
  if (-not $keyParent -or -not (Test-Path -LiteralPath $keyParent -PathType Container)) { throw 'private_key_parent_missing' }
  Assert-PlainAbsolutePath $keyParent
  $serviceAccount = [Security.Principal.NTAccount]::new($serviceIdentity)
  $allowedReaders = @(
    $controllerSid,
    ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)).Value,
    ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)).Value
  )
  $readMask = [int]([Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::FullControl)
  $controlMask = [int]([Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor [Security.AccessControl.FileSystemRights]::FullControl)
  foreach ($boundaryPath in @($keyParent, $keyPath)) {
    $keyAcl = Get-Acl -LiteralPath $boundaryPath
    if (-not $keyAcl.AreAccessRulesProtected) { throw 'private_key_acl_inherited' }
    $keyOwner = $keyAcl.Owner
    if ($keyOwner -eq $serviceIdentity) { throw 'private_key_codex_owner' }
    if ((Get-RuleSid ([Security.Principal.NTAccount]::new($keyOwner))) -notin $allowedReaders) { throw 'private_key_owner_not_allowed' }
    foreach ($rule in @($keyAcl.Access)) {
      if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny) { throw 'private_key_deny_rule_unexpected' }
      if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) {
        if ($rule.IdentityReference -eq $serviceAccount -and (([int]$rule.FileSystemRights -band ($readMask -bor $controlMask)) -ne 0)) { throw 'private_key_codex_acl_control' }
        if ((([int]$rule.FileSystemRights -band $controlMask) -ne 0) -and (Get-RuleSid $rule.IdentityReference) -notin $allowedReaders) { throw 'private_key_controller_acl_control' }
        if ((([int]$rule.FileSystemRights -band $readMask) -ne 0) -and (Get-RuleSid $rule.IdentityReference) -notin $allowedReaders) { throw 'private_key_reader_not_allowed' }
      }
    }
  }
}
function Get-ServiceConfiguration {
  $escaped = $serviceName.Replace("'", "''")
  Get-CimInstance Win32_Service -Filter "Name='$escaped'" -ErrorAction Stop
}
function Assert-ServiceConfiguration {
  $service = Get-ServiceConfiguration
  if ($service.StartName -ne $serviceIdentity) { throw 'service_account_mismatch' }
  if ($service.StartMode -ne 'Manual') { throw 'service_start_mode_mismatch' }
  if ($service.State -ne 'Stopped') { throw 'service_not_stopped' }
  $expectedPath = ('"{0}" --service --config "{1}"' -f $brokerExe, $brokerConfig)
  if ($service.PathName -ne $expectedPath) { throw 'service_image_mismatch' }
}
function Write-PlanReceipt {
  $blockers = [Collections.Generic.List[string]]::new()
  try { $context = Get-ExecutionContext }
  catch {
    $context = [ordered]@{ computer_name = [Environment]::MachineName; identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name; elevated = $false; administrators_sid = 'S-1-5-32-544'; administrators_enabled = $false; administrators_deny_only = $false }
    $blockers.Add('execution_context_unproved')
  }
  if (-not $context.elevated) { $blockers.Add('elevation_required') }
  if (-not $context.administrators_enabled) { $blockers.Add('administrators_sid_not_enabled') }
  if ($context.administrators_deny_only) { $blockers.Add('administrators_sid_deny_only') }

  $controllerSid = $null
  try { $controllerSid = Resolve-AccountSid "${env:COMPUTERNAME}\$controller" }
  catch { $blockers.Add('controller_context_unproved') }

  $service = $null
  try { $service = Get-ServiceConfiguration }
  catch {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) { $blockers.Add('service_configuration_unproved') }
  }
  if ($service) {
    if ($service.StartName -ne $serviceIdentity -or $service.StartMode -ne 'Manual' -or $service.State -ne 'Stopped') { $blockers.Add('service_configuration_unproved') }
  }

  $taskState = 'Unknown'
  if ([string]::IsNullOrWhiteSpace($ScheduledTaskName) -or [string]::IsNullOrWhiteSpace($ScheduledTaskPath)) { $blockers.Add('task_state_unproved') }
  else {
    try {
      $task = Get-ScheduledTask -TaskName $ScheduledTaskName -TaskPath $ScheduledTaskPath -ErrorAction Stop
      $taskState = [string]$task.State
      if ($taskState -ne 'Disabled') { $blockers.Add('task_not_disabled') }
    } catch { $blockers.Add('task_state_unproved') }
  }

  $admissionState = 'Unknown'
  if ([string]::IsNullOrWhiteSpace($AdmissionPauseFile)) { $blockers.Add('admission_state_unproved') }
  else {
    try {
      Assert-PlainAbsolutePath $AdmissionPauseFile
      if (-not (Test-Path -LiteralPath $AdmissionPauseFile -PathType Leaf)) { $blockers.Add('admission_not_paused') }
      else { $admissionState = 'Paused' }
    } catch { $blockers.Add('admission_state_unproved') }
  }

  $runtimeInputs = @($RuntimeSource, $BrokerArtifacts, $CodexExe, $WorkspaceRoot, $PrivateHomeRoot, $CodexHomeRoot)
  if ($runtimeInputs.Where({ [string]::IsNullOrWhiteSpace($_) }).Count -ne 0) { $blockers.Add('runtime_input_unproved') }
  else {
    try {
      foreach ($path in $runtimeInputs) { Assert-PlainAbsolutePath $path }
    } catch { $blockers.Add('runtime_input_unproved') }
  }
  if ($controllerSid) {
    try { Assert-ControllerSecretBoundary $controllerSid }
    catch { $blockers.Add('acl_state_unproved') }
  }

  $receipt = [ordered]@{
    result = $(if ($blockers.Count -eq 0) { 'PASS' } else { 'FAIL' })
    changed = $false
    mode = 'Plan'
    node = $Node
    runtime_commit = $RuntimeCommit
    computer_name = $context.computer_name
    identity = $context.identity
    elevated = $context.elevated
    administrators_sid = $context.administrators_sid
    administrators_enabled = $context.administrators_enabled
    administrators_deny_only = $context.administrators_deny_only
    controller_sid = $controllerSid
    service_exists = [bool]$service
    service_account = $(if ($service) { [string]$service.StartName } else { $null })
    service_start_mode = $(if ($service) { [string]$service.StartMode } else { $null })
    service_state = $(if ($service) { [string]$service.State } else { 'Absent' })
    task_state = $taskState
    admission_state = $admissionState
    proposed_changes = @('install_versioned_runtime', 'install_broker', 'configure_virtual_service_account', 'apply_protected_acls', 'leave_service_manual_stopped')
    blockers = @($blockers)
  }
  [Console]::Out.WriteLine(($receipt | ConvertTo-Json -Compress -Depth 4))
  if ($blockers.Count -eq 0) { exit 0 } else { exit 20 }
}
function Restore-Acls($previousAcl) {
  if (-not $previousAcl) { return }
  foreach ($property in $previousAcl.PSObject.Properties) {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm([string]$property.Value)
    Set-Acl -LiteralPath $property.Name -AclObject $acl
  }
}
function Remove-CreatedResources($created, $previousAcl) {
  if ($created.service) {
    $script:stage = 'rollback_service'
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0 -and (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) { throw 'service_delete_failed' }
    $created.service = $false
    if (Test-Path -LiteralPath $state -PathType Leaf) { Save-RecoveryState $created $previousAcl }
  }
  $script:stage = 'rollback_files'
  if ($created.config -and (Test-Path -LiteralPath $brokerConfig)) { Remove-Item -LiteralPath $brokerConfig -Force; $created.config = $false; if (Test-Path -LiteralPath $state -PathType Leaf) { Save-RecoveryState $created $previousAcl } }
  if ($created.broker -and (Test-Path -LiteralPath $brokerRoot)) { Remove-Item -LiteralPath $brokerRoot -Recurse -Force; $created.broker = $false; if (Test-Path -LiteralPath $state -PathType Leaf) { Save-RecoveryState $created $previousAcl } }
  if ($created.runtime -and (Test-Path -LiteralPath $runtime)) { Remove-Item -LiteralPath $runtime -Recurse -Force; $created.runtime = $false; if (Test-Path -LiteralPath $state -PathType Leaf) { Save-RecoveryState $created $previousAcl } }
  $script:stage = 'rollback_acls'; Restore-Acls $previousAcl
  if ($created.acls) { $created.acls = $false; if (Test-Path -LiteralPath $state -PathType Leaf) { Save-RecoveryState $created $previousAcl } }
  $script:stage = 'rollback_state'
  if ($created.state -and (Test-Path -LiteralPath $state)) { Remove-Item -LiteralPath $state -Force; $created.state = $false }
}

if ($Mode -eq 'Plan') { Assert-PlainAbsolutePath $InstallRoot; Write-PlanReceipt }
if (-not (Test-Elevated)) { Write-Receipt 'FAIL' $false 'elevation_required'; exit 20 }
Assert-PlainAbsolutePath $InstallRoot
$created = [ordered]@{ runtime = $false; broker = $false; config = $false; service = $false; state = $false; acls = $false }
$previousAcl = [ordered]@{}
$stage = 'validate'
try {
  if ($Mode -eq 'Rollback') {
    $stage = 'rollback_manifest'
    if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { throw 'state_missing' }
    $saved = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
    if ($saved.schema -ne 3 -or $saved.node -ne $Node -or $saved.runtime_commit -ne $RuntimeCommit) { throw 'state_mismatch' }
    $saved.created.state = $false
    Remove-CreatedResources $saved.created $saved.previous_acl
    $stage = 'rollback_state'
    Remove-Item -LiteralPath $state -Force
    Write-Receipt 'PASS' $true; exit 0
  }
  foreach ($path in @($RuntimeSource, $BrokerArtifacts, $CodexExe, $WorkspaceRoot, $PrivateHomeRoot, $CodexHomeRoot)) { Assert-PlainAbsolutePath $path }
  if (-not (Test-Path -LiteralPath $RuntimeSource -PathType Container)) { throw 'runtime_source_required' }
  if (-not (Test-Path -LiteralPath $BrokerArtifacts -PathType Container)) { throw 'broker_artifacts_required' }
  $sourceBrokerExe = Join-Path $BrokerArtifacts 'Symphony.WindowsBroker.exe'
  if (-not (Test-Path -LiteralPath $sourceBrokerExe -PathType Leaf)) { throw 'broker_binary_missing' }
  Assert-BrokerArtifactSelfContained $sourceBrokerExe
  if (-not (Test-Path -LiteralPath $CodexExe -PathType Leaf)) { throw 'codex_exe_missing' }
  foreach ($path in @($WorkspaceRoot, $PrivateHomeRoot, $CodexHomeRoot)) { if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'broker_root_missing' } }
  foreach ($profile in @('central-brain', 'project-management')) {
    foreach ($path in @((Join-Path $WorkspaceRoot $profile), (Join-Path $PrivateHomeRoot $profile), (Join-Path $CodexHomeRoot $profile))) {
      if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'broker_profile_root_missing' }
    }
  }
  if ((git -C $RuntimeSource rev-parse HEAD).Trim() -ne $RuntimeCommit) { throw 'runtime_commit_mismatch' }
  if (git -C $RuntimeSource status --porcelain) { throw 'runtime_source_dirty' }
  if (Test-Path -LiteralPath $state) { throw 'state_already_exists' }
  if (Test-Path -LiteralPath $runtime) { throw 'runtime_already_exists' }
  if (Test-Path -LiteralPath $brokerRoot) { throw 'broker_already_exists' }
  if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) { throw 'service_already_exists' }
  $controllerSid = Resolve-AccountSid "${env:COMPUTERNAME}\$controller"; Assert-ControllerSecretBoundary $controllerSid
  $stage = 'runtime'
  New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
  if (-not $previousAcl.Contains($InstallRoot)) { $previousAcl[$InstallRoot] = (Get-Acl -LiteralPath $InstallRoot).Sddl }
  $created.state = $true; Save-RecoveryState $created $previousAcl
  Set-ProtectedAcl $InstallRoot @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller")
  New-Item -ItemType Directory -Path $runtime | Out-Null; $created.runtime = $true; Save-RecoveryState $created $previousAcl
  & git clone --no-local --no-checkout -- $RuntimeSource $runtime | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'runtime_copy_failed' }
  & git -C $runtime checkout --detach $RuntimeCommit | Out-Null
  if ($LASTEXITCODE -ne 0 -or (git -C $runtime rev-parse HEAD).Trim() -ne $RuntimeCommit -or (git -C $runtime status --porcelain)) {
    throw 'runtime_attestation_failed'
  }
  $stage = 'broker_files'
  New-Item -ItemType Directory -Path $brokerRoot | Out-Null; $created.broker = $true; Save-RecoveryState $created $previousAcl
  Copy-Item -Path (Join-Path $BrokerArtifacts '*') -Destination $brokerRoot -Recurse -Force
  Copy-Item -LiteralPath $CodexExe -Destination $installedCodexExe
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $CodexExe).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $installedCodexExe).Hash) { throw 'codex_copy_attestation_failed' }
  $settings = [ordered]@{ schema = 1; node = $Node; pipe_name = "aroak-symphony-codex-$($Node.ToLowerInvariant())"; service_name = $serviceName; controller_sid = $controllerSid; workspace_root = [IO.Path]::GetFullPath($WorkspaceRoot); private_home_root = [IO.Path]::GetFullPath($PrivateHomeRoot); codex_home_root = [IO.Path]::GetFullPath($CodexHomeRoot); codex_exe = $installedCodexExe }
  $settings | ConvertTo-Json | Set-Content -LiteralPath $brokerConfig -Encoding UTF8; $created.config = $true; Save-RecoveryState $created $previousAcl
  $workspaceRootLiteral = ConvertTo-PowerShellSingleQuotedLiteral ([IO.Path]::GetFullPath($WorkspaceRoot))
  $brokerExeLiteral = ConvertTo-PowerShellSingleQuotedLiteral $brokerExe
  $pipeNameLiteral = ConvertTo-PowerShellSingleQuotedLiteral $settings.pipe_name
  $serviceNameLiteral = ConvertTo-PowerShellSingleQuotedLiteral $serviceName
  @"
`$ErrorActionPreference = 'Stop'
`$workspaceRoot = $workspaceRootLiteral
`$brokerService = Get-Service -Name $serviceNameLiteral -ErrorAction Stop
if (`$brokerService.Status -ne 'Running') { throw 'broker_service_not_running' }
`$workspace = [IO.Path]::GetFullPath((Get-Location).ProviderPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
`$workspaceRootFull = [IO.Path]::GetFullPath(`$workspaceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if (`$workspace.Length -le `$workspaceRootFull.Length -or !`$workspace.StartsWith(`$workspaceRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'workspace_outside_root' }
`$relativeWorkspace = `$workspace.Substring(`$workspaceRootFull.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
`$profile = (`$relativeWorkspace -split '[\\/]')[0]
if (`$profile -notin @('central-brain', 'project-management')) { throw 'profile_denied' }
& $brokerExeLiteral --client --pipe $pipeNameLiteral --profile `$profile --workspace `$workspace
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $commandWrapper -Encoding UTF8
  ('codex.command: "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{0}\""' -f $commandWrapper) | Set-Content -LiteralPath $commandExample -Encoding UTF8
  $stage = 'service_create'
  New-Service -Name $serviceName -BinaryPathName ('"{0}" --service --config "{1}"' -f $brokerExe, $brokerConfig) -StartupType Manual -DisplayName "AROAK Symphony Codex Broker ($Node)" | Out-Null
  $created.service = $true; Save-RecoveryState $created $previousAcl
  $stage = 'service_identity'
  & sc.exe config $serviceName obj= $serviceIdentity | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'service_identity_failed' }
  $stage = 'service_sid'
  & sc.exe sidtype $serviceName restricted | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'service_sid_failed' }
  Assert-ServiceConfiguration
  $stage = 'shared_acls'
  $profileAclRoots = foreach ($profile in @('central-brain', 'project-management')) {
    Join-Path $WorkspaceRoot $profile
    Join-Path $PrivateHomeRoot $profile
    Join-Path $CodexHomeRoot $profile
  }
  foreach ($path in @($WorkspaceRoot, $PrivateHomeRoot, $CodexHomeRoot) + $profileAclRoots) {
    $previousAcl[$path] = (Get-Acl -LiteralPath $path).Sddl
  }
  Save-RecoveryState $created $previousAcl
  Set-ProtectedAclRules $WorkspaceRoot @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'FullControl' },
    @{ Principal = $serviceIdentity; Rights = 'ReadAndExecute' }
  )
  Set-ProtectedAclRules $PrivateHomeRoot @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'FullControl' },
    @{ Principal = $serviceIdentity; Rights = 'ReadAndExecute' }
  )
  Set-ProtectedAclRules $CodexHomeRoot @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'FullControl' },
    @{ Principal = $serviceIdentity; Rights = 'ReadAndExecute' }
  )
  foreach ($path in $profileAclRoots) {
    Set-ProtectedAclRules $path @(
      @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
      @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'FullControl' },
      @{ Principal = $serviceIdentity; Rights = 'Modify' }
    )
  }
  $created.acls = $true; Save-RecoveryState $created $previousAcl
  $stage = 'installed_acls'
  Set-ProtectedAclRules $InstallRoot @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'FullControl' },
    @{ Principal = $serviceIdentity; Rights = 'ReadAndExecute' }
  )
  Set-ProtectedAclRules $runtime @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'ReadAndExecute' }
  )
  Set-ProtectedAclRules $brokerRoot @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'ReadAndExecute' },
    @{ Principal = $serviceIdentity; Rights = 'ReadAndExecute' }
  )
  Set-ProtectedAclRules $brokerConfig @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = $serviceIdentity; Rights = 'ReadAndExecute' }
  )
  $stage = 'state'
  Save-RecoveryState $created $previousAcl
  Set-ProtectedAcl $state @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller")
  Assert-ServiceConfiguration
  Write-Receipt 'PASS' $true
} catch {
  $failedStage = $stage
  $failureType = $_.Exception.GetType().Name
  try { Remove-CreatedResources $created ([pscustomobject]$previousAcl) }
  catch { Write-Receipt 'FAIL' $false "cleanup_failed_$($stage)_$($_.Exception.GetType().Name)"; exit 22 }
  Write-Receipt 'FAIL' $false "install_failed_$($failedStage)_$failureType"; exit 21
}
