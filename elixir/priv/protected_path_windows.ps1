$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
  $path = $env:SYMPHONY_PROTECTED_PATH_TARGET
  if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) {
    throw 'invalid_path'
  }

  $item = Get-Item -LiteralPath $path -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'reparse_point'
  }

  $sections = [Security.AccessControl.AccessControlSections](
    [Security.AccessControl.AccessControlSections]::Owner -bor
    [Security.AccessControl.AccessControlSections]::Access
  )

  if ($item.PSIsContainer) {
    $acl = [IO.DirectoryInfo]::new($item.FullName).GetAccessControl($sections)
  } else {
    $acl = [IO.FileInfo]::new($item.FullName).GetAccessControl($sections)
  }

  $rules = @(
    $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
      ForEach-Object {
        [ordered]@{
          sid = $_.IdentityReference.Value
          type = $_.AccessControlType.ToString()
          rights = [long]$_.FileSystemRights
        }
      }
  )

  $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
    $acl.GetSecurityDescriptorBinaryForm(),
    0
  )
  $daclPresent =
    (($rawDescriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -ne 0) -and
    ($null -ne $rawDescriptor.DiscretionaryAcl)

  $evidence = [ordered]@{
    currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    protected = [bool]$acl.AreAccessRulesProtected
    daclPresent = [bool]$daclPresent
    rules = $rules
  }

  [Console]::Out.WriteLine(($evidence | ConvertTo-Json -Compress -Depth 5))
  exit 0
} catch {
  [Console]::Out.WriteLine('{"ok":false}')
  exit 1
}
