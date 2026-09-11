using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Diagnostics;
using Symphony.WindowsBroker;
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
            ["GITHUB_TOKEN"] = "secret", ["UNRELATED"] = "drop"
        };
        var environment = BrokerPolicy.WorkerEnvironment(request, host);
        Assert.Equal("safe", environment["PATH"]);
        Assert.Equal(request.CodexHome, environment["CODEX_HOME"]);
        Assert.Equal("call-local-token", environment["GH_TOKEN"]);
        Assert.DoesNotContain(environment, pair => pair.Key.Contains("TOKEN", StringComparison.OrdinalIgnoreCase) && pair.Key != "GH_TOKEN");
        Assert.DoesNotContain("UNRELATED", environment.Keys);
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
        File.WriteAllText(config, System.Text.Json.JsonSerializer.Serialize(new { schema=1, node="Amy", pipe_name="test", controller_sid=WindowsIdentity.GetCurrent().User!.Value, workspace_root=workspace, private_home_root=privateRoot, codex_home_root=codexRoot, codex_exe=codexExe }));
        var options = BrokerConfiguration.FromFile(config);
        Assert.Equal(Path.Combine(privateRoot, "central-brain"), options.Profiles["central-brain"].PrivateHome);
        Assert.Equal(Path.Combine(codexRoot, "project-management"), options.Profiles["project-management"].CodexHome);
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
    public void Broker_service_is_single_session_to_keep_service_sid_acl_grants_isolated()
    {
        Assert.Equal(1, PipeFactory.MaxServerInstances);
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
            BrokerFrame frame;
            do { frame = await Frame.ReadAsync(client, stop.Token); } while (frame.Kind is FrameKind.Stdout or FrameKind.Stderr);
            Assert.Equal(FrameKind.Error, frame.Kind);
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
    public void Pipe_security_allows_only_system_and_controller_and_denies_network()
    {
        if (!OperatingSystem.IsWindows()) return;
        var controller = WindowsIdentity.GetCurrent().User!;
        var rules = PipeFactory.BuildSecurity(controller).GetAccessRules(true, false, typeof(SecurityIdentifier))
            .Cast<System.IO.Pipes.PipeAccessRule>().ToArray();
        Assert.Contains(rules, r => r.IdentityReference.Equals(controller) && r.AccessControlType == System.Security.AccessControl.AccessControlType.Allow);
        Assert.Contains(rules, r => r.IdentityReference.Equals(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null)));
        Assert.Contains(rules, r => r.IdentityReference.Equals(new SecurityIdentifier(WellKnownSidType.NetworkSid, null)) && r.AccessControlType == System.Security.AccessControl.AccessControlType.Deny);
    }

    [Fact]
    public async Task Pipe_dacl_rejects_a_non_controller_token()
    {
        if (!OperatingSystem.IsWindows()) return;
        var pipeName = "symphony-denied-" + Guid.NewGuid().ToString("N");
        var deniedSid = new SecurityIdentifier(WellKnownSidType.LocalServiceSid, null);
        await using var server = PipeFactory.Create(pipeName, deniedSid);
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
        return new(pipe, WindowsIdentity.GetCurrent().User!.Value, Path.Combine(root, "codex.exe"),
            Path.Combine(root, "workspace"), new Dictionary<string, ProfileRoots> { ["central-brain"] = new(Path.GetDirectoryName(request.PrivateHome)!, Path.GetDirectoryName(request.CodexHome)!) }, idle, absolute);
    }

    BrokerPolicy Policy(string workspace, string privateHome, string codexHome) =>
        new(workspace, new Dictionary<string, ProfileRoots> { ["central-brain"] = new(privateHome, codexHome) });

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
