using System.Security.AccessControl;
using System.Security.Principal;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Windows;

namespace LocalAIGateway.Windows.Tests;

public sealed class ConfigurationStoreWindowsSecurityTests : IDisposable
{
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-WindowsStoreTests-{Guid.NewGuid():N}");

    [Fact]
    public async Task StoreProtectsConfigurationLockAndBackupWithCurrentUserAcl()
    {
        var store = new ConfigurationStore(
            new ConfigurationPaths(temporaryDirectory),
            new WindowsConfigurationFileSecurity());
        var first = await store.SaveAsync(CreateCompleteConfiguration(), expectedRevision: 0);

        await store.SaveAsync(first, expectedRevision: first.Revision);

        AssertCurrentUserOnly(store.Paths.RootDirectory);
        AssertCurrentUserOnly(store.Paths.ConfigurationFile);
        AssertCurrentUserOnly(store.Paths.LockFile);
        AssertCurrentUserOnly(store.Paths.BackupFile);
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private static GatewayConfiguration CreateCompleteConfiguration()
    {
        const string profileId = "default";
        const string providerId = "primary";
        return new GatewayConfiguration
        {
            ActiveProfileId = profileId,
            Profiles =
            [
                new ProfileConfiguration
                {
                    Id = profileId,
                    Name = "Default",
                    Providers =
                    [
                        new ProviderConfiguration
                        {
                            Id = providerId,
                            Name = "Primary",
                            Type = ProviderType.OpenAiCompatible,
                            Endpoint = "https://api.example.com/v1",
                            CredentialTarget = CredentialTargets.UpstreamApiKey(profileId, providerId),
                        },
                    ],
                    Models =
                    [
                        new ModelConfiguration
                        {
                            Alias = "aigw/default",
                            ProviderId = providerId,
                            UpstreamModel = "upstream-model",
                            IsDefault = true,
                        },
                    ],
                },
            ],
        };
    }

    private static void AssertCurrentUserOnly(string path)
    {
        FileSystemSecurity security = Directory.Exists(path)
            ? FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(path))
            : FileSystemAclExtensions.GetAccessControl(new FileInfo(path));
        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        var currentSid = identity.User ?? throw new InvalidOperationException("Current SID unavailable.");
        var rules = security.GetAccessRules(
                includeExplicit: true,
                includeInherited: false,
                typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .ToArray();

        Assert.True(security.AreAccessRulesProtected);
        Assert.Single(rules);
        Assert.Equal(currentSid, rules[0].IdentityReference);
        Assert.Equal(AccessControlType.Allow, rules[0].AccessControlType);
        Assert.Equal(FileSystemRights.FullControl, rules[0].FileSystemRights);
    }
}
