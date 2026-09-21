using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Diagnostics;
using Symphony.WindowsBroker;
using Symphony.WindowsBroker.Probe;
using Xunit;

namespace Symphony.WindowsBroker.Tests;

public sealed class BrokerTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "symphony-broker-tests", Guid.NewGuid().ToString("N"));

    public BrokerTests() => Directory.CreateDirectory(root);
    public void Dispose() => Directory.Delete(root, true);

    [Fact]
    public async Task Frame_round_trips_payload_and_rejects_oversize()
    {
        await using var stream = new MemoryStream();
        await Frame.WriteAsync(stream, FrameKind.Stdout, Encoding.UTF8.GetBytes("hello"), default);
        stream.Position = 0;
        var frame = await Frame.ReadAsync(stream, default);
        Assert.Equal(FrameKind.Stdout, frame.Kind);
        Assert.Equal("hello", Encoding.UTF8.GetString(frame.Payload));

        stream.SetLength(0);
        stream.WriteByte((byte)FrameKind.Stdin);
        var size = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(size, Frame.MaxPayloadLength + 1);
        stream.Write(size);
        stream.Position = 0;
        await Assert.ThrowsAsync<InvalidDataException>(() => Frame.ReadAsync(stream, default).AsTask());
    }

    [Fact]
    public void Policy_rejects_wrong_profile_escape_root_and_reparse_point()
    {
        var workspace = MakeDirectory("workspace");
        var privateRoot = MakeDirectory("private", "central-brain");
        var privateHome = MakeDirectory("private", "central-brain", "ARO-1-r1");
        var codexRoot = MakeDirectory("codex", "central-brain");
        var codexHome = MakeDirectory("codex", "central-brain", "ARO-1-r1");
        var policy = Policy(workspace, privateRoot, codexRoot);
        var valid = policy.Validate(new BrokerRequest("central-brain", MakeDirectory("workspace", "central-brain", "ARO-1"), privateHome, codexHome));
        Assert.Equal("central-brain", valid.Profile);
        Assert.Throws<InvalidDataException>(() => policy.Validate(valid with { Profile = "unknown" }));
        Assert.Throws<InvalidDataException>(() => policy.Validate(valid with { Workspace = root }));
        Assert.Equal(privateRoot, policy.Validate(valid with { PrivateHome = privateRoot }).PrivateHome);
        Assert.Equal(codexRoot, policy.Validate(valid with { CodexHome = codexRoot }).CodexHome);

        var link = Path.Combine(workspace, "central-brain", "link");
        try
        {
            Directory.CreateSymbolicLink(link, root);
            Assert.Throws<InvalidDataException>(() => policy.Validate(valid with { Workspace = link }));
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException) { }
    }

    [Fact]
    public void Worker_environment_is_minimal_and_drops_secrets()
    {
        var request = new BrokerRequest("central-brain", root, Path.Combine(root, "private"), Path.Combine(root, "codex"), "call-local-token");
        var host = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["SystemRoot"] = @"C:\Windows", ["PATH"] = "safe", ["LINEAR_API_KEY"] = "secret",
            ["GITHUB_TOKEN"] = "secret", ["UNRELATED"] = "drop",
            ["GIT_CONFIG_PARAMETERS"] = "'credential.helper=!host-controlled'",
            ["GIT_CONFIG_GLOBAL"] = @"C:\host-controlled.gitconfig"
        };
        var environment = BrokerPolicy.WorkerEnvironment(request, host);
        Assert.Equal("safe", environment["PATH"]);
        Assert.Equal(request.CodexHome, environment["CODEX_HOME"]);
        Assert.Equal("call-local-token", environment["GH_TOKEN"]);
        Assert.Equal("Never", environment["GCM_INTERACTIVE"]);
        Assert.Equal("0", environment["GIT_CONFIG_COUNT"]);
        Assert.Equal("NUL", environment["GIT_CONFIG_GLOBAL"]);
        Assert.Equal("1", environment["GIT_CONFIG_NOSYSTEM"]);
        Assert.Equal("NUL", environment["GIT_CONFIG_SYSTEM"]);
        Assert.Equal("0", environment["GIT_TERMINAL_PROMPT"]);
        Assert.Contains("credential.helper=!f()", environment["GIT_CONFIG_PARAMETERS"]);
        Assert.DoesNotContain("host-controlled", environment["GIT_CONFIG_PARAMETERS"]);
        Assert.DoesNotContain(environment, pair => pair.Key.Contains("TOKEN", StringComparison.OrdinalIgnoreCase) && pair.Key != "GH_TOKEN");
        Assert.DoesNotContain("UNRELATED", environment.Keys);
    }

    [Fact]
    public async Task Worker_git_environment_uses_only_the_fixed_https_github_helper()
    {
        if (!OperatingSystem.IsWindows()) return;

        var marker = Path.Combine(root, "ambient-helper.marker");
        var globalConfig = Path.Combine(root, "ambient.gitconfig");
        File.WriteAllText(globalConfig, $"[credential]\n\thelper = !echo ambient>{marker.Replace('\\', '/')}\n");
        var host = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(entry => (string)entry.Key, entry => (string)entry.Value!, StringComparer.OrdinalIgnoreCase);
        host["GIT_CONFIG_GLOBAL"] = globalConfig;
        host["GIT_CONFIG_PARAMETERS"] = "'credential.helper=!host-controlled'";
        var request = new BrokerRequest("central-brain", root, Path.Combine(root, "private"), Path.Combine(root, "codex"), "call-local-token");
        var environment = BrokerPolicy.WorkerEnvironment(request, host);

        var github = await GitCredentialFillAsync("protocol=https\nhost=github.com\n\n", environment);
        Assert.Equal(0, github.ExitCode);
        Assert.Contains("username=x-access-token", github.Output);
        Assert.Contains("password=call-local-token", github.Output);
        Assert.False(File.Exists(marker));

        var denied = await GitCredentialFillAsync("protocol=https\nhost=example.com\n\n", environment);
        Assert.NotEqual(0, denied.ExitCode);
        Assert.False(File.Exists(marker));
    }

    [Fact]
    public void Worker_environment_without_a_call_local_token_still_denies_ambient_credentials()
    {
        var request = new BrokerRequest("central-brain", root, Path.Combine(root, "private"), Path.Combine(root, "codex"));
        var host = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["GIT_CONFIG_PARAMETERS"] = "'credential.helper=!host-controlled'",
            ["GITHUB_TOKEN"] = "ambient-token"
        };

        var environment = BrokerPolicy.WorkerEnvironment(request, host);

        Assert.DoesNotContain("GH_TOKEN", environment.Keys);
        Assert.DoesNotContain("GITHUB_TOKEN", environment.Keys);
        Assert.Equal("'credential.helper='", environment["GIT_CONFIG_PARAMETERS"]);
        Assert.Equal("NUL", environment["GIT_CONFIG_GLOBAL"]);
        Assert.Equal("NUL", environment["GIT_CONFIG_SYSTEM"]);
        Assert.Equal("0", environment["GIT_TERMINAL_PROMPT"]);
    }

    [Fact]
    public void Policy_validates_call_local_secret_and_model_inputs()
    {
        var workspace = MakeDirectory("workspace");
        var privateRoot = MakeDirectory("private", "central-brain");
        var privateHome = MakeDirectory("private", "central-brain", "ARO-1-r1");
        var codexRoot = MakeDirectory("codex", "central-brain");
        var codexHome = MakeDirectory("codex", "central-brain", "ARO-1-r1");
        var policy = Policy(workspace, privateRoot, codexRoot);
        var valid = new BrokerRequest("central-brain", MakeDirectory("workspace", "central-brain", "ARO-1"), privateHome, codexHome, "token", "gpt-5.5");

        Assert.Equal("gpt-5.5", policy.Validate(valid).Model);
        Assert.Equal(new[] { "--config", "shell_environment_policy.inherit=all", "--config", "model=\"gpt-5.5\"", "app-server" }, BrokerPolicy.CodexArguments(valid));
        Assert.Throws<InvalidDataException>(() => policy.Validate(valid with { GitHubToken = "bad\nsecret" }));
        Assert.Throws<InvalidDataException>(() => policy.Validate(valid with { Model = "bad model" }));
    }

    [Fact]
    public void Json_configuration_matches_the_installer_schema()
    {
        var workspace = MakeDirectory("workspace"); var privateRoot = MakeDirectory("private"); var codexRoot = MakeDirectory("codex");
        var codexExe = Path.Combine(root, "codex.exe"); File.WriteAllText(codexExe, "stub");
        foreach (var profile in new[] { "central-brain", "project-management" }) { MakeDirectory("workspace", profile); MakeDirectory("private", profile); MakeDirectory("codex", profile); }
        var config = Path.Combine(root, "broker-settings.json");
        File.WriteAllText(config, System.Text.Json.JsonSerializer.Serialize(new { schema=1, node="Amy", service_name="AROAKSymphonyCodexAmy", pipe_name="test", controller_sid=WindowsIdentity.GetCurrent().User!.Value, workspace_root=workspace, private_home_root=privateRoot, codex_home_root=codexRoot, codex_exe=codexExe }));
        var options = BrokerConfiguration.FromFile(config);
        Assert.Equal("AROAKSymphonyCodexAmy", options.ServiceName);
        Assert.Equal(Path.Combine(privateRoot, "central-brain"), options.Profiles["central-brain"].PrivateHome);
        Assert.Equal(Path.Combine(codexRoot, "project-management"), options.Profiles["project-management"].CodexHome);
    }

    [Fact]
    public void Json_configuration_defers_private_profile_access_until_the_controller_grant()
    {
        var workspace = MakeDirectory("deferred-workspace");
        var privateRoot = MakeDirectory("deferred-private");
        var codexRoot = MakeDirectory("deferred-codex");
        var codexExe = Path.Combine(root, "deferred-codex.exe"); File.WriteAllText(codexExe, "stub");
        foreach (var profile in new[] { "central-brain", "project-management" }) MakeDirectory("deferred-workspace", profile);
        var config = Path.Combine(root, "deferred-broker-settings.json");
        File.WriteAllText(config, System.Text.Json.JsonSerializer.Serialize(new { schema=1, node="Matt", service_name="AROAKSymphonyCodexMatt", pipe_name="test", controller_sid=WindowsIdentity.GetCurrent().User!.Value, workspace_root=workspace, private_home_root=privateRoot, codex_home_root=codexRoot, codex_exe=codexExe }));

        var options = BrokerConfiguration.FromFile(config);

        Assert.Equal(Path.Combine(privateRoot, "central-brain"), options.Profiles["central-brain"].PrivateHome);
        Assert.Equal(Path.Combine(codexRoot, "project-management"), options.Profiles["project-management"].CodexHome);
    }

    [Fact]
    public void Json_configuration_accepts_utf8_bom_written_by_windows_powershell()
    {
        var workspace = MakeDirectory("workspace"); var privateRoot = MakeDirectory("private"); var codexRoot = MakeDirectory("codex");
        var codexExe = Path.Combine(root, "codex.exe"); File.WriteAllText(codexExe, "stub");
        foreach (var profile in new[] { "central-brain", "project-management" }) { MakeDirectory("workspace", profile); MakeDirectory("private", profile); MakeDirectory("codex", profile); }
        var config = Path.Combine(root, "broker-settings-bom.json");
        var json = System.Text.Json.JsonSerializer.Serialize(new { schema=1, node="Amy", service_name="AROAKSymphonyCodexAmy", pipe_name="test", controller_sid=WindowsIdentity.GetCurrent().User!.Value, workspace_root=workspace, private_home_root=privateRoot, codex_home_root=codexRoot, codex_exe=codexExe });
        File.WriteAllBytes(config, new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes(json)).ToArray());

        var options = BrokerConfiguration.FromFile(config);

        Assert.Equal("AROAKSymphonyCodexAmy", options.ServiceName);
    }

    [Fact]
    public async Task Client_and_server_proxy_stdio_and_return_exit_code()
    {
        var pipe = "symphony-test-" + Guid.NewGuid().ToString("N");
        var request = ValidRequest();
        var options = TestOptions(pipe, idle: TimeSpan.FromSeconds(5), absolute: TimeSpan.FromSeconds(10));
        await using var server = new BrokerServer(options, new TestProcessFactory(TestBehavior.Echo));
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var serving = server.ServeOneAsync(stop.Token);
        await using var input = new MemoryStream(Encoding.UTF8.GetBytes("hello"));
        await using var output = new MemoryStream();
        await using var error = new MemoryStream();
        var exit = await BrokerClient.RunAsync(options.PipeName, request, input, output, error, stop.Token);
        await serving;
        Assert.Equal(0, exit);
        Assert.Equal("hello", Encoding.UTF8.GetString(output.ToArray()));
        Assert.Empty(error.ToArray());
    }

    [Fact]
    public async Task Client_times_out_when_the_service_pipe_is_unavailable()
    {
        Assert.InRange(BrokerClient.DefaultConnectTimeout, TimeSpan.FromMilliseconds(1), TimeSpan.FromMilliseconds(4999));
        var elapsed = Stopwatch.StartNew();
        await using var input = new MemoryStream();
        await using var output = new MemoryStream();
        await using var error = new MemoryStream();

        var failure = await Assert.ThrowsAsync<TimeoutException>(() => BrokerClient.RunAsync(
            "symphony-missing-" + Guid.NewGuid().ToString("N"), ValidRequest(), input, output, error,
            CancellationToken.None, TimeSpan.FromMilliseconds(100)));

        Assert.Equal("broker_connect_timeout", failure.Message);
        Assert.InRange(elapsed.Elapsed, TimeSpan.FromMilliseconds(50), TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task Native_process_host_starts_a_child_without_marshalling_safe_handles()
    {
        if (!OperatingSystem.IsWindows()) return;
        var request = new BrokerRequest("central-brain", root, MakeDirectory("native-private"), MakeDirectory("native-codex"));
        var executable = Path.Combine(Environment.SystemDirectory, "where.exe");
        var options = new BrokerOptions("unused", "unused", WindowsIdentity.GetCurrent().User!.Value, executable, root,
            new Dictionary<string, ProfileRoots>(), TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));

        await using var process = new CodexProcessFactory().Start(request, options);
        process.StandardInput.Dispose();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        await process.WaitForExitAsync(timeout.Token);
    }

    [Fact]
    public void Broker_service_is_single_session_to_keep_service_sid_acl_grants_isolated()
    {
        Assert.Equal(1, PipeFactory.MaxServerInstances);
    }

    [Fact]
    public void Service_identity_accepts_only_the_expected_low_privilege_sid()
    {
        var expected = new SecurityIdentifier("S-1-5-80-1-2-3-4-5");

        ServiceIdentity.Demand(expected, expected);
    }

    [Theory]
    [InlineData("S-1-5-18", "service_identity_system")]
    [InlineData("S-1-5-80-9-8-7-6-5", "service_identity_mismatch")]
    public void Service_identity_rejects_system_or_wrong_tokens(string userSid, string reason)
    {
        var expected = new SecurityIdentifier("S-1-5-80-1-2-3-4-5");

        Assert.Equal(reason, Assert.Throws<InvalidOperationException>(() => ServiceIdentity.Demand(expected, new SecurityIdentifier(userSid))).Message);
    }

    [Fact]
    public void Boundary_probe_negative_control_does_not_report_readable_files_as_denied()
    {
        var workspace = MakeDirectory("probe-workspace");
        var secretDirectory = MakeDirectory("probe-secret");
        var key = Path.Combine(secretDirectory, "app-key.pem");
        File.WriteAllText(key, "disposable-test-key");
        File.WriteAllText(Path.Combine(workspace, ProbeRunner.ConfigurationFileName), JsonSerializer.Serialize(new
        {
            synthetic_key_path = key
        }));

        var result = ProbeRunner.Run(workspace);

        Assert.False(result.KeyDirectoryListDenied);
        Assert.False(result.KeyReadDenied);
        Assert.True(result.WorkspaceCreateEditDeleteSucceeded);
        Assert.False(ProbeRunner.Succeeded(result));
    }

    [Fact]
    public void Boundary_probe_rejects_unknown_configuration_members()
    {
        var workspace = MakeDirectory("probe-config");
        File.WriteAllText(Path.Combine(workspace, ProbeRunner.ConfigurationFileName), "{\"synthetic_key_path\":\"C:\\\\key\",\"extra\":true}");

        Assert.Throws<JsonException>(() => ProbeRunner.Run(workspace));
    }

    [Fact]
    public void Boundary_probe_does_not_preflight_secret_target_existence()
    {
        var workspace = MakeDirectory("probe-missing-target");
        var secretDirectory = MakeDirectory("probe-missing-secret");
        var missingKey = Path.Combine(secretDirectory, "missing.pem");
        File.WriteAllText(Path.Combine(workspace, ProbeRunner.ConfigurationFileName), JsonSerializer.Serialize(new
        {
            synthetic_key_path = missingKey
        }));

        Assert.Throws<FileNotFoundException>(() => ProbeRunner.Run(workspace));
    }

    [Fact]
    public void Windows_service_onstart_returns_after_scheduling_broker_loop()
    {
        var program = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "Symphony.WindowsBroker", "Program.cs"));
        var service = program[program.IndexOf("sealed class BrokerWindowsService", StringComparison.Ordinal)..];
        Assert.Contains(" : ServiceBase", service);
        Assert.Contains("protected override void OnStart", service);
        Assert.Contains("running = Task.Run(RunAsync);", service);
        Assert.True(service.IndexOf("running = Task.Run(RunAsync);", StringComparison.Ordinal) < service.IndexOf("async Task RunAsync", StringComparison.Ordinal));
    }


    [Fact]
    public async Task Idle_and_absolute_timeouts_terminate_the_process_tree()
    {
        foreach (var (idle, absolute, behavior) in new[]
        {
            (TimeSpan.FromMilliseconds(150), TimeSpan.FromSeconds(5), TestBehavior.Silent),
            (TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(150), TestBehavior.Active)
        })
        {
            var pipe = "symphony-timeout-" + Guid.NewGuid().ToString("N");
            var factory = new TestProcessFactory(behavior);
            var options = TestOptions(pipe, idle, absolute);
            await using var server = new BrokerServer(options, factory);
            using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var serving = server.ServeOneAsync(stop.Token);
            await using var client = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Impersonation);
            await client.ConnectAsync(stop.Token);
            await Frame.WriteJsonAsync(client, FrameKind.Request, ValidRequest(), stop.Token);
            try
            {
                BrokerFrame frame;
                do { frame = await Frame.ReadAsync(client, stop.Token); } while (frame.Kind is FrameKind.Stdout or FrameKind.Stderr);
                Assert.Equal(FrameKind.Error, frame.Kind);
            }
            catch (EndOfStreamException)
            {
                // A timeout may close the pipe before the client observes the error frame; the invariant is that the child tree is terminated.
            }
            await serving;
            Assert.True(factory.LastProcess!.TreeTerminated);
        }
    }

    [Fact]
    public async Task Disconnect_and_server_stop_terminate_the_process_tree()
    {
        foreach (var disconnect in new[] { true, false })
        {
            var pipe = "symphony-stop-" + Guid.NewGuid().ToString("N");
            var factory = new TestProcessFactory(TestBehavior.Silent);
            var options = TestOptions(pipe, TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(20));
            await using var server = new BrokerServer(options, factory);
            using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var serving = server.ServeOneAsync(stop.Token);
            var client = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Impersonation);
            await client.ConnectAsync(stop.Token);
            await Frame.WriteJsonAsync(client, FrameKind.Request, ValidRequest(), stop.Token);
            await factory.Started.Task.WaitAsync(stop.Token);
            if (disconnect) client.Dispose(); else stop.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await serving);
            Assert.True(factory.LastProcess!.TreeTerminated);
            client.Dispose();
        }
    }

    [Fact]
    public void Pipe_security_allows_only_system_controller_and_server_identity_and_denies_network()
    {
        if (!OperatingSystem.IsWindows()) return;
        var controller = WindowsIdentity.GetCurrent().User!;
        var server = new SecurityIdentifier(WellKnownSidType.LocalServiceSid, null);
        var rules = PipeFactory.BuildSecurity(controller, server).GetAccessRules(true, false, typeof(SecurityIdentifier))
            .Cast<System.IO.Pipes.PipeAccessRule>().ToArray();
        Assert.Contains(rules, r => r.IdentityReference.Equals(controller) && r.AccessControlType == System.Security.AccessControl.AccessControlType.Allow);
        Assert.Contains(rules, r => r.IdentityReference.Equals(server) && r.AccessControlType == System.Security.AccessControl.AccessControlType.Allow);
        Assert.Contains(rules, r => r.IdentityReference.Equals(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null)));
        Assert.DoesNotContain(rules, r => r.IdentityReference.Equals(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null)));
        Assert.Contains(rules, r => r.IdentityReference.Equals(new SecurityIdentifier(WellKnownSidType.NetworkSid, null)) && r.AccessControlType == System.Security.AccessControl.AccessControlType.Deny);
    }

    [Fact]
    public async Task Pipe_dacl_rejects_a_non_controller_token()
    {
        if (!OperatingSystem.IsWindows()) return;
        var pipeName = "symphony-denied-" + Guid.NewGuid().ToString("N");
        var deniedSid = new SecurityIdentifier(WellKnownSidType.LocalServiceSid, null);
        await using var server = PipeFactory.Create(pipeName, deniedSid, new SecurityIdentifier(WellKnownSidType.LocalServiceSid, null));
        await using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Impersonation);
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
        await Assert.ThrowsAnyAsync<Exception>(async () => await client.ConnectAsync(timeout.Token));
        Assert.False(client.IsConnected);
    }

    [Fact]
    public async Task Closing_job_terminates_parent_and_descendant_processes()
    {
        if (!OperatingSystem.IsWindows()) return;
        var pidFile = Path.Combine(root, "child.pid");
        var escaped = pidFile.Replace("'", "''");
        var command = "$child=Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep 60' -PassThru; Set-Content -LiteralPath '" + escaped + "' -Value $child.Id; Wait-Process $child.Id";
        using var parent = Process.Start(new ProcessStartInfo("powershell.exe") { ArgumentList = { "-NoProfile", "-Command", command }, UseShellExecute = false, CreateNoWindow = true })!;
        using var job = new KillOnCloseJob();
        job.Add(parent);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (!File.Exists(pidFile)) await Task.Delay(20, timeout.Token);
        var childPid = int.Parse((await File.ReadAllTextAsync(pidFile, timeout.Token)).Trim());
        job.Dispose();
        await parent.WaitForExitAsync(timeout.Token);
        await Task.Delay(100, timeout.Token);
        Assert.Throws<ArgumentException>(() => Process.GetProcessById(childPid));
    }

    BrokerRequest ValidRequest()
    {
        var workspace = MakeDirectory("workspace", "central-brain", "ARO-1");
        var privateHome = MakeDirectory("private", "central-brain", "ARO-1-r1");
        MakeDirectory("codex", "central-brain");
        var codexHome = MakeDirectory("codex", "central-brain", "ARO-1-r1");
        return new("central-brain", workspace, privateHome, codexHome);
    }

    BrokerOptions TestOptions(string pipe, TimeSpan idle, TimeSpan absolute)
    {
        var request = ValidRequest();
        return new(pipe, "AROAKSymphonyCodexAmy", WindowsIdentity.GetCurrent().User!.Value, Path.Combine(root, "codex.exe"),
            Path.Combine(root, "workspace"), new Dictionary<string, ProfileRoots> { ["central-brain"] = new(Path.GetDirectoryName(request.PrivateHome)!, Path.GetDirectoryName(request.CodexHome)!) }, idle, absolute);
    }

    BrokerPolicy Policy(string workspace, string privateHome, string codexHome) =>
        new(workspace, new Dictionary<string, ProfileRoots> { ["central-brain"] = new(privateHome, codexHome) });

    static async Task<(int ExitCode, string Output)> GitCredentialFillAsync(string input, IReadOnlyDictionary<string, string> environment)
    {
        var start = new ProcessStartInfo("git")
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        start.ArgumentList.Add("credential");
        start.ArgumentList.Add("fill");
        start.Environment.Clear();
        foreach (var pair in environment) start.Environment[pair.Key] = pair.Value;
        using var process = Process.Start(start) ?? throw new InvalidOperationException("git_start_failed");
        await process.StandardInput.WriteAsync(input);
        process.StandardInput.Close();
        var stdout = await process.StandardOutput.ReadToEndAsync();
        var stderr = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return (process.ExitCode, stdout + stderr);
    }

    string MakeDirectory(params string[] parts)
    {
        var path = parts.Aggregate(root, Path.Combine);
        Directory.CreateDirectory(path);
        return path;
    }
}

enum TestBehavior { Echo, Silent, Active }

sealed class TestProcessFactory(TestBehavior behavior, int expectedStarts = 1) : IBrokerProcessFactory
{
    int startCount;
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource AllStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public int StartCount => Volatile.Read(ref startCount);
    public TestBrokerProcess? LastProcess { get; private set; }
    public IBrokerProcess Start(BrokerRequest request, BrokerOptions options)
    {
        LastProcess = new TestBrokerProcess(behavior);
        var count = Interlocked.Increment(ref startCount);
        Started.TrySetResult();
        if (count >= expectedStarts) AllStarted.TrySetResult();
        return LastProcess;
    }
}

sealed class TestBrokerProcess : IBrokerProcess
{
    readonly TestBehavior behavior;
    readonly AnonymousPipeServerStream input = new(PipeDirection.Out);
    readonly AnonymousPipeServerStream output = new(PipeDirection.In);
    readonly AnonymousPipeServerStream error = new(PipeDirection.In);
    readonly AnonymousPipeClientStream peerInput;
    readonly AnonymousPipeClientStream peerOutput;
    readonly AnonymousPipeClientStream peerError;
    readonly TaskCompletionSource<int> exited = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public bool TreeTerminated { get; private set; }

    public TestBrokerProcess(TestBehavior behavior)
    {
        this.behavior = behavior;
        peerInput = new AnonymousPipeClientStream(PipeDirection.In, input.ClientSafePipeHandle);
        peerOutput = new AnonymousPipeClientStream(PipeDirection.Out, output.ClientSafePipeHandle);
        peerError = new AnonymousPipeClientStream(PipeDirection.Out, error.ClientSafePipeHandle);
        if (behavior == TestBehavior.Echo) _ = EchoAsync();
        if (behavior == TestBehavior.Active) _ = ActiveAsync();
    }
    public Stream StandardInput => input;
    public Stream StandardOutput => output;
    public Stream StandardError => error;
    public Task<int> WaitForExitAsync(CancellationToken token) => exited.Task.WaitAsync(token);
    public void TerminateTree() { TreeTerminated = true; exited.TrySetCanceled(); }
    public ValueTask DisposeAsync() { input.Dispose(); output.Dispose(); error.Dispose(); peerInput.Dispose(); peerOutput.Dispose(); peerError.Dispose(); return ValueTask.CompletedTask; }
    async Task EchoAsync()
    {
        await peerInput.CopyToAsync(peerOutput); await peerOutput.FlushAsync(); peerOutput.Dispose(); peerError.Dispose(); exited.TrySetResult(0);
    }
    async Task ActiveAsync()
    {
        while (!TreeTerminated) { await peerOutput.WriteAsync(new byte[] { 1 }); await peerOutput.FlushAsync(); await Task.Delay(20); }
    }
}
