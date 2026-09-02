$ErrorActionPreference = 'Stop'

$nativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

public sealed class SymphonyLockedDirectory : IDisposable
{
    private const uint FILE_READ_ATTRIBUTES = 0x0080;
    private const uint DELETE = 0x00010000;
    private const uint READ_CONTROL = 0x00020000;
    private const uint WRITE_DAC = 0x00040000;
    private const uint WRITE_OWNER = 0x00080000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_CREATE = 2;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
    private const uint FILE_DIRECTORY_FILE = 0x00000001;
    private const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
    private const uint FILE_OPEN_REPARSE_POINT = 0x00200000;
    private const uint OBJ_CASE_INSENSITIVE = 0x00000040;
    private const int FILE_ID_INFO_CLASS = 18;
    private const int FILE_DISPOSITION_INFO_CLASS = 4;
    private const uint SDDL_REVISION_1 = 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_DISPOSITION_INFO
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool DeleteFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_STATUS_BLOCK
    {
        public IntPtr Status;
        public UIntPtr Information;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string name,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle handle,
        out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle handle,
        int informationClass,
        IntPtr information,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle handle,
        int informationClass,
        ref FILE_DISPOSITION_INFO information,
        uint bufferSize);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
        string stringSecurityDescriptor,
        uint stringSDRevision,
        out IntPtr securityDescriptor,
        out uint securityDescriptorSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("ntdll.dll")]
    private static extern int NtCreateFile(
        out SafeFileHandle fileHandle,
        uint desiredAccess,
        ref OBJECT_ATTRIBUTES objectAttributes,
        out IO_STATUS_BLOCK ioStatusBlock,
        IntPtr allocationSize,
        uint fileAttributes,
        uint shareAccess,
        uint createDisposition,
        uint createOptions,
        IntPtr eaBuffer,
        uint eaLength);

    [DllImport("ntdll.dll")]
    private static extern uint RtlNtStatusToDosError(int status);

    public SafeFileHandle Handle { get; private set; }
    public string Identity { get; private set; }
    public bool Created { get; private set; }

    private SymphonyLockedDirectory(SafeFileHandle handle, bool created)
    {
        Handle = handle;
        Created = created;
        VerifyDirectory();
        Identity = ReadIdentity();
    }

    public static SymphonyLockedDirectory OpenExisting(string path, bool created)
    {
        uint access = FILE_READ_ATTRIBUTES | READ_CONTROL;
        if (created) access |= DELETE | WRITE_DAC | WRITE_OWNER;

        SafeFileHandle handle = CreateFile(
            path,
            access,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }

        try
        {
            return new SymphonyLockedDirectory(handle, created);
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    public static SymphonyLockedDirectory CreateExact(string leafName, SymphonyLockedDirectory parent)
    {
        if (String.IsNullOrWhiteSpace(leafName) ||
            leafName.IndexOfAny(new char[] { '\\', '/' }) >= 0 ||
            leafName == "." ||
            leafName == "..")
            throw new InvalidOperationException("invalid_leaf");

        string currentSid = WindowsIdentity.GetCurrent().User.Value;
        string sddl = "O:" + currentSid + "D:P(A;OICI;FA;;;" + currentSid + ")";
        IntPtr securityDescriptor = IntPtr.Zero;
        uint securityDescriptorSize;

        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                sddl,
                SDDL_REVISION_1,
                out securityDescriptor,
                out securityDescriptorSize))
            throw new Win32Exception(Marshal.GetLastWin32Error());

        IntPtr nameBuffer = IntPtr.Zero;
        IntPtr nameStructure = IntPtr.Zero;
        SafeFileHandle handle = null;

        try
        {
            nameBuffer = Marshal.StringToHGlobalUni(leafName);
            UNICODE_STRING unicodeName = new UNICODE_STRING
            {
                Length = checked((ushort)(leafName.Length * 2)),
                MaximumLength = checked((ushort)((leafName.Length + 1) * 2)),
                Buffer = nameBuffer
            };
            nameStructure = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));
            Marshal.StructureToPtr(unicodeName, nameStructure, false);

            OBJECT_ATTRIBUTES attributes = new OBJECT_ATTRIBUTES
            {
                Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)),
                RootDirectory = parent.Handle.DangerousGetHandle(),
                ObjectName = nameStructure,
                Attributes = OBJ_CASE_INSENSITIVE,
                SecurityDescriptor = securityDescriptor,
                SecurityQualityOfService = IntPtr.Zero
            };

            IO_STATUS_BLOCK statusBlock;
            int status = NtCreateFile(
                out handle,
                FILE_READ_ATTRIBUTES | DELETE | READ_CONTROL | WRITE_DAC | WRITE_OWNER | SYNCHRONIZE,
                ref attributes,
                out statusBlock,
                IntPtr.Zero,
                0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                FILE_CREATE,
                FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
                IntPtr.Zero,
                0);

            if (status < 0 || handle == null || handle.IsInvalid)
            {
                if (handle != null) handle.Dispose();
                throw new Win32Exception((int)RtlNtStatusToDosError(status));
            }

            try
            {
                return new SymphonyLockedDirectory(handle, true);
            }
            catch
            {
                try { MarkDeleteHandle(handle); }
                finally { handle.Dispose(); }
                throw;
            }
        }
        finally
        {
            if (nameStructure != IntPtr.Zero) Marshal.FreeHGlobal(nameStructure);
            if (nameBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nameBuffer);
            if (securityDescriptor != IntPtr.Zero) LocalFree(securityDescriptor);
        }
    }

    public void Verify(string expectedIdentity)
    {
        VerifyDirectory();
        string current = ReadIdentity();
        if (!String.Equals(current, expectedIdentity, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("identity_changed");
    }

    public void MarkDelete()
    {
        MarkDeleteHandle(Handle);
    }

    private static void MarkDeleteHandle(SafeFileHandle handle)
    {
        FILE_DISPOSITION_INFO information = new FILE_DISPOSITION_INFO { DeleteFile = true };
        if (!SetFileInformationByHandle(
                handle,
                FILE_DISPOSITION_INFO_CLASS,
                ref information,
                (uint)Marshal.SizeOf(typeof(FILE_DISPOSITION_INFO))))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    private void VerifyDirectory()
    {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(Handle, out information))
            throw new Win32Exception(Marshal.GetLastWin32Error());

        if ((information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
            (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            throw new InvalidOperationException("unsafe_component");
    }

    private string ReadIdentity()
    {
        IntPtr buffer = Marshal.AllocHGlobal(24);
        try
        {
            if (!GetFileInformationByHandleEx(Handle, FILE_ID_INFO_CLASS, buffer, 24))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            byte[] identifier = new byte[16];
            Marshal.Copy(IntPtr.Add(buffer, 8), identifier, 0, identifier.Length);
            Array.Reverse(identifier);
            return "0x" + BitConverter.ToString(identifier).Replace("-", "").ToLowerInvariant();
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public void Dispose()
    {
        if (Handle != null && !Handle.IsClosed) Handle.Dispose();
    }
}
'@

function Write-Reply([string]$id, [bool]$ok, [string]$code, [string]$identity = $null) {
  $reply = [ordered]@{ id = $id; ok = $ok; code = $code }
  if (-not [string]::IsNullOrEmpty($identity)) { $reply.identity = $identity }
  [Console]::Out.WriteLine(($reply | ConvertTo-Json -Compress))
  [Console]::Out.Flush()
}

function Normalize-Path([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { throw 'invalid_path' }
  return [IO.Path]::GetFullPath($path).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Path-Key([string]$path) {
  return (Normalize-Path $path).ToUpperInvariant()
}

function Assert-ExpectedIdentity($locked, [string]$expected) {
  if ([string]::IsNullOrWhiteSpace($expected)) { throw 'missing_identity' }
  $locked.Verify($expected)
}

function Assert-PrivateAcl([string]$path) {
  $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = [IO.DirectoryInfo]::new($path).GetAccessControl(
    [Security.AccessControl.AccessControlSections](
      [Security.AccessControl.AccessControlSections]::Owner -bor
      [Security.AccessControl.AccessControlSections]::Access
    )
  )
  if (-not $acl.AreAccessRulesProtected) { throw 'acl_inherited' }
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $current) { throw 'acl_owner' }
  $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  if ($rules.Count -ne 1) { throw 'acl_rule_count' }
  $rule = $rules[0]
  if ($rule.IdentityReference -ne $current -or
      $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
      $rule.IsInherited -or
      $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
      $rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit' -or
      $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
    throw 'acl_rule'
  }
}

function Verify-All {
  foreach ($entry in $script:anchors.Values) {
    $entry.locked.Verify($entry.identity)
  }
  foreach ($entry in $script:components.Values) {
    $entry.locked.Verify($entry.identity)
    Assert-PrivateAcl $entry.path
  }
}

function Close-All {
  foreach ($entry in $script:components.Values) { $entry.locked.Dispose() }
  foreach ($entry in $script:anchors.Values) { $entry.locked.Dispose() }
}

function Parent-Entry([string]$path) {
  $parentKey = Path-Key ([IO.Path]::GetDirectoryName($path))
  if ($script:components.ContainsKey($parentKey)) { return $script:components[$parentKey] }
  if ($script:anchors.ContainsKey($parentKey)) { return $script:anchors[$parentKey] }
  throw 'missing_parent'
}

function Rollback-Created {
  $failed = $false
  $remaining = [Collections.ArrayList]::new()

  for ($index = $script:created.Count - 1; $index -ge 0; $index--) {
    $entry = $script:created[$index]
    try {
      $entry.locked.Verify($entry.identity)
      $entry.locked.MarkDelete()
      $entry.locked.Dispose()
      $script:components.Remove((Path-Key $entry.path))
      if ([IO.Directory]::Exists($entry.path) -or [IO.File]::Exists($entry.path)) {
        throw 'delete_not_complete'
      }
    } catch {
      $failed = $true
      $null = $remaining.Insert(0, $entry)
    }
  }

  $script:created = $remaining
  if (-not $failed) { Close-All }
  return (-not $failed)
}

$script:anchors = @{}
$script:components = @{}
$script:expected = @{}
$script:created = [Collections.ArrayList]::new()
$script:usedIds = @{}
$script:committed = $false
$script:failCommit = $false
$initialized = $false

try {
  $null = Add-Type -TypeDefinition $nativeSource -Language CSharp

  while ($null -ne ($line = [Console]::In.ReadLine())) {
    $correlationId = ''

    try {
      if ($line.Length -gt 65536) { throw 'oversized_request' }
      $request = $line | ConvertFrom-Json
      $correlationId = [string]$request.id
      if ($correlationId -notmatch '\A[0-9]{1,32}\z') { throw 'invalid_correlation' }
      if ($script:usedIds.ContainsKey($correlationId)) { throw 'duplicate_correlation' }
      $script:usedIds[$correlationId] = $true

      switch ($request.op) {
        'init' {
          if ($initialized) { throw 'already_initialized' }
          $script:failCommit = $request.failCommit -eq $true

          foreach ($item in @($request.anchors)) {
            $path = Normalize-Path $item.path
            $key = Path-Key $path
            if ($script:anchors.ContainsKey($key)) { throw 'duplicate_anchor' }
            $locked = [SymphonyLockedDirectory]::OpenExisting($path, $false)
            Assert-ExpectedIdentity $locked $item.identity
            $script:anchors[$key] = [pscustomobject]@{
              path = $path; identity = $locked.Identity; locked = $locked
            }
          }

          foreach ($item in @($request.components)) {
            $path = Normalize-Path $item.path
            $key = Path-Key $path
            if ($script:expected.ContainsKey($key)) { throw 'duplicate_component' }
            $script:expected[$key] = $item.identity

            if ($null -ne $item.identity) {
              $locked = [SymphonyLockedDirectory]::OpenExisting($path, $false)
              Assert-ExpectedIdentity $locked $item.identity
              Assert-PrivateAcl $path
              $script:components[$key] = [pscustomobject]@{
                path = $path; identity = $locked.Identity; locked = $locked; created = $false
              }
            } elseif ([IO.Directory]::Exists($path) -or [IO.File]::Exists($path)) {
              throw 'unexpected_component'
            }
          }

          Verify-All
          $initialized = $true
          Write-Reply $correlationId $true 'ready'
        }

        'ensure' {
          if (-not $initialized) { throw 'not_initialized' }
          Verify-All
          $path = Normalize-Path $request.path
          $key = Path-Key $path
          if (-not $script:expected.ContainsKey($key)) { throw 'unknown_component' }

          if (-not $script:components.ContainsKey($key)) {
            $parent = Parent-Entry $path
            $leafName = [IO.Path]::GetFileName($path)
            $locked = [SymphonyLockedDirectory]::CreateExact($leafName, $parent.locked)
            $entry = [pscustomobject]@{
              path = $path; identity = $locked.Identity; locked = $locked; created = $true
            }
            $script:components[$key] = $entry
            $null = $script:created.Add($entry)

            if ($request.failPermission -eq $true) { throw 'injected_permission_failure' }
            Assert-PrivateAcl $path
          }

          $entry = $script:components[$key]
          $entry.locked.Verify($entry.identity)
          Assert-PrivateAcl $entry.path
          Verify-All
          Write-Reply $correlationId $true 'ensured' $entry.identity
        }

        'verify' {
          if (-not $initialized) { throw 'not_initialized' }
          if ($script:components.Count -ne $script:expected.Count) { throw 'incomplete' }
          Verify-All
          Write-Reply $correlationId $true 'verified'
        }

        'commit' {
          if (-not $initialized) { throw 'not_initialized' }
          if ($script:components.Count -ne $script:expected.Count) { throw 'incomplete' }
          if ($script:failCommit) { throw 'injected_commit_failure' }
          Verify-All
          $script:committed = $true
          Close-All
          Write-Reply $correlationId $true 'committed'
          return
        }

        'rollback' {
          if (Rollback-Created) {
            Write-Reply $correlationId $true 'rolled_back'
            return
          }

          Write-Reply $correlationId $false 'rollback_failed'
        }

        default { throw 'invalid_operation' }
      }
    } catch {
      Write-Reply $correlationId $false 'operation_failed'
    }
  }
} catch {
  Write-Reply '' $false 'helper_failed'
} finally {
  if (-not $script:committed) {
    $null = Rollback-Created
    Close-All
  }
}
