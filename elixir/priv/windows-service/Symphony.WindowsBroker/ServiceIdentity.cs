using System.Security.Principal;

namespace Symphony.WindowsBroker;

public static class ServiceIdentity
{
    static readonly SecurityIdentifier SystemSid = new(WellKnownSidType.LocalSystemSid, null);

    public static void Demand(string serviceName)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("windows_broker_requires_windows");
        var expected = (SecurityIdentifier)new NTAccount("NT SERVICE", serviceName).Translate(typeof(SecurityIdentifier));
        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        Demand(expected, identity.User ?? throw new InvalidOperationException("service_identity_user_missing"));
    }

    public static void Demand(SecurityIdentifier expected, SecurityIdentifier actual)
    {
        if (actual.Equals(SystemSid)) throw new InvalidOperationException("service_identity_system");
        if (!actual.Equals(expected)) throw new InvalidOperationException("service_identity_mismatch");
    }
}
