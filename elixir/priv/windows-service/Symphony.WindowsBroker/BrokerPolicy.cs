using System.Text.RegularExpressions;
using System.Text.Json;
using System.Text.Json.Serialization;
namespace Symphony.WindowsBroker;
public sealed record BrokerRequest(
    [property: JsonPropertyName("protocol_version")] int ProtocolVersion,
    [property: JsonPropertyName("request_id")] string RequestId,
    [property: JsonPropertyName("profile")] string Profile,
    [property: JsonPropertyName("workspace")] string Workspace);
public sealed record ValidatedBrokerRequest(string RequestId, string Profile, string Workspace, string PrivateHome, string CodexHome);
public sealed record ProfileRoots(string PrivateHome, string CodexHome);
public static class BrokerJson
{
    public static readonly JsonSerializerOptions Strict = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
}
public sealed class BrokerPolicy(string workspaceRoot, IReadOnlyDictionary<string, ProfileRoots> profiles)
{
    static readonly Regex SecretName = new("(LINEAR|TOKEN|JWT|SECRET|PASSWORD|PRIVATE_KEY|GITHUB_APP|CLAIM|CONTROLLER)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    static readonly Regex RequestId = new(@"\A[a-f0-9]{32}\z", RegexOptions.CultureInvariant);
    public ValidatedBrokerRequest Validate(BrokerRequest request)
    {
        if (request.ProtocolVersion != 1) throw new InvalidDataException("protocol_denied");
        var requestId = request.RequestId ?? string.Empty;
        if (!RequestId.IsMatch(requestId)) throw new InvalidDataException("request_id_denied");
        if (!profiles.TryGetValue(request.Profile, out var profile)) throw new InvalidDataException("profile_denied");
        var workspace = CanonicalUnder(Path.Combine(workspaceRoot, request.Profile), request.Workspace, allowEqual: false);
        return new(requestId, request.Profile, workspace, ExistingDirectory(profile.PrivateHome), ExistingDirectory(profile.CodexHome));
    }
    public static Dictionary<string, string> WorkerEnvironment(ValidatedBrokerRequest request, IReadOnlyDictionary<string, string> host)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in new[] { "SystemRoot", "WINDIR", "TEMP", "TMP", "PATH", "PATHEXT", "COMSPEC" }) if (host.TryGetValue(key, out var value) && !SecretName.IsMatch(key)) result[key] = value;
        result["HOME"] = request.PrivateHome; result["USERPROFILE"] = request.PrivateHome; result["CODEX_HOME"] = request.CodexHome;
        result["GCM_INTERACTIVE"] = "Never";
        result["GIT_CONFIG_COUNT"] = "0";
        result["GIT_CONFIG_GLOBAL"] = "NUL";
        result["GIT_CONFIG_NOSYSTEM"] = "1";
        result["GIT_CONFIG_PARAMETERS"] = "'credential.helper='";
        result["GIT_CONFIG_SYSTEM"] = "NUL";
        result["GIT_TERMINAL_PROMPT"] = "0";
        return result;
    }
    public static string[] CodexArguments() => new[] { "--config", "shell_environment_policy.inherit=all", "app-server" };
    static string CanonicalUnder(string root, string supplied, bool allowEqual)
    {
        var a = Canonical(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); var b = Canonical(supplied);
        if (StringComparer.OrdinalIgnoreCase.Equals(a, b)) { if (allowEqual) return b; throw new InvalidDataException("path_denied"); }
        if (!b.StartsWith(a + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("path_denied");
        return b;
    }
    static string Canonical(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("path_not_absolute");
        if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.StartsWith(@"\\?\", StringComparison.Ordinal)) throw new InvalidDataException("path_denied");
        var full = Path.GetFullPath(path); var root = Path.GetPathRoot(full) ?? throw new InvalidDataException("path_root_missing"); var current = root;
        foreach (var component in full[root.Length..].Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries))
        { current = Path.Combine(current, component); if (!Directory.Exists(current) && !File.Exists(current)) throw new InvalidDataException("path_missing"); if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("reparse_denied"); }
        return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }
    public static string ExistingFile(string path) { var canonical = Canonical(path); if (!File.Exists(canonical)) throw new InvalidDataException("file_required"); return canonical; }
    public static string ExistingDirectory(string path) { var canonical = Canonical(path); if (!Directory.Exists(canonical)) throw new InvalidDataException("directory_required"); return canonical; }
}
