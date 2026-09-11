using System.Text.RegularExpressions;
namespace Symphony.WindowsBroker;
public sealed record BrokerRequest(string Profile, string Workspace, string PrivateHome, string CodexHome);
public sealed record ProfileRoots(string PrivateHome, string CodexHome);
public sealed class BrokerPolicy(string workspaceRoot, IReadOnlyDictionary<string, ProfileRoots> profiles)
{
    static readonly Regex SecretName = new("(LINEAR|TOKEN|JWT|SECRET|PASSWORD|PRIVATE_KEY|GITHUB_APP|CLAIM|CONTROLLER)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    public BrokerRequest Validate(BrokerRequest request)
    {
        if (!profiles.TryGetValue(request.Profile, out var profile)) throw new InvalidDataException("profile_denied");
        return request with { Workspace = CanonicalUnder(Path.Combine(workspaceRoot, request.Profile), request.Workspace), PrivateHome = CanonicalUnder(profile.PrivateHome, request.PrivateHome), CodexHome = CanonicalExact(profile.CodexHome, request.CodexHome) };
    }
    public static Dictionary<string, string> WorkerEnvironment(BrokerRequest request, IReadOnlyDictionary<string, string> host)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in new[] { "SystemRoot", "WINDIR", "TEMP", "TMP", "PATH", "PATHEXT", "COMSPEC" }) if (host.TryGetValue(key, out var value) && !SecretName.IsMatch(key)) result[key] = value;
        result["HOME"] = request.PrivateHome; result["USERPROFILE"] = request.PrivateHome; result["CODEX_HOME"] = request.CodexHome;
        return result;
    }
    static string CanonicalExact(string expected, string supplied)
    {
        var a = Canonical(expected); var b = Canonical(supplied);
        if (!StringComparer.OrdinalIgnoreCase.Equals(a, b)) throw new InvalidDataException("profile_path_denied");
        return b;
    }
    static string CanonicalUnder(string root, string supplied)
    {
        var a = Canonical(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); var b = Canonical(supplied);
        if (StringComparer.OrdinalIgnoreCase.Equals(a, b) || !b.StartsWith(a + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("path_denied");
        return b;
    }
    static string Canonical(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("path_not_absolute");
        var full = Path.GetFullPath(path); var root = Path.GetPathRoot(full) ?? throw new InvalidDataException("path_root_missing"); var current = root;
        foreach (var component in full[root.Length..].Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries))
        { current = Path.Combine(current, component); if (!Directory.Exists(current) && !File.Exists(current)) throw new InvalidDataException("path_missing"); if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("reparse_denied"); }
        return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }
    public static string ExistingFile(string path) { var canonical = Canonical(path); if (!File.Exists(canonical)) throw new InvalidDataException("file_required"); return canonical; }
    public static string ExistingDirectory(string path) { var canonical = Canonical(path); if (!Directory.Exists(canonical)) throw new InvalidDataException("directory_required"); return canonical; }
}
