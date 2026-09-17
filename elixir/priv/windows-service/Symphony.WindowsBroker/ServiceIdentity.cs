using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace Symphony.WindowsBroker;

public sealed record ServiceIdentitySnapshot(
    SecurityIdentifier UserSid,
    bool Elevated,
    bool AdministratorsEnabled,
    bool AdministratorsDenyOnly);

public static class ServiceIdentity
{
    const uint SeGroupEnabled = 0x00000004;
    const uint SeGroupUseForDenyOnly = 0x00000010;
    static readonly SecurityIdentifier SystemSid = new(WellKnownSidType.LocalSystemSid, null);
    static readonly SecurityIdentifier AdministratorsSid = new(WellKnownSidType.BuiltinAdministratorsSid, null);

    public static void Demand(string serviceName)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("windows_broker_requires_windows");
        var expected = (SecurityIdentifier)new NTAccount("NT SERVICE", serviceName).Translate(typeof(SecurityIdentifier));
        Demand(expected, Capture());
    }

    public static void Demand(SecurityIdentifier expected, ServiceIdentitySnapshot snapshot)
    {
        if (snapshot.UserSid.Equals(SystemSid)) throw new InvalidOperationException("service_identity_system");
        if (!snapshot.UserSid.Equals(expected)) throw new InvalidOperationException("service_identity_mismatch");
        if (snapshot.Elevated) throw new InvalidOperationException("service_identity_elevated");
        if (snapshot.AdministratorsEnabled) throw new InvalidOperationException("service_identity_admin");
        if (snapshot.AdministratorsDenyOnly) throw new InvalidOperationException("service_identity_admin_deny_only");
    }

    public static ServiceIdentitySnapshot Capture()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("windows_broker_requires_windows");
        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        var userSid = identity.User ?? throw new InvalidOperationException("service_identity_user_missing");
        var elevated = ReadElevation(identity.AccessToken);
        var (administratorsEnabled, administratorsDenyOnly) = ReadAdministrators(identity.AccessToken);
        return new(userSid, elevated, administratorsEnabled, administratorsDenyOnly);
    }

    static bool ReadElevation(SafeAccessTokenHandle token)
    {
        var size = Marshal.SizeOf<TokenElevation>();
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!GetTokenInformation(token, TokenInformationClass.TokenElevation, buffer, size, out _)) throw new Win32Exception();
            return Marshal.PtrToStructure<TokenElevation>(buffer).TokenIsElevated != 0;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    static (bool Enabled, bool DenyOnly) ReadAdministrators(SafeAccessTokenHandle token)
    {
        GetTokenInformation(token, TokenInformationClass.TokenGroups, IntPtr.Zero, 0, out var size);
        if (size <= 0) throw new Win32Exception();
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!GetTokenInformation(token, TokenInformationClass.TokenGroups, buffer, size, out _)) throw new Win32Exception();
            var count = Marshal.ReadInt32(buffer);
            var offset = IntPtr.Size == 8 ? 8 : 4;
            var stride = Marshal.SizeOf<SidAndAttributes>();
            for (var index = 0; index < count; index++)
            {
                var entry = Marshal.PtrToStructure<SidAndAttributes>(IntPtr.Add(buffer, offset + index * stride));
                var sid = new SecurityIdentifier(entry.Sid);
                if (!sid.Equals(AdministratorsSid)) continue;
                return ((entry.Attributes & SeGroupEnabled) != 0, (entry.Attributes & SeGroupUseForDenyOnly) != 0);
            }
            return (false, false);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    enum TokenInformationClass { TokenGroups = 2, TokenElevation = 20 }
    [StructLayout(LayoutKind.Sequential)] struct TokenElevation { public uint TokenIsElevated; }
    [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(
        SafeAccessTokenHandle token,
        TokenInformationClass informationClass,
        IntPtr information,
        int informationLength,
        out int returnLength);
}
