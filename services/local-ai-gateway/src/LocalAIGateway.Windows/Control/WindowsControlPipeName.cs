using System.Security.Principal;
using LocalAIGateway.Core.Control;

namespace LocalAIGateway.Windows.Control;

public static class WindowsControlPipeName
{
    public static string ForCurrentUser()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User?.Value;
        if (string.IsNullOrWhiteSpace(sid))
        {
            throw new ControlProtocolException(
                "aigw_control_identity_unavailable",
                "The current Windows user SID is unavailable.");
        }

        return $"LocalAIGateway.Control.v{ControlProtocol.Version}.{sid}";
    }
}
