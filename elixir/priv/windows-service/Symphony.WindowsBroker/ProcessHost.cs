using System.Collections;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Symphony.WindowsBroker;

public interface IBrokerProcess : IAsyncDisposable
{
    Stream StandardInput { get; }
    Stream StandardOutput { get; }
    Stream StandardError { get; }
    Task<int> WaitForExitAsync(CancellationToken token);
    void TerminateTree();
}

public interface IBrokerProcessFactory { IBrokerProcess Start(BrokerRequest request, BrokerOptions options); }

public sealed class CodexProcessFactory : IBrokerProcessFactory
{
    public IBrokerProcess Start(BrokerRequest request, BrokerOptions options)
    {
        var host = Environment.GetEnvironmentVariables()
            .Cast<DictionaryEntry>()
            .ToDictionary(e => (string)e.Key, e => (string)e.Value!, StringComparer.OrdinalIgnoreCase);
        var environment = BrokerPolicy.WorkerEnvironment(request, host);
        var arguments = BrokerPolicy.CodexArguments(request);
        return SuspendedBrokerProcess.Start(options.CodexExecutable, arguments, request.Workspace, environment);
    }
}

sealed class SuspendedBrokerProcess : IBrokerProcess
{
    const int StartfUseStdHandles = 0x00000100;
    const uint CreateSuspended = 0x00000004;
    const uint CreateNoWindow = 0x08000000;
    const uint CreateUnicodeEnvironment = 0x00000400;
    const uint HandleFlagInherit = 0x00000001;
    readonly Process process;
    readonly KillOnCloseJob job;
    readonly SafeFileHandle processHandle;
    readonly FileStream standardInput;
    readonly FileStream standardOutput;
    readonly FileStream standardError;

    SuspendedBrokerProcess(Process process, SafeFileHandle processHandle, KillOnCloseJob job, FileStream standardInput, FileStream standardOutput, FileStream standardError)
    {
        this.process = process;
        this.processHandle = processHandle;
        this.job = job;
        this.standardInput = standardInput;
        this.standardOutput = standardOutput;
        this.standardError = standardError;
    }

    public Stream StandardInput => standardInput;
    public Stream StandardOutput => standardOutput;
    public Stream StandardError => standardError;

    public static SuspendedBrokerProcess Start(string executable, IReadOnlyList<string> arguments, string workingDirectory, IReadOnlyDictionary<string, string> environment)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("windows_broker_requires_windows");
        var stdinRead = InvalidHandle();
        var stdinWrite = InvalidHandle();
        var stdoutRead = InvalidHandle();
        var stdoutWrite = InvalidHandle();
        var stderrRead = InvalidHandle();
        var stderrWrite = InvalidHandle();
        var threadHandle = InvalidHandle();
        var processHandle = InvalidHandle();
        var environmentBlock = IntPtr.Zero;
        var job = new KillOnCloseJob();
        var processStarted = false;

        try
        {
            var security = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), InheritHandle = true };
            CreatePipe(out stdinRead, out stdinWrite, ref security, 0);
            CreatePipe(out stdoutRead, out stdoutWrite, ref security, 0);
            CreatePipe(out stderrRead, out stderrWrite, ref security, 0);
            DisableInheritance(stdinWrite);
            DisableInheritance(stdoutRead);
            DisableInheritance(stderrRead);

            environmentBlock = BuildEnvironmentBlock(environment);
            var startup = new StartupInfo
            {
                cb = Marshal.SizeOf<StartupInfo>(),
                dwFlags = StartfUseStdHandles,
                hStdInput = stdinRead.DangerousGetHandle(),
                hStdOutput = stdoutWrite.DangerousGetHandle(),
                hStdError = stderrWrite.DangerousGetHandle()
            };

            var commandLine = new StringBuilder(BuildCommandLine(executable, arguments));
            if (!CreateProcessW(null, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                    CreateSuspended | CreateNoWindow | CreateUnicodeEnvironment, environmentBlock, workingDirectory,
                    ref startup, out var processInformation))
                throw new Win32Exception();

            processHandle = processInformation.hProcess;
            threadHandle = processInformation.hThread;
            processStarted = true;

            job.Add(processHandle);
            if (ResumeThread(threadHandle) == unchecked((uint)-1)) throw new Win32Exception();

            stdinRead.Dispose(); stdoutWrite.Dispose(); stderrWrite.Dispose();
            stdinRead = InvalidHandle(); stdoutWrite = InvalidHandle(); stderrWrite = InvalidHandle();

            var process = Process.GetProcessById(processInformation.dwProcessId);
            return new SuspendedBrokerProcess(
                process,
                processHandle,
                job,
                new FileStream(stdinWrite, FileAccess.Write, 4096, true),
                new FileStream(stdoutRead, FileAccess.Read, 4096, true),
                new FileStream(stderrRead, FileAccess.Read, 4096, true));
        }
        catch
        {
            if (processStarted && !processHandle.IsInvalid) TerminateProcess(processHandle, 1);
            job.Dispose();
            processHandle.Dispose();
            stdinRead.Dispose(); stdinWrite.Dispose(); stdoutRead.Dispose(); stdoutWrite.Dispose(); stderrRead.Dispose(); stderrWrite.Dispose();
            throw;
        }
        finally
        {
            threadHandle.Dispose();
            if (environmentBlock != IntPtr.Zero) Marshal.FreeHGlobal(environmentBlock);
        }
    }

    public async Task<int> WaitForExitAsync(CancellationToken token)
    {
        await process.WaitForExitAsync(token);
        return process.ExitCode;
    }

    public void TerminateTree()
    {
        try
        {
            if (!process.HasExited) process.Kill(true);
        }
        catch (InvalidOperationException) { }
        finally { job.Dispose(); }
    }

    public ValueTask DisposeAsync()
    {
        standardInput.Dispose(); standardOutput.Dispose(); standardError.Dispose(); process.Dispose(); processHandle.Dispose(); job.Dispose();
        return ValueTask.CompletedTask;
    }

    static SafeFileHandle InvalidHandle() => new(IntPtr.Zero, false);

    static void CreatePipe(out SafeFileHandle readPipe, out SafeFileHandle writePipe, ref SecurityAttributes security, uint size)
    {
        if (!CreatePipeNative(out readPipe, out writePipe, ref security, size)) throw new Win32Exception();
    }

    static void DisableInheritance(SafeFileHandle handle)
    {
        if (!SetHandleInformation(handle, HandleFlagInherit, 0)) throw new Win32Exception();
    }

    static IntPtr BuildEnvironmentBlock(IReadOnlyDictionary<string, string> environment)
    {
        var builder = new StringBuilder();
        foreach (var pair in environment.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (pair.Key.Contains('=')) throw new InvalidDataException("invalid_environment_key");
            builder.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
        }
        builder.Append('\0');
        var text = builder.ToString();
        var bytes = Encoding.Unicode.GetBytes(text);
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }

    static string BuildCommandLine(string executable, IReadOnlyList<string> arguments) =>
        string.Join(" ", new[] { executable }.Concat(arguments).Select(QuoteArgument));

    static string QuoteArgument(string argument)
    {
        if (argument.Length == 0) return "\"\"";
        if (!argument.Any(ch => char.IsWhiteSpace(ch) || ch is '\"' or '\\')) return argument;
        var builder = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var ch in argument)
        {
            if (ch == '\\') { backslashes++; continue; }
            if (ch == '\"') { builder.Append('\\', backslashes * 2 + 1).Append(ch); backslashes = 0; continue; }
            builder.Append('\\', backslashes).Append(ch); backslashes = 0;
        }
        builder.Append('\\', backslashes * 2).Append('"');
        return builder.ToString();
    }

    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Length; public IntPtr SecurityDescriptor; [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo { public int cb; public string? lpReserved; public string? lpDesktop; public string? lpTitle; public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInformation { public SafeFileHandle hProcess; public SafeFileHandle hThread; public int dwProcessId; public int dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "CreatePipe")] static extern bool CreatePipeNative(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, ref SecurityAttributes lpPipeAttributes, uint nSize);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(SafeFileHandle hObject, uint dwMask, uint dwFlags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessW(string? lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref StartupInfo lpStartupInfo, out ProcessInformation lpProcessInformation);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(SafeFileHandle hThread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(SafeFileHandle hProcess, uint uExitCode);
}
