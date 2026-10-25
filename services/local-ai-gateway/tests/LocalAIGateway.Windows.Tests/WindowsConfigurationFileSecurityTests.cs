using System.Security.AccessControl;
using System.Security.Principal;
using LocalAIGateway.Windows;

namespace LocalAIGateway.Windows.Tests;

public sealed class WindowsConfigurationFileSecurityTests : IDisposable
{
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-WindowsTests-{Guid.NewGuid():N}");

    [Fact]
    public void DirectoryAndFileAreRestrictedToCurrentUser()
    {
        Directory.CreateDirectory(temporaryDirectory);
        var file = Path.Combine(temporaryDirectory, "config.json");
        File.WriteAllText(file, "{}");
        var security = new WindowsConfigurationFileSecurity();

        security.ProtectDirectory(temporaryDirectory);
        security.ProtectFile(file);

        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        var currentSid = identity.User ?? throw new InvalidOperationException("Current SID unavailable.");
        var directorySecurity = FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(temporaryDirectory));
        var fileSecurity = FileSystemAclExtensions.GetAccessControl(new FileInfo(file));
        Assert.True(directorySecurity.AreAccessRulesProtected);
        Assert.True(fileSecurity.AreAccessRulesProtected);
        AssertCurrentUserFullControl(directorySecurity, currentSid);
        AssertCurrentUserFullControl(fileSecurity, currentSid);
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private static void AssertCurrentUserFullControl(
        FileSystemSecurity security,
        SecurityIdentifier currentSid)
    {
        var rules = security.GetAccessRules(
            includeExplicit: true,
            includeInherited: false,
            typeof(SecurityIdentifier));
        var matchingRules = rules
            .Cast<FileSystemAccessRule>()
            .Where(rule => currentSid.Equals(rule.IdentityReference) &&
                rule.AccessControlType == AccessControlType.Allow)
            .ToArray();

        Assert.Single(matchingRules);
        Assert.Equal(FileSystemRights.FullControl, matchingRules[0].FileSystemRights);
    }
}
