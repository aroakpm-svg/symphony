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
$commandWrapper = Join-Path $brokerRoot 'codex-command.ps1'
$commandExample = Join-Path $brokerRoot 'codex-command.example.txt'
$grantManifest = Join-Path $brokerRoot 'outstanding-grants.json'
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
function Save-RecoveryState($created, $previousAcl) {
  $document = [ordered]@{ schema = 2; node = $Node; runtime_commit = $RuntimeCommit; created = $created; previous_acl = $previousAcl }
  $document | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $state -Encoding UTF8
  Set-ProtectedAcl $state @('BUILTIN\Administrators', "${env:COMPUTERNAME}\$controller")
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
function Set-ProtectedAclRules([string]$path, [object[]]$rules) {
  $acl = Get-Acl -LiteralPath $path; $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRuleAll($rule) }
  $inheritance = if ((Get-Item -LiteralPath $path -Force) -is [IO.DirectoryInfo]) { 'ContainerInherit,ObjectInherit' } else { 'None' }
  foreach ($rule in $rules) {
    $ruleInheritance = if ($null -ne $rule.Inheritance) { [string]$rule.Inheritance } else { $inheritance }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([string]$rule.Principal, [string]$rule.Rights, $ruleInheritance, 'None', 'Allow'))
  }
  Set-Acl -LiteralPath $path -AclObject $acl; Assert-AreAllAccessRulesProtected $path
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
function Test-SafeAncestorRights([Security.AccessControl.FileSystemRights]$value) {
  [int64]$rights = [int64][int]$value
  if ($rights -lt 0) { $rights += 0x100000000L }
  if (($rights -band (-bnot 0xF01F01FFL)) -ne 0) { return $false }
  [int64]$mapped = $rights
  if (($rights -band 0x80000000L) -ne 0) { $mapped = $mapped -bor 0x00120089L }
  if (($rights -band 0x40000000L) -ne 0) { $mapped = $mapped -bor 0x00120116L }
  if (($rights -band 0x20000000L) -ne 0) { $mapped = $mapped -bor 0x001200A0L }
  if (($rights -band 0x10000000L) -ne 0) { $mapped = $mapped -bor 0x001F01FFL }
  $mapped = $mapped -band 0x001F01FFL
  (($mapped -band 0x001200ADL) -eq $mapped)
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
  $trustedInstallerSid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
  $trustedAncestorSids = @($allowedReaders) + @($trustedInstallerSid)
  $ancestor = [IO.Directory]::GetParent($keyParent)
  while ($null -ne $ancestor) {
    $ancestorAcl = Get-Acl -LiteralPath $ancestor.FullName
    $ancestorOwnerSid = Get-RuleSid ([Security.Principal.NTAccount]::new($ancestorAcl.Owner))
    if ($ancestorOwnerSid -notin $trustedAncestorSids) { throw 'private_key_ancestor_owner_untrusted' }
    foreach ($rule in @($ancestorAcl.Access)) {
      if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
          ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0 -and
          (Get-RuleSid $rule.IdentityReference) -notin $trustedAncestorSids -and
          -not (Test-SafeAncestorRights $rule.FileSystemRights)) {
        throw 'private_key_ancestor_acl_control'
      }
    }
    $ancestor = $ancestor.Parent
  }
  foreach ($boundaryPath in @($keyParent, $keyPath)) {
    $keyAcl = Get-Acl -LiteralPath $boundaryPath
    if (-not $keyAcl.AreAccessRulesProtected) { throw 'private_key_acl_inherited' }
    $keyOwner = $keyAcl.Owner
    if ($keyOwner -eq $serviceIdentity) { throw 'private_key_codex_owner' }
    if ((Get-RuleSid ([Security.Principal.NTAccount]::new($keyOwner))) -ne $controllerSid) { throw 'private_key_owner_not_controller' }
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
function Restore-Acls($previousAcl) {
  if (-not $previousAcl) { return }
  foreach ($property in $previousAcl.PSObject.Properties) {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm([string]$property.Value)
    Set-Acl -LiteralPath $property.Name -AclObject $acl
  }
}
function Revoke-OutstandingBrokerGrants {
  if (-not (Test-Path -LiteralPath $grantManifest -PathType Leaf)) { throw 'broker_grant_manifest_invalid' }
  $mutex = New-Object System.Threading.Mutex($false, "Global\AROAKSymphonyCodex-$Node")
  $lockHeld = $false
  try {
    try { $lockHeld = $mutex.WaitOne(30000) }
    catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw 'broker_acl_busy' }
    try { $grantDocument = Get-Content -LiteralPath $grantManifest -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'broker_grant_manifest_invalid' }
    if ($grantDocument.schema -ne 1 -or $null -eq $grantDocument.grant_paths) { throw 'broker_grant_manifest_invalid' }
    $grantPaths = @($grantDocument.grant_paths)
    [array]::Reverse($grantPaths)
    foreach ($grantPath in $grantPaths) {
      if ($grantPath -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($grantPath)) { throw 'broker_grant_manifest_invalid' }
      if (-not (Test-Path -LiteralPath $grantPath)) { throw 'broker_stale_grant_path_missing' }
      & icacls.exe $grantPath /remove:g $serviceIdentity | Out-Null
      if ($LASTEXITCODE) { throw 'broker_stale_revoke_failed' }
      & icacls.exe $grantPath /remove:d $serviceIdentity | Out-Null
      if ($LASTEXITCODE) { throw 'broker_stale_revoke_failed' }
    }
    [ordered]@{ schema = 1; grant_paths = @() } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $grantManifest -Encoding UTF8
  } finally {
    if ($lockHeld) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}
function Remove-CreatedResources($created, $previousAcl) {
  if ($created.service) {
    $script:stage = 'rollback_service'
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
  }
  if ($created.service -or (Test-Path -LiteralPath $grantManifest -PathType Leaf)) {
    $script:stage = 'rollback_grants'
    Revoke-OutstandingBrokerGrants
  }
  if ($created.service) {
    $script:stage = 'rollback_service'
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

if ($Mode -eq 'Plan') { Assert-PlainAbsolutePath $InstallRoot; Write-Receipt 'PASS' $false; exit 0 }
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
    if ($saved.schema -ne 2 -or $saved.node -ne $Node -or $saved.runtime_commit -ne $RuntimeCommit) { throw 'state_mismatch' }
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
  $controllerSid = Resolve-AccountSid "${env:COMPUTERNAME}\$controller"
  Assert-ControllerSecretBoundary $controllerSid
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
  [ordered]@{ schema = 1; grant_paths = @() } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $grantManifest -Encoding UTF8
  $workspaceRootLiteral = ConvertTo-PowerShellSingleQuotedLiteral ([IO.Path]::GetFullPath($WorkspaceRoot))
  $brokerExeLiteral = ConvertTo-PowerShellSingleQuotedLiteral $brokerExe
  $pipeNameLiteral = ConvertTo-PowerShellSingleQuotedLiteral $settings.pipe_name
  $serviceNameLiteral = ConvertTo-PowerShellSingleQuotedLiteral $serviceName
  $grantManifestLiteral = ConvertTo-PowerShellSingleQuotedLiteral $grantManifest
  @"
`$ErrorActionPreference = 'Stop'
`$cleanupSafeToAcknowledge = `$true
`$cleanupAcknowledged = `$false
try {
`$workspaceRoot = $workspaceRootLiteral
`$grantManifest = $grantManifestLiteral
`$codexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
`$privateHome = [Environment]::GetEnvironmentVariable('HOME', 'Process')
if ([string]::IsNullOrWhiteSpace(`$privateHome)) { `$privateHome = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process') }
if ([string]::IsNullOrWhiteSpace(`$codexHome)) { throw 'codex_home_missing' }
if ([string]::IsNullOrWhiteSpace(`$privateHome)) { throw 'private_home_missing' }
`$brokerService = Get-Service -Name $serviceNameLiteral -ErrorAction Stop
if (`$brokerService.Status -ne 'Running') { throw 'broker_service_not_running' }
`$workspace = [IO.Path]::GetFullPath((Get-Location).ProviderPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
`$workspaceRootFull = [IO.Path]::GetFullPath(`$workspaceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if (`$workspace.Length -le `$workspaceRootFull.Length -or !`$workspace.StartsWith(`$workspaceRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'workspace_outside_root' }
`$relativeWorkspace = `$workspace.Substring(`$workspaceRootFull.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
`$profile = (`$relativeWorkspace -split '[\\/]')[0]
if (`$profile -notin @('central-brain', 'project-management')) { throw 'profile_denied' }
`$privateHomeChildren = foreach (`$leaf in @('gh', 'xdg-config', 'xdg-cache', 'xdg-data', 'codex')) {
  `$child = Join-Path `$privateHome `$leaf
  if (!(Test-Path -LiteralPath `$child -PathType Container)) { throw 'private_home_component_missing' }
  `$item = Get-Item -LiteralPath `$child -Force
  if ((`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'private_home_component_reparse' }
  `$item.FullName
}
`$grantPaths = @(`$workspace, `$privateHome) + @(`$privateHomeChildren) + @(`$codexHome)
`$mutex = New-Object System.Threading.Mutex(`$false, 'Global\AROAKSymphonyCodex-$($Node)')
`$lockHeld = `$false
`$currentGrantIntentPersisted = `$false
try {
  try { `$lockHeld = `$mutex.WaitOne(0) }
  catch [Threading.AbandonedMutexException] { `$lockHeld = `$true }
  if (!`$lockHeld) { throw 'broker_acl_busy' }
  `$cleanupSafeToAcknowledge = `$false

  if (!(Test-Path -LiteralPath `$grantManifest -PathType Leaf)) { throw 'broker_grant_manifest_invalid' }
  try { `$staleGrantDocument = Get-Content -LiteralPath `$grantManifest -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { throw 'broker_grant_manifest_invalid' }
  if (`$staleGrantDocument.schema -ne 1 -or `$null -eq `$staleGrantDocument.grant_paths) { throw 'broker_grant_manifest_invalid' }
  `$stalePaths = @(`$staleGrantDocument.grant_paths)
  [array]::Reverse(`$stalePaths)
  foreach (`$grantPath in `$stalePaths) {
    if (`$grantPath -isnot [string] -or ![IO.Path]::IsPathFullyQualified(`$grantPath)) { throw 'broker_grant_manifest_invalid' }
    if (!(Test-Path -LiteralPath `$grantPath)) { throw 'broker_stale_grant_path_missing' }
    & icacls.exe `$grantPath /remove:g '$($serviceIdentity)' | Out-Null
    if (`$LASTEXITCODE) { throw 'broker_stale_revoke_failed' }
    & icacls.exe `$grantPath /remove:d '$($serviceIdentity)' | Out-Null
    if (`$LASTEXITCODE) { throw 'broker_stale_revoke_failed' }
  }
  [ordered]@{ schema = 1; grant_paths = @() } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath `$grantManifest -Encoding UTF8
  `$cleanupSafeToAcknowledge = `$true

  `$cleanupSafeToAcknowledge = `$false
  `$grantDocument = [ordered]@{ schema = 1; grant_paths = @(`$grantPaths) }
  `$grantDocument | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath `$grantManifest -Encoding UTF8
  `$currentGrantIntentPersisted = `$true
  foreach (`$grantPath in `$grantPaths) {
    & icacls.exe `$grantPath /deny '$($serviceIdentity):(D)' | Out-Null
    if (`$LASTEXITCODE) { throw 'broker_grant_failed' }
    & icacls.exe `$grantPath /grant '$($serviceIdentity):(OI)(CI)(M)' | Out-Null
    if (`$LASTEXITCODE) { throw 'broker_grant_failed' }
  }
  & $brokerExeLiteral --client --pipe $pipeNameLiteral --profile `$profile --workspace `$workspace --private-home `$privateHome --codex-home `$codexHome
  exit `$LASTEXITCODE
} finally {
  try {
    `$cleanupOk = `$true
    if (`$lockHeld -and `$currentGrantIntentPersisted) {
      `$revokePaths = @(`$grantPaths)
      [array]::Reverse(`$revokePaths)
      foreach (`$grantPath in `$revokePaths) {
        & icacls.exe `$grantPath /remove:g '$($serviceIdentity)' | Out-Null
        if (`$LASTEXITCODE) { `$cleanupOk = `$false }
        & icacls.exe `$grantPath /remove:d '$($serviceIdentity)' | Out-Null
        if (`$LASTEXITCODE) { `$cleanupOk = `$false }
      }
    }
    if (`$cleanupOk -and `$currentGrantIntentPersisted) {
      [ordered]@{ schema = 1; grant_paths = @() } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath `$grantManifest -Encoding UTF8
      `$cleanupSafeToAcknowledge = `$true
    } elseif (!`$cleanupOk) {
      throw 'broker_revoke_failed'
    }
  } finally {
    if (`$lockHeld) { `$mutex.ReleaseMutex() }
    `$mutex.Dispose()
  }
}
} finally {
  if (`$cleanupSafeToAcknowledge -and !`$cleanupAcknowledged -and ![string]::IsNullOrWhiteSpace(`$env:SYMPHONY_BROKER_CLEANUP_ACK)) { Set-Content -LiteralPath `$env:SYMPHONY_BROKER_CLEANUP_ACK -Value 'done' -Encoding ASCII }
}
"@ | Set-Content -LiteralPath $commandWrapper -Encoding UTF8
  $yamlCommand = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $commandWrapper).Replace("'", "''")
  ("codex.command: '{0}'" -f $yamlCommand) | Set-Content -LiteralPath $commandExample -Encoding UTF8
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
    @{ Principal = $serviceIdentity; Rights = 'ReadAttributes, Traverse'; Inheritance = 'None' }
  )
  Set-ProtectedAclRules $CodexHomeRoot @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'FullControl' },
    @{ Principal = $serviceIdentity; Rights = 'ReadAttributes, Traverse'; Inheritance = 'None' }
  )
  foreach ($path in $profileAclRoots) {
    Set-ProtectedAclRules $path @(
      @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
      @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'FullControl' },
      @{ Principal = $serviceIdentity; Rights = 'ReadAttributes, Traverse'; Inheritance = 'None' }
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
  Set-ProtectedAclRules $grantManifest @(
    @{ Principal = 'BUILTIN\Administrators'; Rights = 'FullControl' },
    @{ Principal = "${env:COMPUTERNAME}\$controller"; Rights = 'FullControl' }
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
  $failureMessage = [string]$_.Exception.Message
  $failureCode = if ($failureMessage -match '^private_key_[a-z_]+$') { $failureMessage } else { $failureType }
  try { Remove-CreatedResources $created ([pscustomobject]$previousAcl) }
  catch { Write-Receipt 'FAIL' $false "cleanup_failed_$($stage)_$($_.Exception.GetType().Name)"; exit 22 }
  Write-Receipt 'FAIL' $false "install_failed_$($failedStage)_$failureCode"; exit 21
}
