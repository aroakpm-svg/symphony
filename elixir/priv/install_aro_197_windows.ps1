[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Amy', 'Matt')][string]$Node,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$RuntimeCommit,
  [Parameter(Mandatory)][ValidateSet('Plan', 'Install', 'Rollback')][string]$Mode,
  [string]$InstallRoot = "$env:ProgramData\AROAK\Symphony",
  [string]$RuntimeSource, [string]$BrokerArtifacts, [string]$CodexExe,
  [string]$WorkspaceRoot, [string]$PrivateHomeRoot, [string]$CodexHomeRoot
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
$commandExample = Join-Path $brokerRoot 'codex-command.example.txt'
$state = Join-Path $InstallRoot "aro197-$($Node.ToLowerInvariant()).json"
$serviceIdentity = "NT SERVICE\$serviceName"

function Write-Receipt([string]$result, [bool]$changed, [string]$reason = '') {
  $receipt = [ordered]@{ result = $result; changed = $changed }
  if ($reason) { $receipt.reason = $reason } else {
    $receipt.mode = $Mode; $receipt.node = $Node; $receipt.runtime_commit = $RuntimeCommit
    $receipt.service_state = 'Stopped'
  }
  [Console]::Out.WriteLine(($receipt | ConvertTo-Json -Compress))
}
function Test-Elevated {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
function Resolve-AccountSid([string]$name) {
  try { ([Security.Principal.NTAccount]::new($name)).Translate([Security.Principal.SecurityIdentifier]).Value }
  catch { throw 'controller_principal_missing' }
}
function Get-RuleSid([Security.Principal.IdentityReference]$identity) {
  try { $identity.Translate([Security.Principal.SecurityIdentifier]).Value }
  catch { throw 'private_key_acl_unresolvable' }
}
function Assert-ControllerSecretBoundary([string]$controllerSid) {
  $keyPath = [Environment]::GetEnvironmentVariable('SYMPHONY_GITHUB_APP_PRIVATE_KEY_FILE', 'Machine')
  if (-not $keyPath -or -not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw 'private_key_missing' }
  Assert-PlainAbsolutePath $keyPath; $keyAcl = Get-Acl -LiteralPath $keyPath
  if (-not $keyAcl.AreAccessRulesProtected) { throw 'private_key_acl_inherited' }
  $allowedReaders = @(
    $controllerSid,
    ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)).Value,
    ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)).Value
  )
  $readMask = [int]([Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::FullControl)
  foreach ($rule in @($keyAcl.Access)) {
    if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and (([int]$rule.FileSystemRights -band $readMask) -ne 0)) {
      if ((Get-RuleSid $rule.IdentityReference) -notin $allowedReaders) { throw 'private_key_reader_not_allowed' }
    }
  }
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
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'service_delete_failed' }
  }
  if ($created.config -and (Test-Path -LiteralPath $brokerConfig)) { Remove-Item -LiteralPath $brokerConfig -Force }
  if ($created.broker -and (Test-Path -LiteralPath $brokerRoot)) { Remove-Item -LiteralPath $brokerRoot -Recurse -Force }
  if ($created.runtime -and (Test-Path -LiteralPath $runtime)) { Remove-Item -LiteralPath $runtime -Recurse -Force }
  Restore-Acls $previousAcl
  if ($created.state -and (Test-Path -LiteralPath $state)) { Remove-Item -LiteralPath $state -Force }
}

if ($Mode -eq 'Plan') { Assert-PlainAbsolutePath $InstallRoot; Write-Receipt 'PASS' $false; exit 0 }
if (-not (Test-Elevated)) { Write-Receipt 'FAIL' $false 'elevation_required'; exit 20 }
Assert-PlainAbsolutePath $InstallRoot
$created = [ordered]@{ runtime = $false; broker = $false; config = $false; service = $false; state = $false; acls = $false }
$previousAcl = [ordered]@{}
try {
  if ($Mode -eq 'Rollback') {
    if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { throw 'state_missing' }
    $saved = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
    if ($saved.schema -ne 2 -or $saved.node -ne $Node -or $saved.runtime_commit -ne $RuntimeCommit) { throw 'state_mismatch' }
    Remove-CreatedResources $saved.created $saved.previous_acl
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Force }
    Write-Receipt 'PASS' $true; exit 0
  }
  foreach ($path in @($RuntimeSource, $BrokerArtifacts, $CodexExe, $WorkspaceRoot, $PrivateHomeRoot, $CodexHomeRoot)) { Assert-PlainAbsolutePath $path }
  if (-not (Test-Path -LiteralPath $RuntimeSource -PathType Container)) { throw 'runtime_source_required' }
  if (-not (Test-Path -LiteralPath $BrokerArtifacts -PathType Container)) { throw 'broker_artifacts_required' }
  if (-not (Test-Path -LiteralPath (Join-Path $BrokerArtifacts 'Symphony.WindowsBroker.exe') -PathType Leaf)) { throw 'broker_binary_missing' }
  if (-not (Test-Path -LiteralPath $CodexExe -PathType Leaf)) { throw 'codex_exe_missing' }
  foreach ($path in @($WorkspaceRoot, $PrivateHomeRoot, $CodexHomeRoot)) { if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'broker_root_missing' } }
  if ((git -C $RuntimeSource rev-parse HEAD).Trim() -ne $RuntimeCommit) { throw 'runtime_commit_mismatch' }
  if (git -C $RuntimeSource status --porcelain) { throw 'runtime_source_dirty' }
  if (Test-Path -LiteralPath $state) { throw 'state_already_exists' }
  if (Test-Path -LiteralPath $runtime) { throw 'runtime_already_exists' }
  if (Test-Path -LiteralPath $brokerRoot) { throw 'broker_already_exists' }
  if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) { throw 'service_already_exists' }
  $controllerSid = Resolve-AccountSid "${env:COMPUTERNAME}\$controller"; Assert-ControllerSecretBoundary $controllerSid
  New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
  & git clone --no-local --no-checkout -- $RuntimeSource $runtime | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'runtime_copy_failed' }
  $created.runtime = $true
  & git -C $runtime checkout --detach $RuntimeCommit | Out-Null
  if ($LASTEXITCODE -ne 0 -or (git -C $runtime rev-parse HEAD).Trim() -ne $RuntimeCommit -or (git -C $runtime status --porcelain)) {
    throw 'runtime_attestation_failed'
  }
  Copy-Item -LiteralPath $BrokerArtifacts -Destination $brokerRoot -Recurse; $created.broker = $true
  Copy-Item -LiteralPath $CodexExe -Destination $installedCodexExe
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $CodexExe).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $installedCodexExe).Hash) { throw 'codex_copy_attestation_failed' }
  $settings = [ordered]@{ schema = 1; node = $Node; pipe_name = "aroak-symphony-codex-$($Node.ToLowerInvariant())"; controller_sid = $controllerSid; workspace_root = [IO.Path]::GetFullPath($WorkspaceRoot); private_home_root = [IO.Path]::GetFullPath($PrivateHomeRoot); codex_home_root = [IO.Path]::GetFullPath($CodexHomeRoot); codex_exe = $installedCodexExe }
  $settings | ConvertTo-Json | Set-Content -LiteralPath $brokerConfig -Encoding UTF8; $created.config = $true
  ('codex.command: "\"{0}\" --client --pipe {1} --profile <profile> --workspace <issue-workspace> --private-home <issue-private-home> --codex-home <profile-codex-home>"' -f $brokerExe, $settings.pipe_name) | Set-Content -LiteralPath $commandExample -Encoding UTF8
  New-Service -Name $serviceName -BinaryPathName ('"{0}" --service --config "{1}"' -f $brokerExe, $brokerConfig) -StartupType Manual -DisplayName "AROAK Symphony Codex Broker ($Node)" | Out-Null
  $created.service = $true
  & sc.exe config $serviceName obj= $serviceIdentity password= '' | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'service_identity_failed' }
  & sc.exe sidtype $serviceName restricted | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'service_sid_failed' }
  foreach ($path in @($WorkspaceRoot, $PrivateHomeRoot, $CodexHomeRoot)) {
    $previousAcl[$path] = (Get-Acl -LiteralPath $path).Sddl
  }
  Set-ProtectedAcl $WorkspaceRoot @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller", $serviceIdentity) 'Modify'
  Set-ProtectedAcl $PrivateHomeRoot @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller", $serviceIdentity) 'Modify'
  Set-ProtectedAcl $CodexHomeRoot @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller", $serviceIdentity) 'Modify'
  $created.acls = $true
  Set-ProtectedAcl $runtime @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller") 'ReadAndExecute'
  Set-ProtectedAcl $brokerRoot @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller", $serviceIdentity) 'ReadAndExecute'
  Set-ProtectedAcl $brokerConfig @('BUILTIN\Administrators', $serviceIdentity) 'ReadAndExecute'
  $document = [ordered]@{ schema = 2; node = $Node; runtime_commit = $RuntimeCommit; created = $created; previous_acl = $previousAcl }
  $created.state = $true; $document.created.state = $true
  $document | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $state -Encoding UTF8
  Set-ProtectedAcl $state @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller")
  if ((Get-Service -Name $serviceName).Status -ne 'Stopped') { throw 'service_not_stopped' }
  Write-Receipt 'PASS' $true
} catch {
  Remove-CreatedResources $created ([pscustomobject]$previousAcl)
  Write-Receipt 'FAIL' $false 'install_failed'; exit 21
}
