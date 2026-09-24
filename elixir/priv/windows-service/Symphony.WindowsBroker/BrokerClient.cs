using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
namespace Symphony.WindowsBroker;
public static class BrokerClient
{
    public static readonly TimeSpan DefaultConnectTimeout = TimeSpan.FromSeconds(3);

    public static async Task<int> RunAsync(string pipeName, BrokerRequest request, Stream input, Stream output, Stream error, CancellationToken token, TimeSpan? connectTimeout = null)
    {
        await using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.WriteThrough, TokenImpersonationLevel.Impersonation);
        using var connect = CancellationTokenSource.CreateLinkedTokenSource(token);
        connect.CancelAfter(connectTimeout ?? DefaultConnectTimeout);
        try { await pipe.ConnectAsync(connect.Token); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested && connect.IsCancellationRequested)
        {
            throw new TimeoutException("broker_connect_timeout");
        }
        await Frame.WriteJsonAsync(pipe, FrameKind.Request, request, token);
        using var session = CancellationTokenSource.CreateLinkedTokenSource(token);
        var writeGate = new SemaphoreSlim(1, 1);
        var sending = SendInputAsync(input, pipe, writeGate, session.Token);
        try
        {
            while (true)
            {
                var frame = await Frame.ReadAsync(pipe, token);
                switch (frame.Kind)
                {
                    case FrameKind.Stdout: await output.WriteAsync(frame.Payload, token); await output.FlushAsync(token); break;
                    case FrameKind.Stderr: await error.WriteAsync(frame.Payload, token); await error.FlushAsync(token); break;
                    case FrameKind.Exit:
                        if (frame.Payload.Length != 4) throw new InvalidDataException("exit_frame_invalid");
                        return BinaryPrimitives.ReadInt32BigEndian(frame.Payload);
                    case FrameKind.Error: throw new InvalidOperationException(Encoding.UTF8.GetString(frame.Payload));
                    default: throw new InvalidDataException("server_frame_invalid");
                }
            }
        }
        finally
        {
            session.Cancel();
            if (sending.IsCompleted)
            {
                try { await sending; } catch (Exception sendError) when (sendError is IOException or OperationCanceledException) { }
            }
            else
            {
                _ = sending.ContinueWith(completed => _ = completed.Exception, CancellationToken.None,
                    TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            }
        }
    }
    static async Task SendInputAsync(Stream input, Stream pipe, SemaphoreSlim gate, CancellationToken token)
    {
        var buffer = new byte[8192];
        while (true)
        {
            var read = await input.ReadAsync(buffer, token);
            await gate.WaitAsync(token);
            try { await Frame.WriteAsync(pipe, read == 0 ? FrameKind.StdinEnd : FrameKind.Stdin, buffer.AsMemory(0, read), token); }
            finally { gate.Release(); }
            if (read == 0) return;
        }
    }
}
