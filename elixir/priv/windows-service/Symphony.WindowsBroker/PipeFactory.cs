using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Symphony.WindowsBroker;

public static class PipeFactory
{
    public const int MaxServerInstances = 1;

    public static PipeSecurity BuildSecurity(SecurityIdentifier controller, SecurityIdentifier? server = null)
    {
        var serverSid = server ?? WindowsIdentity.GetCurrent().User ?? new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
        security.AddAccessRule(new PipeAccessRule(controller, PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(serverSid, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return security;
    }

    public static NamedPipeServerStream Create(string name, SecurityIdentifier controller, SecurityIdentifier? server = null) =>
        NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, MaxServerInstances, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.WriteThrough, 0, 0, BuildSecurity(controller, server));

    public static void DemandController(NamedPipeServerStream pipe, SecurityIdentifier expected)
    {
        SecurityIdentifier? actual = null;
        pipe.RunAsClient(() => actual = (SecurityIdentifier)new NTAccount(pipe.GetImpersonationUserName()).Translate(typeof(SecurityIdentifier)));
        if (actual is null || !actual.Equals(expected)) throw new UnauthorizedAccessException("controller_sid_denied");
    }
}
