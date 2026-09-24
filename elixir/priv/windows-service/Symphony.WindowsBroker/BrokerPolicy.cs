using System.Text.RegularExpressions;
namespace Symphony.WindowsBroker;
public sealed record BrokerRequest(string Profile, string Workspace, string PrivateHome, string CodexHome, string? GitHubToken = null, string? Model = null);
public sealed record ProfileRoots(string PrivateHome, string CodexHome);
public sealed class BrokerPolicy(string workspaceRoot, IReadOnlyDictionary<string, ProfileRoots> profiles)
{
    static readonly Regex SecretName = new("(LINEAR|TOKEN|JWT|SECRET|PASSWORD|PRIVATE_KEY|GITHUB_APP|CLAIM|CONTROLLER)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    const string GitCredentialHelper = "!f() { test \"$1\" = get || exit 0; protocol=; host=; while IFS== read -r key value; do case \"$key\" in protocol) protocol=\"$value\" ;; host) host=\"$value\" ;; esac; done; test \"$protocol\" = https && test \"$host\" = github.com || exit 1; printf \"username=x-access-token\\npassword=%s\\n\" \"$GH_TOKEN\"; }; f";
    public BrokerRequest Validate(BrokerRequest request)
    {
        if (!profiles.TryGetValue(request.Profile, out var profile)) throw new InvalidDataException("profile_denied");
        ValidateOptionalSecret(request.GitHubToken, "github_token_invalid");
        ValidateOptionalModel(request.Model);
        return request with { Workspace = CanonicalUnder(Path.Combine(workspaceRoot, request.Profile), request.Workspace, allowEqual: false), PrivateHome = CanonicalUnder(profile.PrivateHome, request.PrivateHome, allowEqual: true), CodexHome = CanonicalUnder(profile.CodexHome, request.CodexHome, allowEqual: true) };
    }
    public static Dictionary<string, string> WorkerEnvironment(BrokerRequest request, IReadOnlyDictionary<string, string> host)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in new[] { "SystemRoot", "WINDIR", "TEMP", "TMP", "PATH", "PATHEXT", "COMSPEC" }) if (host.TryGetValue(key, out var value) && !SecretName.IsMatch(key)) result[key] = value;
        result["HOME"] = request.PrivateHome; result["USERPROFILE"] = request.PrivateHome; result["CODEX_HOME"] = request.CodexHome;
        result["GH_CONFIG_DIR"] = Path.Combine(request.PrivateHome, "gh");
        result["XDG_CONFIG_HOME"] = Path.Combine(request.PrivateHome, "xdg-config");
        result["XDG_CACHE_HOME"] = Path.Combine(request.PrivateHome, "xdg-cache");
        result["XDG_DATA_HOME"] = Path.Combine(request.PrivateHome, "xdg-data");
        result["GCM_INTERACTIVE"] = "Never";
        result["GIT_CONFIG_COUNT"] = "0";
        result["GIT_CONFIG_GLOBAL"] = "NUL";
        result["GIT_CONFIG_NOSYSTEM"] = "1";
        result["GIT_CONFIG_PARAMETERS"] = "'credential.helper='";
        result["GIT_CONFIG_SYSTEM"] = "NUL";
        result["GIT_TERMINAL_PROMPT"] = "0";
        if (!string.IsNullOrWhiteSpace(request.GitHubToken))
        {
            result["GH_TOKEN"] = request.GitHubToken!;
            result["GIT_CONFIG_PARAMETERS"] = $"'credential.helper=' 'credential.helper={GitCredentialHelper}'";
        }
        return result;
    }
    public static string[] CodexArguments(BrokerRequest request)
    {
        var args = new List<string> { "--config", "shell_environment_policy.inherit=all" };
        if (!string.IsNullOrWhiteSpace(request.Model)) args.AddRange(new[] { "--config", $"model=\"{request.Model}\"" });
        args.Add("app-server");
        return args.ToArray();
    }
    static void ValidateOptionalSecret(string? value, string reason)
    {
        if (value is not null && (value.Length > 8192 || value.Contains('\0') || value.Contains('\r') || value.Contains('\n'))) throw new InvalidDataException(reason);
    }
    static void ValidateOptionalModel(string? model)
    {
        if (model is null) return;
        if (string.IsNullOrWhiteSpace(model) || !Regex.IsMatch(model, @"\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,63}\z")) throw new InvalidDataException("model_denied");
    }
    static string CanonicalUnder(string root, string supplied, bool allowEqual)
    {
        var a = ExistingDirectory(root); var b = ConfiguredRoot(supplied);
        if (StringComparer.OrdinalIgnoreCase.Equals(a, b)) { if (!allowEqual) throw new InvalidDataException("path_denied"); return b; }
        if (!b.StartsWith(a + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("path_denied");
        var current = a;
        foreach (var component in b[(a.Length + 1)..].Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries))
        { current = Path.Combine(current, component); DemandExistingNonReparse(current); }
        return b;
    }
    public static string ConfiguredRoot(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("path_not_absolute");
        return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }
    static void DemandExistingNonReparse(string path)
    {
        if (!Directory.Exists(path) && !File.Exists(path)) throw new InvalidDataException("path_missing");
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("reparse_denied");
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
