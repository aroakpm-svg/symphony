[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $ChildCommand,
  [string] $NotificationCommand = $null,
  [string] $NotificationReceiver = $null,
  [Parameter(Mandatory = $true)][string] $RuntimeIdentity,
  [Parameter(Mandatory = $true)][string] $RuntimeStateRoot,
  [Parameter(Mandatory = $true)][string] $StatePath,
  [int] $RestartLimit = 3,
  [int] $NotificationTimeoutMs = 5000
)

$ErrorActionPreference = "Stop"
$rootLease = $null
$root = $null
# Must match SymphonyElixir.RuntimeReceiptContract. All string limits are UTF-8 bytes;
# routing_revision uses the positive signed-64-bit domain shared by both PowerShell runtimes.
$Task5StringMaxBytes = @{
  at = 20
  category = 15
  receipt_path = 4096
  runtime_epoch = 128
  profile_key = 128
  issue_id = 128
  issue_identifier = 128
  repository = 256
  workspace_namespace = 128
  environment = 20
  failure_category = 34
  canonical_branch = 256
  detail = 8192
}
$MaxTask5RoutingRevision = [long]::MaxValue
$MaxTask5ReceiptBytes = 98304
$MaxIdempotencyReceiptBytes = 1024
$MaxPortableFileNameBytes = 255
$MaxPortablePathBytes = 4096

function Test-SecretBearingValue {
  param([AllowNull()][string] $Value)

  if ($null -eq $Value) { return $false }
  return $Value -match '(?i)(authorization|bearer|credential|password|secret|api[_-]?key|token)\s*[:= ]' -or
    $Value -match '(?i)(^|[_:/-])(credential|password|secret|api[_-]?key|token)([_:/-]|$)' -or
    $Value -match '(?i)\bsk-(?:proj-)?[a-z0-9_-]{16,}\b' -or
    $Value -match '(?i)\bgh[pousr]_[a-z0-9]{20,}\b' -or
    $Value -match '(?i)\bgithub_pat_[a-z0-9_]{20,}\b' -or
    $Value -match '\b(?:AKIA|ASIA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b' -or
    $Value -match '(?i)\bxox[baprs]-[a-z0-9-]{20,}\b' -or
    $Value -match '\bAIza[0-9A-Za-z_-]{20,}\b' -or
    $Value -match '(?i)\b[rs]k_(?:live|test)_[a-z0-9]{16,}\b' -or
    $Value -match '(?i)\b(?:glpat-|npm_|pypi-|hf_)[a-z0-9_-]{20,}\b' -or
    $Value -match '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b' -or
    $Value -match '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----' -or
    $Value -match '(?i)://[^/@\s]+:[^/@\s]+@'
}

function Test-ProductionPath {
  param([string] $Path)
  foreach ($segment in ($Path -split '[\\/]')) {
    if ($segment.ToLowerInvariant().Contains("production")) { return $true }
  }
  return $false
}

function Get-NormalizedPath {
  param([string] $Path)
  return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-SamePath {
  param([string] $Left, [string] $Right)
  return [string]::Equals((Get-NormalizedPath $Left), (Get-NormalizedPath $Right), [StringComparison]::OrdinalIgnoreCase)
}

function Test-ExactProperties {
  param($Object, [string[]] $Required, [string[]] $Allowed)
  if ($null -eq $Object -or $Object -isnot [PSCustomObject]) { return $false }
  $names = @($Object.PSObject.Properties.Name)
  foreach ($name in $Required) { if ($names -notcontains $name) { return $false } }
  foreach ($name in $names) { if ($Allowed -notcontains $name) { return $false } }
  return $true
}

function Test-UtcTimestamp {
  param([AllowNull()] $Value)
  if ($Value -is [DateTime]) { return $Value.Kind -ne [DateTimeKind]::Local }
  if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { return $false }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParseExact($Value, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)
}

function Get-ReceiverHash {
  param([string] $Receiver)
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    return [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Receiver))).Replace("-", "").ToLowerInvariant()
  }
  finally { $sha256.Dispose() }
}

function Get-NotificationKey {
  param([string] $ReceiverHash, [string] $Epoch)
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $identity = "$ReceiverHash`:$Epoch"
    return [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace("-", "").ToLowerInvariant()
  }
  finally { $sha256.Dispose() }
}

function Get-Utf8ByteCount {
  param([string] $Value)
  return [Text.Encoding]::UTF8.GetByteCount($Value)
}

function Get-LegacyNotificationName {
  param([string] $Kind, [string] $ReceiverHash, [string] $Epoch)
  if ($Kind -notin @('claim','delivery') -or $ReceiverHash -notmatch '\A[a-f0-9]{64}\z' -or
      $Epoch -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or (Test-SecretBearingValue $Epoch)) { return $null }
  $name = "restart-limit-$Kind-$ReceiverHash-$Epoch.json"
  $path = Join-Path $root $name
  if ((Get-Utf8ByteCount $name) -gt $MaxPortableFileNameBytes -or
      (Get-Utf8ByteCount $path) -gt $MaxPortablePathBytes -or
      -not [string]::Equals([IO.Path]::GetFileName($name), $name, [StringComparison]::Ordinal)) { return $null }
  return $name
}

function Test-PathEntryExists {
  param([string] $Name)
  try {
    $null = [IO.File]::GetAttributes($Name)
    return $true
  }
  catch [IO.FileNotFoundException] { return $false }
  catch [IO.DirectoryNotFoundException] { return $false }
}

$nativeSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public sealed class SymphonyTask6RootLease : IDisposable
{
  private const uint FILE_SHARE_READ = 1;
  private const uint FILE_SHARE_WRITE = 2;
  private const uint FILE_SHARE_DELETE = 4;
  private const uint OPEN_EXISTING = 3;
  private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
  private SafeFileHandle handle;
  private readonly uint volume;
  private readonly ulong index;

  [StructLayout(LayoutKind.Sequential)]
  private struct FILETIME { public uint Low; public uint High; }

  [StructLayout(LayoutKind.Sequential)]
  private struct BY_HANDLE_FILE_INFORMATION
  {
    public uint FileAttributes;
    public FILETIME CreationTime;
    public FILETIME LastAccessTime;
    public FILETIME LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle CreateFile(
    string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);

  private SymphonyTask6RootLease(SafeFileHandle value, BY_HANDLE_FILE_INFORMATION info)
  {
    handle = value;
    volume = info.VolumeSerialNumber;
    index = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
  }

  private static SafeFileHandle OpenHandle(string path, uint share)
  {
    return CreateFile(path, 0, share, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
  }

  private static bool Identity(SafeFileHandle value, out BY_HANDLE_FILE_INFORMATION info)
  {
    info = new BY_HANDLE_FILE_INFORMATION();
    return value != null && !value.IsInvalid && GetFileInformationByHandle(value, out info);
  }

  public static bool HasReparseAncestor(string path)
  {
    string full = Path.GetFullPath(path);
    string root = Path.GetPathRoot(full);
    string remainder = full.Substring(root.Length);
    string current = root;
    foreach (string part in remainder.Split(new char[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries))
    {
      current = Path.Combine(current, part);
      if (!Directory.Exists(current)) { return true; }
      FileAttributes attributes = File.GetAttributes(current);
      if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0) { return true; }
    }
    return false;
  }

  public static SymphonyTask6RootLease Open(string path)
  {
    if (HasReparseAncestor(path)) { return null; }
    SafeFileHandle value = OpenHandle(path, FILE_SHARE_READ | FILE_SHARE_WRITE);
    BY_HANDLE_FILE_INFORMATION info;
    if (!Identity(value, out info)) { if (value != null) value.Dispose(); return null; }
    if ((info.FileAttributes & 0x400) != 0) { value.Dispose(); return null; }
    return new SymphonyTask6RootLease(value, info);
  }

  public bool VerifyPath(string path)
  {
    if (handle == null || handle.IsInvalid || HasReparseAncestor(path)) { return false; }
    SafeFileHandle current = OpenHandle(path, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
    try
    {
      BY_HANDLE_FILE_INFORMATION info;
      if (!Identity(current, out info)) { return false; }
      ulong currentIndex = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
      return info.VolumeSerialNumber == volume && currentIndex == index && (info.FileAttributes & 0x400) == 0;
    }
    finally { if (current != null) current.Dispose(); }
  }

  public void Dispose() { if (handle != null) { handle.Dispose(); handle = null; } }
}

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

public sealed class SymphonyTask6Job : IDisposable
{
  private const uint KILL_ON_CLOSE = 0x00002000;
  private const int Accounting = 1;
  private const int ExtendedLimits = 9;
  private IntPtr handle;

  [StructLayout(LayoutKind.Sequential)] private struct BASIC_LIMIT { public long A; public long B; public uint Flags; public UIntPtr C; public UIntPtr D; public uint E; public UIntPtr F; public uint G; public uint H; }
  [StructLayout(LayoutKind.Sequential)] private struct IO_COUNTERS { public ulong A; public ulong B; public ulong C; public ulong D; public ulong E; public ulong F; }
  [StructLayout(LayoutKind.Sequential)] private struct EXTENDED_LIMIT { public BASIC_LIMIT Basic; public IO_COUNTERS Io; public UIntPtr A; public UIntPtr B; public UIntPtr C; public UIntPtr D; }
  [StructLayout(LayoutKind.Sequential)] private struct BASIC_ACCOUNTING { public long A; public long B; public long C; public long D; public uint E; public uint Total; public uint Active; public uint Terminated; }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint length);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(IntPtr job, uint code);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int cls, out BASIC_ACCOUNTING info, uint length, IntPtr returned);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr value);
  private SymphonyTask6Job(IntPtr value) { handle = value; }

  public static SymphonyTask6Job Create()
  {
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) return null;
    EXTENDED_LIMIT info = new EXTENDED_LIMIT(); info.Basic.Flags = KILL_ON_CLOSE;
    int size = Marshal.SizeOf(typeof(EXTENDED_LIMIT)); IntPtr buffer = Marshal.AllocHGlobal(size);
    try { Marshal.StructureToPtr(info, buffer, false); if (!SetInformationJobObject(job, ExtendedLimits, buffer, (uint)size)) { CloseHandle(job); return null; } }
    finally { Marshal.FreeHGlobal(buffer); }
    return new SymphonyTask6Job(job);
  }

  public bool Assign(Process process) { return handle != IntPtr.Zero && AssignProcessToJobObject(handle, process.Handle); }
  public bool TerminateAndWait(int timeoutMs)
  {
    if (handle == IntPtr.Zero || !TerminateJobObject(handle, 1)) return false;
    Stopwatch timer = Stopwatch.StartNew();
    while (timer.ElapsedMilliseconds <= timeoutMs)
    {
      BASIC_ACCOUNTING info;
      if (!QueryInformationJobObject(handle, Accounting, out info, (uint)Marshal.SizeOf(typeof(BASIC_ACCOUNTING)), IntPtr.Zero)) return false;
      if (info.Active == 0) return true;
      Thread.Sleep(10);
    }
    return false;
  }
  public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
}
'@

function Assert-PinnedRoot {
  if ($null -eq $rootLease -or -not $rootLease.VerifyPath($root) -or -not (Test-SamePath ([Environment]::CurrentDirectory) $root)) {
    throw "invalid runtime state root"
  }
}

function Test-ReparseFile {
  param([string] $Path)
  try {
    return [bool]([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint)
  }
  catch { return $true }
}

function Write-SyncedFile {
  param([string] $Path, [string] $Content)
  $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  }
  finally { $stream.Dispose() }
}

function Write-State {
  param([string] $Name, [hashtable] $State)
  Assert-PinnedRoot
  $temporary = ".$Name.tmp-$([Guid]::NewGuid().ToString('N'))"
  $backup = ".$Name.bak-$([Guid]::NewGuid().ToString('N'))"
  try {
    Write-SyncedFile $temporary ($State | ConvertTo-Json -Compress)
    Assert-PinnedRoot
    if ([IO.File]::Exists($Name)) {
      if (Test-ReparseFile $Name) { throw "invalid state file" }
      [IO.File]::Replace($temporary, $Name, $backup, $true)
    }
    else { [IO.File]::Move($temporary, $Name) }
    Assert-PinnedRoot
  }
  finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
  }
}

function Read-State {
  param([string] $Name, [AllowNull()][string] $ReceiverHash)
  Assert-PinnedRoot
  if (Test-ReparseFile $Name) { throw "invalid state file" }
  $stored = [IO.File]::ReadAllText($Name) | ConvertFrom-Json
  if (-not (Test-ExactProperties $stored @('version','runtime_epoch','attempt_count','receiver_hash','runtime_identity','terminal_timestamp') @('version','runtime_epoch','attempt_count','receiver_hash','runtime_identity','terminal_timestamp'))) { throw "invalid state" }
  if ($stored.version -ne 1 -or $stored.runtime_epoch -isnot [string] -or $stored.runtime_epoch -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or (Test-SecretBearingValue $stored.runtime_epoch)) { throw "invalid state" }
  if ($stored.attempt_count -isnot [int] -and $stored.attempt_count -isnot [long]) { throw "invalid state" }
  if ([int]$stored.attempt_count -lt 0 -or $stored.receiver_hash -ne $ReceiverHash -or $stored.runtime_identity -ne $RuntimeIdentity) { throw "invalid state" }
  $terminalTimestamp = $stored.terminal_timestamp
  if ($terminalTimestamp -is [DateTime]) {
    $terminalTimestamp = ([DateTimeOffset]$terminalTimestamp).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  elseif ($null -ne $terminalTimestamp -and -not (Test-UtcTimestamp $terminalTimestamp)) { throw "invalid state" }
  Assert-PinnedRoot
  return @{
    version = 1
    runtime_epoch = [string]$stored.runtime_epoch
    attempt_count = [int]$stored.attempt_count
    receiver_hash = $ReceiverHash
    runtime_identity = [string]$stored.runtime_identity
    terminal_timestamp = $terminalTimestamp
  }
}

function Test-SafeOptionalReceiptValue {
  param([string] $Name, $Value)
  if ($Name -eq 'routing_revision' -or $Name -eq 'restart_attempt') {
    return ($Value -is [int] -or $Value -is [long]) -and [long]$Value -gt 0 -and [long]$Value -le $MaxTask5RoutingRevision
  }
  if ($Name -eq 'environment') {
    return $Value -is [string] -and (Get-Utf8ByteCount $Value) -le $Task5StringMaxBytes.environment -and $Value -eq 'local_non_production'
  }
  if ($Name -eq 'failure_category') {
    return $null -eq $Value -or ($Value -is [string] -and (Get-Utf8ByteCount $Value) -le $Task5StringMaxBytes.failure_category -and $Value -in @(
      'callback_exception','callback_failure','candidate_fetch_failed','claim_rejected',
      'claim_service_unavailable','claim_timeout','default_branch_mismatch','default_branch_unresolvable',
      'dispatch_exception','dispatch_failure','inactive_state','linear_forbidden','linear_identity_missing',
      'linear_response_invalid','linear_unauthorized','linear_workspace_mismatch','linear_unavailable','missing','missing_routing',
      'missing_worker_label','non_exclusive_routing','poll_error','poll_timeout','preflight_unavailable',
      'project_changed','project_mapping_missing','refresh_unavailable','repository_metadata_invalid',
      'repository_mismatch','repository_unavailable','required_check_contract_invalid',
      'required_check_contract_missing','required_check_contract_unreadable','routing_unavailable',
      'stale_issue','unknown_project','wrong_node'))
  }
  if ($Value -isnot [string] -or (Test-SecretBearingValue $Value)) { return $false }
  $utf8Bytes = Get-Utf8ByteCount $Value
  if ($Name -eq 'profile_key') { return $utf8Bytes -ge 1 -and $utf8Bytes -le $Task5StringMaxBytes.profile_key -and $Value -match '\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z' }
  if ($Name -eq 'issue_id') { return $utf8Bytes -ge 1 -and $utf8Bytes -le $Task5StringMaxBytes.issue_id -and $Value -match '\A[A-Za-z0-9][A-Za-z0-9._:-]*\z' }
  if ($Name -eq 'issue_identifier') { return $utf8Bytes -ge 1 -and $utf8Bytes -le $Task5StringMaxBytes.issue_identifier -and $Value -match '\A[A-Za-z0-9][A-Za-z0-9._-]*\z' }
  if ($Name -eq 'repository') { return $utf8Bytes -ge 1 -and $utf8Bytes -le $Task5StringMaxBytes.repository -and $Value -match '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' }
  if ($Name -eq 'workspace_namespace') { return $utf8Bytes -ge 1 -and $utf8Bytes -le $Task5StringMaxBytes.workspace_namespace -and $Value -match '\A[a-z0-9]+(?:-[a-z0-9]+)*\z' }
  if ($Name -eq 'canonical_branch') {
    return $utf8Bytes -ge 1 -and $utf8Bytes -le $Task5StringMaxBytes.canonical_branch -and $Value -notmatch '[\x00-\x20\x7F\\]' -and -not $Value.StartsWith('/') -and -not $Value.EndsWith('/') -and -not $Value.Contains('..') -and -not $Value.Contains('@{') -and -not $Value.EndsWith('.lock')
  }
  if ($Name -eq 'detail') { return $utf8Bytes -le $Task5StringMaxBytes.detail -and $Value -notmatch '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' }
  return $false
}

function Test-StopReceipt {
  param([string] $Name, [string] $Epoch)
  try {
    Assert-PinnedRoot
    if ($Name -ne "stop-$Epoch.json" -or -not [IO.File]::Exists($Name) -or (Test-ReparseFile $Name)) { return $false }
    # Must match SymphonyElixir.RuntimeReceiptContract's producer-enforced bound.
    $bytes = [SymphonyTask6StableReceipt]::Read((Join-Path $root $Name), $MaxTask5ReceiptBytes)
    $payload = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($payload -notmatch '"at"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"') { return $false }
    $receipt = $payload | ConvertFrom-Json
    $required = @('at','category','receipt_path','runtime_epoch')
    $allowed = $required + @('profile_key','issue_id','issue_identifier','repository','workspace_namespace','environment','routing_revision','restart_attempt','failure_category','canonical_branch','detail')
    if (-not (Test-ExactProperties $receipt $required $allowed)) { return $false }
    if (-not (Test-UtcTimestamp $receipt.at)) { return $false }
    if ($receipt.at -is [string] -and (Get-Utf8ByteCount $receipt.at) -gt $Task5StringMaxBytes.at) { return $false }
    if ($receipt.runtime_epoch -isnot [string] -or (Get-Utf8ByteCount $receipt.runtime_epoch) -lt 1 -or (Get-Utf8ByteCount $receipt.runtime_epoch) -gt $Task5StringMaxBytes.runtime_epoch -or $receipt.runtime_epoch -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z' -or $receipt.runtime_epoch -ne $Epoch -or (Test-SecretBearingValue $receipt.runtime_epoch)) { return $false }
    if ($receipt.receipt_path -isnot [string] -or (Get-Utf8ByteCount $receipt.receipt_path) -lt 1 -or (Get-Utf8ByteCount $receipt.receipt_path) -gt $Task5StringMaxBytes.receipt_path -or (Test-SecretBearingValue $receipt.receipt_path) -or -not (Test-SamePath $receipt.receipt_path (Join-Path $root $Name))) { return $false }
    if ($receipt.category -isnot [string] -or (Get-Utf8ByteCount $receipt.category) -lt 1 -or (Get-Utf8ByteCount $receipt.category) -gt $Task5StringMaxBytes.category -or $receipt.category -notin @('normal_shutdown','startup_failure','unexpected_exit','restart_limit')) { return $false }
    foreach ($property in $receipt.PSObject.Properties) {
      if ($required -notcontains $property.Name -and -not (Test-SafeOptionalReceiptValue $property.Name $property.Value)) { return $false }
    }
    Assert-PinnedRoot
    return $true
  }
  catch { return $false }
}

function Test-ClaimReceipt {
  param([string] $Name, [string] $Epoch, [string] $ReceiverHash)
  try {
    $receipt = Read-IdempotencyReceipt $Name
    if (-not (Test-ExactProperties $receipt @('version','state','receiver_hash','runtime_epoch','stop_category') @('version','state','receiver_hash','runtime_epoch','stop_category'))) { return $false }
    return $receipt.version -eq 1 -and $receipt.state -eq 'inflight' -and $receipt.receiver_hash -eq $ReceiverHash -and $receipt.runtime_epoch -eq $Epoch -and $receipt.stop_category -eq 'restart_limit'
  }
  catch { return $false }
}

function Test-DeliveryReceipt {
  param([string] $Name, [string] $Epoch, [string] $ReceiverHash)
  try {
    $receipt = Read-IdempotencyReceipt $Name
    if (-not (Test-ExactProperties $receipt @('version','delivered','receiver_hash','runtime_epoch','stop_category') @('version','delivered','receiver_hash','runtime_epoch','stop_category'))) { return $false }
    return $receipt.version -eq 1 -and $receipt.delivered -eq $true -and $receipt.receiver_hash -eq $ReceiverHash -and $receipt.runtime_epoch -eq $Epoch -and $receipt.stop_category -eq 'restart_limit'
  }
  catch { return $false }
}

function Read-IdempotencyReceipt {
  param([string] $Name)
  Assert-PinnedRoot
  if (-not [IO.File]::Exists($Name) -or (Test-ReparseFile $Name)) { throw "invalid idempotency receipt" }
  $bytes = [SymphonyTask6StableReceipt]::Read((Join-Path $root $Name), $MaxIdempotencyReceiptBytes)
  if ($bytes.Length -lt 1 -or $bytes.Length -gt $MaxIdempotencyReceiptBytes) { throw "invalid idempotency receipt" }
  $payload = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  $receipt = $payload | ConvertFrom-Json
  Assert-PinnedRoot
  return $receipt
}

function Write-ImmutableJson {
  param([string] $Name, [hashtable] $Value)
  Assert-PinnedRoot
  $temporary = ".$Name.tmp-$([Guid]::NewGuid().ToString('N'))"
  try {
    Write-SyncedFile $temporary ($Value | ConvertTo-Json -Compress)
    Assert-PinnedRoot
    [IO.File]::Move($temporary, $Name)
    Assert-PinnedRoot
    return 'created'
  }
  catch [IO.IOException] { return 'exists' }
  catch { return 'error' }
  finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-GateWrapper {
  param([string] $EncodedCommand, [string] $Nonce)
  $template = @'
$ErrorActionPreference = 'Stop'
if ([Console]::In.ReadLine() -ne '__NONCE__') { exit 125 }
$payload = [Console]::In.ReadToEnd()
$command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__COMMAND__'))
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = (Get-Process -Id $PID).Path
$start.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
$start.UseShellExecute = $false; $start.CreateNoWindow = $true
$start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
$process = [Diagnostics.Process]::new(); $process.StartInfo = $start
try {
  if (-not $process.Start()) { exit 125 }
  $out = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
  $err = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
  $process.StandardInput.Write($payload); $process.StandardInput.Close()
  $process.WaitForExit(); $code = $process.ExitCode
  if (-not $out.Wait(500) -or -not $err.Wait(500)) { exit 126 }
  exit $code
}
catch { exit 125 }
finally { $process.Dispose() }
'@
  return $template.Replace('__COMMAND__', $EncodedCommand).Replace('__NONCE__', $Nonce)
}

function Invoke-SuppressedCommand {
  param([string] $Command, [AllowNull()][string] $InputLine, [hashtable] $Environment, [int] $TimeoutMs)

  $enginePath = (Get-Process -Id $PID).Path
  $nonceBytes = New-Object byte[] 24
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $random.GetBytes($nonceBytes) } finally { $random.Dispose() }
  $nonce = [Convert]::ToBase64String($nonceBytes)
  $gate = Get-GateWrapper ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))) $nonce
  $encodedGate = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($gate))
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $enginePath
  $start.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedGate"
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  $start.WorkingDirectory = $root
  foreach ($key in $Environment.Keys) { $start.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
  $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
  $job = [SymphonyTask6Job]::Create()
  $started = $false; $assigned = $false; $treeStopped = $false; $timedOut = $false; $code = -1
  try {
    if ($null -eq $job -or -not $process.Start()) { return @{ exit_code = -1; timed_out = $false; termination_verified = $false } }
    $started = $true
    if (-not $job.Assign($process)) { return @{ exit_code = -1; timed_out = $false; termination_verified = $false } }
    $assigned = $true
    $outputDrain = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
    $errorDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $process.StandardInput.WriteLine($nonce)
    if ($null -ne $InputLine) { $process.StandardInput.Write($InputLine) }
    $process.StandardInput.Close()
    if ($TimeoutMs -gt 0) { $completed = $process.WaitForExit($TimeoutMs) }
    else { $process.WaitForExit(); $completed = $true }
    if ($completed) { $code = $process.ExitCode } else { $timedOut = $true }
  }
  catch { $code = -1 }
  finally {
    if ($null -ne $job -and $assigned) { $treeStopped = $job.TerminateAndWait(2000) }
    elseif ($started) {
      try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
      $treeStopped = $process.WaitForExit(2000)
    }
    if ($started) { $null = $process.WaitForExit(2000) }
    if ($null -ne $outputDrain) { $null = $outputDrain.Wait(2000) }
    if ($null -ne $errorDrain) { $null = $errorDrain.Wait(2000) }
    $process.Dispose()
    if ($null -ne $job) { $job.Dispose() }
  }
  return @{ exit_code = $code; timed_out = $timedOut; termination_verified = $treeStopped }
}

function Remove-Claim {
  param([string] $Name, [string] $Epoch, [string] $ReceiverHash)
  Assert-PinnedRoot
  if (-not (Test-ClaimReceipt $Name $Epoch $ReceiverHash)) { return $false }
  [IO.File]::Delete($Name)
  Assert-PinnedRoot
  return $true
}

function Ensure-RestartLimitReceipt {
  param([hashtable] $State)
  $epoch = [string]$State.runtime_epoch
  $receiptName = "stop-$epoch.json"
  if (Test-PathEntryExists $receiptName) { return Test-StopReceipt $receiptName $epoch }
  $receipt = @{
    at = [string]$State.terminal_timestamp
    category = 'restart_limit'
    receipt_path = (Join-Path $root $receiptName)
    runtime_epoch = $epoch
    restart_attempt = [int]$State.attempt_count
  }
  $published = Write-ImmutableJson $receiptName $receipt
  if ($published -eq 'error') { return $false }
  return Test-StopReceipt $receiptName $epoch
}

function Invoke-RestartLimitNotification {
  param([hashtable] $State, [bool] $Enabled)
  if (-not $Enabled) { return $false }
  $epoch = [string]$State.runtime_epoch
  $receiptName = "stop-$epoch.json"
  if (-not (Test-StopReceipt $receiptName $epoch)) { return $false }
  $hash = [string]$State.receiver_hash
  $notificationKey = Get-NotificationKey $hash $epoch
  $deliveryName = "restart-limit-delivery-$notificationKey.json"
  $claimName = "restart-limit-claim-$notificationKey.json"
  if (Test-PathEntryExists $deliveryName) { return Test-DeliveryReceipt $deliveryName $epoch $hash }
  $legacyDeliveryName = Get-LegacyNotificationName 'delivery' $hash $epoch
  $legacyClaimName = Get-LegacyNotificationName 'claim' $hash $epoch
  if ($null -eq $legacyDeliveryName -or $null -eq $legacyClaimName) { return $false }
  if ($null -ne $legacyDeliveryName -and (Test-PathEntryExists $legacyDeliveryName)) {
    return Test-DeliveryReceipt $legacyDeliveryName $epoch $hash
  }
  if ($null -ne $legacyClaimName -and (Test-PathEntryExists $legacyClaimName)) {
    $null = Test-ClaimReceipt $legacyClaimName $epoch $hash
    return $false
  }
  $claim = @{ version = 1; state = 'inflight'; receiver_hash = $hash; runtime_epoch = $epoch; stop_category = 'restart_limit' }
  $reservation = Write-ImmutableJson $claimName $claim
  if ($reservation -ne 'created') {
    if ($reservation -eq 'exists') { $null = Test-ClaimReceipt $claimName $epoch $hash }
    return $false
  }
  $event = [ordered]@{
    runtime_identity = $RuntimeIdentity
    receiver = $NotificationReceiver
    attempt_count = [int]$State.attempt_count
    stop_category = 'restart_limit'
    timestamp = [string]$State.terminal_timestamp
    runtime_epoch = $epoch
    receipt_path = (Join-Path $root $receiptName)
  }
  $result = Invoke-SuppressedCommand $NotificationCommand ($event | ConvertTo-Json -Compress) @{} $NotificationTimeoutMs
  if (-not $result.termination_verified) { return $false }
  if ($result.timed_out -or $result.exit_code -ne 0) {
    $null = Remove-Claim $claimName $epoch $hash
    return $false
  }
  $delivery = @{ version = 1; delivered = $true; receiver_hash = $hash; runtime_epoch = $epoch; stop_category = 'restart_limit' }
  $published = Write-ImmutableJson $deliveryName $delivery
  if ($published -eq 'created' -or ($published -eq 'exists' -and (Test-DeliveryReceipt $deliveryName $epoch $hash))) {
    $null = Remove-Claim $claimName $epoch $hash
    return $true
  }
  return $false
}

try {
  $commandPresent = -not [string]::IsNullOrWhiteSpace($NotificationCommand)
  $receiverPresent = -not [string]::IsNullOrWhiteSpace($NotificationReceiver)
  if ($commandPresent -xor $receiverPresent) { exit 2 }
  $notificationsEnabled = $commandPresent -and $receiverPresent

  if (-not [IO.Path]::IsPathRooted($RuntimeStateRoot) -or -not [IO.Path]::IsPathRooted($StatePath)) { exit 2 }
  if ([string]::IsNullOrWhiteSpace($ChildCommand) -or [string]::IsNullOrWhiteSpace($RuntimeIdentity)) { exit 2 }
  if ($RuntimeIdentity -notmatch '\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z' -or (Test-SecretBearingValue $RuntimeIdentity)) { exit 2 }
  if (Test-ProductionPath $RuntimeStateRoot -or (Test-SecretBearingValue $RuntimeStateRoot) -or (Test-SecretBearingValue $StatePath)) { exit 2 }
  if ($notificationsEnabled) {
    if ($NotificationCommand.Length -gt 4096 -or (Test-SecretBearingValue $NotificationCommand)) { exit 2 }
    if ($NotificationReceiver -notmatch '\A[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}\z' -or (Test-SecretBearingValue $NotificationReceiver)) { exit 2 }
  }
  if ($RestartLimit -le 0 -or $NotificationTimeoutMs -le 0) { exit 2 }

  Add-Type -TypeDefinition $nativeSource | Out-Null
  $root = Get-NormalizedPath $RuntimeStateRoot
  if (-not [IO.Directory]::Exists($root)) { exit 2 }
  if (Test-ProductionPath $root -or (Test-SamePath $root ([IO.Path]::GetPathRoot($root)))) { exit 2 }
  if ([SymphonyTask6RootLease]::HasReparseAncestor($root)) { exit 2 }
  $rootLease = [SymphonyTask6RootLease]::Open($root)
  if ($null -eq $rootLease) { exit 2 }
  [Environment]::CurrentDirectory = $root
  Assert-PinnedRoot

  $stateFullPath = Get-NormalizedPath $StatePath
  if (-not (Test-SamePath ([IO.Path]::GetDirectoryName($stateFullPath)) $root)) { exit 2 }
  $stateName = [IO.Path]::GetFileName($stateFullPath)
  if ($stateName -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or (Test-SecretBearingValue $stateName)) { exit 2 }
  $receiverHash = if ($notificationsEnabled) { Get-ReceiverHash $NotificationReceiver } else { $null }

  if ([IO.File]::Exists($stateName)) { $state = Read-State $stateName $receiverHash }
  else {
    $state = @{ version = 1; runtime_epoch = [Guid]::NewGuid().ToString('N'); attempt_count = 0; receiver_hash = $receiverHash; runtime_identity = $RuntimeIdentity; terminal_timestamp = $null }
    Write-State $stateName $state
  }

  while ($true) {
    Assert-PinnedRoot
    if ([int]$state.attempt_count -ge $RestartLimit) {
      if ([string]::IsNullOrWhiteSpace([string]$state.terminal_timestamp)) {
        $state.terminal_timestamp = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-State $stateName $state
      }
      if (-not (Ensure-RestartLimitReceipt $state)) { exit 2 }
      $null = Invoke-RestartLimitNotification $state $notificationsEnabled
      exit 1
    }

    $attempt = [int]$state.attempt_count + 1
    $receiptName = "stop-$($state.runtime_epoch).json"
    $environment = @{
      SYMPHONY_RUNTIME_EPOCH = [string]$state.runtime_epoch
      SYMPHONY_RUNTIME_RECEIPT_PATH = Join-Path $root $receiptName
      SYMPHONY_RUNTIME_STATE_ROOT = $root
      SYMPHONY_RESTART_ATTEMPT = [string]$attempt
    }
    $childResult = Invoke-SuppressedCommand $ChildCommand $null $environment 0
    Assert-PinnedRoot
    if (-not $childResult.termination_verified) { exit 2 }
    if (-not $childResult.timed_out -and $childResult.exit_code -eq 0) {
      if ([IO.File]::Exists($stateName)) {
        if (Test-ReparseFile $stateName) { exit 2 }
        [IO.File]::Delete($stateName)
      }
      Assert-PinnedRoot
      exit 0
    }
    $state.attempt_count = $attempt
    Write-State $stateName $state
  }
}
catch { exit 2 }
finally { if ($null -ne $rootLease) { $rootLease.Dispose() } }
