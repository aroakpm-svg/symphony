using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
namespace Symphony.WindowsBroker;
public sealed record BrokerOptions(string PipeName, string ControllerSid, string CodexExecutable, string WorkspaceRoot, IReadOnlyDictionary<string, ProfileRoots> Profiles, TimeSpan IdleTimeout, TimeSpan AbsoluteTimeout);
public sealed class BrokerServer(BrokerOptions options, IBrokerProcessFactory processFactory) : IAsyncDisposable
{
    public async Task ServeOneAsync(CancellationToken stop)
    {
        var sid = new SecurityIdentifier(options.ControllerSid);
        await using var pipe = PipeFactory.Create(options.PipeName, sid);
        await pipe.WaitForConnectionAsync(stop);
        PipeFactory.DemandController(pipe, sid);
        await RunSessionAsync(pipe, stop);
    }
    public async Task RunAsync(CancellationToken stop)
    {
        var sid = new SecurityIdentifier(options.ControllerSid);
        while (!stop.IsCancellationRequested)
        {
            await using var pipe = PipeFactory.Create(options.PipeName, sid);
            await pipe.WaitForConnectionAsync(stop);
            try { PipeFactory.DemandController(pipe, sid); await RunSessionAsync(pipe, stop); }
            catch (OperationCanceledException) when (!stop.IsCancellationRequested) { }
            catch (Exception error) when (!stop.IsCancellationRequested)
            {
                try { await Frame.WriteAsync(pipe, FrameKind.Error, Encoding.UTF8.GetBytes(error.Message), stop); } catch (IOException) { }
            }
        }
    }
    async Task RunSessionAsync(Stream pipe, CancellationToken stop)
    {
        using var absolute = CancellationTokenSource.CreateLinkedTokenSource(stop); absolute.CancelAfter(options.AbsoluteTimeout);
        var first = await Frame.ReadAsync(pipe, absolute.Token);
        if (first.Kind != FrameKind.Request) throw new InvalidDataException("request_required");
        var raw = JsonSerializer.Deserialize<BrokerRequest>(first.Payload) ?? throw new InvalidDataException("request_invalid");
        var request = new BrokerPolicy(options.WorkspaceRoot, options.Profiles).Validate(raw);
        await using var process = processFactory.Start(request, options);
        var writeGate = new SemaphoreSlim(1, 1); long activity = Environment.TickCount64;
        void Touch() => Interlocked.Exchange(ref activity, Environment.TickCount64);
        using var session = CancellationTokenSource.CreateLinkedTokenSource(absolute.Token);
        Task? input = InputAsync(pipe, process.StandardInput, Touch, session.Token);
        var stdout = PumpAsync(process.StandardOutput, pipe, FrameKind.Stdout, writeGate, Touch, session.Token);
        var stderr = PumpAsync(process.StandardError, pipe, FrameKind.Stderr, writeGate, Touch, session.Token);
        var exit = process.WaitForExitAsync(session.Token);
        string? failure = null; int exitCode = -1;
        try
        {
            while (true)
            {
                var idleRemaining = options.IdleTimeout - TimeSpan.FromMilliseconds(Environment.TickCount64 - Interlocked.Read(ref activity));
                if (idleRemaining <= TimeSpan.Zero) { failure = "idle_timeout"; break; }
                var idleDelay = Task.Delay(idleRemaining, session.Token);
                var candidates = input is null ? new[] { exit, idleDelay } : new[] { exit, input, idleDelay };
                var completed = await Task.WhenAny(candidates);
                if (completed == exit) { exitCode = await exit; break; }
                if (completed == input) { await input; input = null; continue; }
                if (absolute.IsCancellationRequested) { failure = stop.IsCancellationRequested ? "server_stopped" : "absolute_timeout"; break; }
                if (Environment.TickCount64 - Interlocked.Read(ref activity) >= options.IdleTimeout.TotalMilliseconds) { failure = "idle_timeout"; break; }
            }
        }
        catch (EndOfStreamException) { failure = "client_disconnected"; }
        catch (IOException) { failure = "client_disconnected"; }
        catch (OperationCanceledException) when (absolute.IsCancellationRequested) { failure = stop.IsCancellationRequested ? "server_stopped" : "absolute_timeout"; }
        finally
        {
            if (failure is not null) { session.Cancel(); process.TerminateTree(); }
        }
        if (failure is not null)
        {
            if (failure is "idle_timeout" or "absolute_timeout") await TryWriteAsync(pipe, FrameKind.Error, Encoding.UTF8.GetBytes(failure), writeGate, CancellationToken.None);
            if (failure == "server_stopped") throw new OperationCanceledException(stop);
            if (failure == "client_disconnected") throw new OperationCanceledException("client_disconnected");
            return;
        }
        await Task.WhenAll(IgnoreCancellation(stdout), IgnoreCancellation(stderr));
        session.Cancel();
        var payload = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(payload, exitCode); await TryWriteAsync(pipe, FrameKind.Exit, payload, writeGate, stop);
    }
    static async Task InputAsync(Stream pipe, Stream stdin, Action touch, CancellationToken token)
    { while (true) { var frame = await Frame.ReadAsync(pipe, token); touch(); if (frame.Kind == FrameKind.StdinEnd) { stdin.Close(); return; } if (frame.Kind != FrameKind.Stdin) throw new InvalidDataException("stdin_frame_required"); await stdin.WriteAsync(frame.Payload, token); await stdin.FlushAsync(token); } }
    static async Task PumpAsync(Stream source, Stream pipe, FrameKind kind, SemaphoreSlim gate, Action touch, CancellationToken token)
    { var buffer = new byte[8192]; while (true) { var read = await source.ReadAsync(buffer, token); if (read == 0) return; touch(); await TryWriteAsync(pipe, kind, buffer.AsMemory(0, read), gate, token); } }
    static async Task TryWriteAsync(Stream pipe, FrameKind kind, ReadOnlyMemory<byte> payload, SemaphoreSlim gate, CancellationToken token)
    { await gate.WaitAsync(token); try { await Frame.WriteAsync(pipe, kind, payload, token); } catch (IOException) { } finally { gate.Release(); } }
    static async Task IgnoreCancellation(Task task) { try { await task; } catch (OperationCanceledException) { } }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
