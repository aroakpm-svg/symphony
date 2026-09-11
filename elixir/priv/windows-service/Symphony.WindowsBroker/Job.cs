using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Symphony.WindowsBroker;
sealed class KillOnCloseJob : IDisposable
{
    const int Extended = 9; const uint KillOnClose = 0x2000; readonly SafeFileHandle handle;
    public KillOnCloseJob() { handle = CreateJobObject(IntPtr.Zero, null); if (handle.IsInvalid) throw new Win32Exception(); var info = new ExtendedInfo { Basic = new BasicInfo { LimitFlags = KillOnClose } }; var size = Marshal.SizeOf<ExtendedInfo>(); var pointer = Marshal.AllocHGlobal(size); try { Marshal.StructureToPtr(info, pointer, false); if (!SetInformationJobObject(handle, Extended, pointer, (uint)size)) throw new Win32Exception(); } finally { Marshal.FreeHGlobal(pointer); } }
    public void Add(System.Diagnostics.Process process) { if (!AssignProcessToJobObject(handle, process.Handle)) throw new Win32Exception(); }
    public void Dispose() => handle.Dispose();
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a,b,c,d,e,f; }
    [StructLayout(LayoutKind.Sequential)] struct BasicInfo { public long a,b; public uint LimitFlags; public UIntPtr c,d; public uint e; public UIntPtr f; public uint g,h; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedInfo { public BasicInfo Basic; public IoCounters Io; public UIntPtr a,b,c,d; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern SafeFileHandle CreateJobObject(IntPtr attributes,string? name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(SafeFileHandle job,int kind,IntPtr info,uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(SafeFileHandle job,IntPtr process);
}
