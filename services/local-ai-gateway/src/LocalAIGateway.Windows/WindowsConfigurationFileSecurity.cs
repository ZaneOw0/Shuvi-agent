using System.Security.AccessControl;
using System.Security.Principal;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Windows;

public sealed class WindowsConfigurationFileSecurity : IConfigurationFileSecurity
{
    public void ProtectDirectory(string path)
    {
        EnsureWindows();
        ArgumentException.ThrowIfNullOrWhiteSpace(path);

        var identity = GetCurrentUserSid();
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            identity,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(new DirectoryInfo(path), security);
    }

    public void ProtectFile(string path)
    {
        EnsureWindows();
        ArgumentException.ThrowIfNullOrWhiteSpace(path);

        var identity = GetCurrentUserSid();
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            identity,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(new FileInfo(path), security);
    }

    private static SecurityIdentifier GetCurrentUserSid()
    {
        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        return identity.User ?? throw new ConfigurationException(
            "aigw_config_identity_unavailable",
            "The current Windows user identity is unavailable.");
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows ACLs require Windows.");
        }
    }
}
