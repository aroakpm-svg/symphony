using System.Collections;
using System.Diagnostics;
namespace Symphony.WindowsBroker;
public interface IBrokerProcess : IAsyncDisposable { Stream StandardInput { get; } Stream StandardOutput { get; } Stream StandardError { get; } Task<int> WaitForExitAsync(CancellationToken token); void TerminateTree(); }
public interface IBrokerProcessFactory { IBrokerProcess Start(BrokerRequest request, BrokerOptions options); }
public sealed class CodexProcessFactory : IBrokerProcessFactory
{
    public IBrokerProcess Start(BrokerRequest request, BrokerOptions options)
    {
        var start = new ProcessStartInfo(options.CodexExecutable, "app-server") { UseShellExecute=false, RedirectStandardInput=true, RedirectStandardOutput=true, RedirectStandardError=true, WorkingDirectory=request.Workspace, CreateNoWindow=true };
        start.Environment.Clear();
        var host = Environment.GetEnvironmentVariables().Cast<DictionaryEntry>().ToDictionary(e => (string)e.Key, e => (string)e.Value!, StringComparer.OrdinalIgnoreCase);
        foreach (var pair in BrokerPolicy.WorkerEnvironment(request, host)) start.Environment[pair.Key] = pair.Value;
        return new BrokerProcess(Process.Start(start) ?? throw new InvalidOperationException("codex_start_failed"));
    }
}
sealed class BrokerProcess : IBrokerProcess
{
    readonly Process process; readonly KillOnCloseJob job = new();
    public BrokerProcess(Process process) { this.process=process; job.Add(process); }
    public Stream StandardInput => process.StandardInput.BaseStream; public Stream StandardOutput => process.StandardOutput.BaseStream; public Stream StandardError => process.StandardError.BaseStream;
    public async Task<int> WaitForExitAsync(CancellationToken token) { await process.WaitForExitAsync(token); return process.ExitCode; }
    public void TerminateTree() { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } finally { job.Dispose(); } }
    public ValueTask DisposeAsync() { process.Dispose(); job.Dispose(); return ValueTask.CompletedTask; }
}
