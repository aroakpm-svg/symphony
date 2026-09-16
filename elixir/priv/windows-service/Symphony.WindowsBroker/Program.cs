using System.ServiceProcess;
using System.Text.Json;
using System.Text.Json.Serialization;
namespace Symphony.WindowsBroker;
public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Contains("--client", StringComparer.OrdinalIgnoreCase)) return await RunClientAsync(args);
            var configPath = Value(args, "--config") ?? throw new ArgumentException("missing_config");
            var options = BrokerConfiguration.FromFile(configPath);
            if (args.Contains("--server", StringComparer.OrdinalIgnoreCase)) { await using var server = new BrokerServer(options, new CodexProcessFactory()); await server.RunAsync(CancellationToken.None); return 0; }
            if (!args.Contains("--service", StringComparer.OrdinalIgnoreCase)) throw new ArgumentException("mode_required");
            ServiceBase.Run(new BrokerWindowsService(options, new CodexProcessFactory()));
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }
    static async Task<int> RunClientAsync(string[] args)
    {
        string Required(string name) => Value(args, name) ?? throw new ArgumentException($"missing_{name.TrimStart('-')}");
        var request = new BrokerRequest(
            Required("--profile"),
            Required("--workspace"),
            Required("--private-home"),
            Required("--codex-home"),
            Environment.GetEnvironmentVariable("GH_TOKEN"),
            Environment.GetEnvironmentVariable("CODEX_DEFAULT_MODEL"));
        return await BrokerClient.RunAsync(Required("--pipe"), request, Console.OpenStandardInput(), Console.OpenStandardOutput(), Console.OpenStandardError(), CancellationToken.None);
    }
    static string? Value(string[] args, string name) { var index = Array.FindIndex(args, value => value.Equals(name, StringComparison.OrdinalIgnoreCase)); return index >= 0 && index + 1 < args.Length ? args[index + 1] : null; }
}
sealed class BrokerWindowsService : ServiceBase
{
    readonly BrokerOptions options;
    readonly IBrokerProcessFactory factory;
    readonly CancellationTokenSource stop = new();
    Task? running;

    public BrokerWindowsService(BrokerOptions options, IBrokerProcessFactory factory)
    {
        this.options = options;
        this.factory = factory;
        ServiceName = options.ServiceName;
    }

    protected override void OnStart(string[] args)
    {
        running = Task.Run(RunAsync);
    }

    protected override void OnStop()
    {
        stop.Cancel();
        try { running?.GetAwaiter().GetResult(); }
        catch (OperationCanceledException) { }
    }

    async Task RunAsync()
    {
        await using var server = new BrokerServer(options, factory);
        await server.RunAsync(stop.Token);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) stop.Dispose();
        base.Dispose(disposing);
    }
}
public sealed record BrokerSettings(
    [property: JsonPropertyName("schema")] int Schema,
    [property: JsonPropertyName("node")] string Node,
    [property: JsonPropertyName("pipe_name")] string PipeName,
    [property: JsonPropertyName("service_name")] string ServiceName,
    [property: JsonPropertyName("controller_sid")] string ControllerSid,
    [property: JsonPropertyName("workspace_root")] string WorkspaceRoot,
    [property: JsonPropertyName("private_home_root")] string PrivateHomeRoot,
    [property: JsonPropertyName("codex_home_root")] string CodexHomeRoot,
    [property: JsonPropertyName("codex_exe")] string CodexExecutable,
    [property: JsonPropertyName("idle_timeout_seconds")] int? IdleTimeoutSeconds = null,
    [property: JsonPropertyName("absolute_timeout_seconds")] int? AbsoluteTimeoutSeconds = null);
public static class BrokerConfiguration
{
    public static BrokerOptions FromFile(string path)
    {
        string canonicalConfig;
        try { canonicalConfig = BrokerPolicy.ExistingFile(path); }
        catch (InvalidDataException) { throw new InvalidDataException("config_path_invalid"); }
        var settings = JsonSerializer.Deserialize<BrokerSettings>(File.ReadAllText(canonicalConfig)) ?? throw new InvalidDataException("config_invalid");
        if (settings.Schema != 1 || settings.Node is not ("Amy" or "Matt") || settings.ServiceName != $"AROAKSymphonyCodex{settings.Node}") throw new InvalidDataException("config_schema_invalid");
        if (settings.IdleTimeoutSeconds is <= 0 || settings.AbsoluteTimeoutSeconds is <= 0) throw new InvalidDataException("timeout_invalid");
        var workspaceRoot = BrokerPolicy.ExistingDirectory(settings.WorkspaceRoot);
        var privateRoot = BrokerPolicy.ExistingDirectory(settings.PrivateHomeRoot);
        var codexRoot = BrokerPolicy.ExistingDirectory(settings.CodexHomeRoot);
        var codexExecutable = BrokerPolicy.ExistingFile(settings.CodexExecutable);
        var profiles = new Dictionary<string, ProfileRoots>(StringComparer.OrdinalIgnoreCase)
        {
            ["central-brain"] = new(BrokerPolicy.ExistingDirectory(Path.Combine(privateRoot, "central-brain")), BrokerPolicy.ExistingDirectory(Path.Combine(codexRoot, "central-brain"))),
            ["project-management"] = new(BrokerPolicy.ExistingDirectory(Path.Combine(privateRoot, "project-management")), BrokerPolicy.ExistingDirectory(Path.Combine(codexRoot, "project-management")))
        };
        foreach (var profile in profiles.Keys) BrokerPolicy.ExistingDirectory(Path.Combine(workspaceRoot, profile));
        return new(settings.PipeName, settings.ServiceName, settings.ControllerSid, codexExecutable, workspaceRoot, profiles, TimeSpan.FromSeconds(settings.IdleTimeoutSeconds ?? 900), TimeSpan.FromSeconds(settings.AbsoluteTimeoutSeconds ?? 14400));
    }
}
