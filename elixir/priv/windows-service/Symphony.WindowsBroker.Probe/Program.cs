using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Symphony.WindowsBroker.Probe;

public sealed record ProbeConfiguration(
    [property: JsonPropertyName("synthetic_key_path")] string SyntheticKeyPath,
    [property: JsonPropertyName("protected_grant_root")] string ProtectedGrantRoot);

public sealed record ProbeResult(
    string UserSid,
    bool KeyDirectoryListDenied,
    bool KeyReadDenied,
    bool GrantRootRenameDenied,
    bool WorkspaceCreateEditDeleteSucceeded);

public static class ProbeRunner
{
    public const string ConfigurationFileName = ".aro197-boundary-probe.json";
    static readonly JsonSerializerOptions StrictJson = new() { PropertyNameCaseInsensitive = false, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };

    public static ProbeResult Run(string workingDirectory)
    {
        var workspace = ExistingDirectory(workingDirectory);
        var configuration = JsonSerializer.Deserialize<ProbeConfiguration>(
            File.ReadAllText(ExistingFile(Path.Combine(workspace, ConfigurationFileName))), StrictJson)
            ?? throw new InvalidDataException("probe_config_invalid");
        var key = TargetPath(configuration.SyntheticKeyPath);
        var keyDirectory = Path.GetDirectoryName(key) ?? throw new InvalidDataException("probe_key_parent_missing");
        var protectedGrantRoot = ExistingDirectory(configuration.ProtectedGrantRoot);
        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        var userSid = identity.User?.Value ?? throw new InvalidOperationException("probe_identity_missing");

        return new(
            userSid,
            Denied(() => Directory.EnumerateFileSystemEntries(keyDirectory).ToArray()),
            Denied(() => File.ReadAllBytes(key)),
            RenameDenied(protectedGrantRoot),
            ExerciseWorkspace(workspace));
    }

    public static bool Succeeded(ProbeResult result) =>
        result.UserSid != "S-1-5-18" &&
        result.KeyDirectoryListDenied &&
        result.KeyReadDenied &&
        result.GrantRootRenameDenied &&
        result.WorkspaceCreateEditDeleteSucceeded;

    static bool Denied(Action action)
    {
        try { action(); return false; }
        catch (UnauthorizedAccessException) { return true; }
    }

    static bool RenameDenied(string path)
    {
        var moved = path + ".aro197-rename-probe-" + Guid.NewGuid().ToString("N");
        try
        {
            Directory.Move(path, moved);
            Directory.Move(moved, path);
            return false;
        }
        catch (UnauthorizedAccessException) { return true; }
        catch (IOException error) when ((error.HResult & 0xffff) == 5) { return true; }
        finally
        {
            if (Directory.Exists(moved) && !Directory.Exists(path)) Directory.Move(moved, path);
        }
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
        catch (Exception error) when (error is UnauthorizedAccessException or IOException) { return false; }
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

    static string TargetPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("probe_path_not_absolute");
        return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    static string Canonical(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("probe_path_not_absolute");
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
