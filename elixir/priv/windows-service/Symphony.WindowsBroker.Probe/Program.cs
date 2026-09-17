using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Symphony.WindowsBroker.Probe;

public sealed record ProbeConfiguration(
    [property: JsonPropertyName("synthetic_key_path")] string SyntheticKeyPath,
    [property: JsonPropertyName("outside_path")] string OutsidePath);

public sealed record ProbeResult(
    string UserSid,
    string UserName,
    bool Elevated,
    bool AdministratorsEnabled,
    bool AdministratorsDenyOnly,
    bool KeyDirectoryListDenied,
    bool KeyReadDenied,
    bool OutsideReadDenied,
    bool WorkspaceCreateEditDeleteSucceeded,
    string[] LeakedEnvironmentNames);

public static class ProbeRunner
{
    public const string ConfigurationFileName = ".aro197-boundary-probe.json";
    static readonly Regex SecretName = new("(LINEAR|TOKEN|JWT|SECRET|PASSWORD|PRIVATE_KEY|GITHUB_APP|CLAIM|CONTROLLER)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    static readonly JsonSerializerOptions StrictJson = new() { PropertyNameCaseInsensitive = false, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };

    public static ProbeResult Run(string workingDirectory)
    {
        var workspace = ExistingDirectory(workingDirectory);
        var configurationPath = ExistingFile(Path.Combine(workspace, ConfigurationFileName));
        var configuration = JsonSerializer.Deserialize<ProbeConfiguration>(File.ReadAllText(configurationPath), StrictJson)
            ?? throw new InvalidDataException("probe_config_invalid");
        var key = ExistingFile(configuration.SyntheticKeyPath);
        var outside = ExistingFile(configuration.OutsidePath);
        var identity = TokenInspector.Capture();
        var keyDirectory = Path.GetDirectoryName(key) ?? throw new InvalidDataException("probe_key_parent_missing");

        return new(
            identity.UserSid.Value,
            identity.UserName,
            identity.Elevated,
            identity.AdministratorsEnabled,
            identity.AdministratorsDenyOnly,
            Denied(() => Directory.EnumerateFileSystemEntries(keyDirectory).ToArray()),
            Denied(() => File.ReadAllBytes(key)),
            Denied(() => File.ReadAllBytes(outside)),
            ExerciseWorkspace(workspace),
            Environment.GetEnvironmentVariables().Keys.Cast<object>().Select(value => value.ToString() ?? string.Empty)
                .Where(name => SecretName.IsMatch(name)).Order(StringComparer.OrdinalIgnoreCase).ToArray());
    }

    public static bool Succeeded(ProbeResult result) =>
        result.UserSid != "S-1-5-18" &&
        !result.Elevated &&
        !result.AdministratorsEnabled &&
        !result.AdministratorsDenyOnly &&
        result.KeyDirectoryListDenied &&
        result.KeyReadDenied &&
        result.OutsideReadDenied &&
        result.WorkspaceCreateEditDeleteSucceeded &&
        result.LeakedEnvironmentNames.Length == 0;

    static bool Denied(Action action)
    {
        try { action(); return false; }
        catch (UnauthorizedAccessException) { return true; }
    }

    static bool ExerciseWorkspace(string workspace)
    {
        var sentinel = Path.Combine(workspace, "aro197-worker-sentinel.txt");
        try
        {
            File.WriteAllText(sentinel, "created");
            File.WriteAllText(sentinel, "edited");
            if (File.ReadAllText(sentinel) != "edited") return false;
            File.Delete(sentinel);
            return !File.Exists(sentinel);
        }
        catch (UnauthorizedAccessException) { return false; }
        catch (IOException) { return false; }
        finally
        {
            try { if (File.Exists(sentinel)) File.Delete(sentinel); }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException) { }
        }
    }

    static string ExistingFile(string path)
    {
        var canonical = Canonical(path);
        if (!File.Exists(canonical)) throw new InvalidDataException("probe_file_missing");
        return canonical;
    }

    static string ExistingDirectory(string path)
    {
        var canonical = Canonical(path);
        if (!Directory.Exists(canonical)) throw new InvalidDataException("probe_directory_missing");
        return canonical;
    }

    static string Canonical(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("probe_path_not_absolute");
        if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.StartsWith(@"\\?\", StringComparison.Ordinal)) throw new InvalidDataException("probe_path_denied");
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full) ?? throw new InvalidDataException("probe_path_root_missing");
        var current = root;
        foreach (var component in full[root.Length..].Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            if (!Directory.Exists(current) && !File.Exists(current)) throw new InvalidDataException("probe_path_missing");
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("probe_reparse_denied");
        }
        return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }
}

static class TokenInspector
{
    const uint SeGroupEnabled = 0x00000004;
    const uint SeGroupUseForDenyOnly = 0x00000010;
    static readonly SecurityIdentifier AdministratorsSid = new(WellKnownSidType.BuiltinAdministratorsSid, null);

    internal sealed record Snapshot(SecurityIdentifier UserSid, string UserName, bool Elevated, bool AdministratorsEnabled, bool AdministratorsDenyOnly);

    internal static Snapshot Capture()
    {
        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        var user = identity.User ?? throw new InvalidOperationException("probe_identity_missing");
        var elevated = ReadElevation(identity.AccessToken);
        var (enabled, denyOnly) = ReadAdministrators(identity.AccessToken);
        return new(user, identity.Name, elevated, enabled, denyOnly);
    }

    static bool ReadElevation(SafeAccessTokenHandle token)
    {
        var size = Marshal.SizeOf<TokenElevation>();
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!GetTokenInformation(token, TokenInformationClass.TokenElevation, buffer, size, out _)) throw new Win32Exception();
            return Marshal.PtrToStructure<TokenElevation>(buffer).TokenIsElevated != 0;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    static (bool Enabled, bool DenyOnly) ReadAdministrators(SafeAccessTokenHandle token)
    {
        GetTokenInformation(token, TokenInformationClass.TokenGroups, IntPtr.Zero, 0, out var size);
        if (size <= 0) throw new Win32Exception();
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!GetTokenInformation(token, TokenInformationClass.TokenGroups, buffer, size, out _)) throw new Win32Exception();
            var count = Marshal.ReadInt32(buffer);
            var offset = IntPtr.Size == 8 ? 8 : 4;
            var stride = Marshal.SizeOf<SidAndAttributes>();
            for (var index = 0; index < count; index++)
            {
                var entry = Marshal.PtrToStructure<SidAndAttributes>(IntPtr.Add(buffer, offset + index * stride));
                var sid = new SecurityIdentifier(entry.Sid);
                if (!sid.Equals(AdministratorsSid)) continue;
                return ((entry.Attributes & SeGroupEnabled) != 0, (entry.Attributes & SeGroupUseForDenyOnly) != 0);
            }
            return (false, false);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    enum TokenInformationClass { TokenGroups = 2, TokenElevation = 20 }
    [StructLayout(LayoutKind.Sequential)] struct TokenElevation { public uint TokenIsElevated; }
    [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(SafeAccessTokenHandle token, TokenInformationClass informationClass, IntPtr information, int informationLength, out int returnLength);
}

public static class Program
{
    public static int Main()
    {
        try
        {
            var result = ProbeRunner.Run(Environment.CurrentDirectory);
            Console.Out.WriteLine(JsonSerializer.Serialize(result));
            return ProbeRunner.Succeeded(result) ? 0 : 10;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 11;
        }
    }
}
