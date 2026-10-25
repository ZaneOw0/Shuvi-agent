using System.Text;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Tests;

public sealed class ConfigurationStoreTests : IDisposable
{
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CoreTests-{Guid.NewGuid():N}");

    [Fact]
    public async Task Missing_configuration_loads_as_revision_zero()
    {
        var loaded = await CreateStore().LoadAsync();

        Assert.Equal(GatewayConfiguration.Empty, loaded);
    }

    [Fact]
    public async Task Existing_but_unreadable_configuration_is_not_treated_as_missing()
    {
        var store = CreateStore();
        Directory.CreateDirectory(store.Paths.ConfigurationFile);

        var exception = await Assert.ThrowsAsync<ConfigurationException>(() => store.LoadAsync());

        Assert.Equal("aigw_config_access_denied", exception.ErrorCode);
    }

    [Fact]
    public async Task FirstSaveCreatesRevisionOneAndRoundTrips()
    {
        var store = CreateStore();

        var saved = await store.SaveAsync(TestConfiguration.CreateComplete(), expectedRevision: 0);
        var loaded = await store.LoadAsync();

        Assert.Equal(1, saved.Revision);
        Assert.Equal(saved.Revision, loaded.Revision);
        Assert.Equal(saved.ActiveProfileId, loaded.ActiveProfileId);
        Assert.Equal(saved.Profiles[0].Id, loaded.Profiles[0].Id);
        Assert.Equal(saved.Profiles[0].Limits, loaded.Profiles[0].Limits);
        Assert.Equal(saved.Profiles[0].Providers[0], loaded.Profiles[0].Providers[0]);
        Assert.Equal(saved.Profiles[0].Models[0].Alias, loaded.Profiles[0].Models[0].Alias);
        Assert.Equal(saved.Profiles[0].Models[0].ProviderId, loaded.Profiles[0].Models[0].ProviderId);
        Assert.Equal(saved.Profiles[0].Models[0].UpstreamModel, loaded.Profiles[0].Models[0].UpstreamModel);
        Assert.Equal(saved.Profiles[0].Models[0].IsDefault, loaded.Profiles[0].Models[0].IsDefault);
        Assert.Equal(saved.Profiles[0].Models[0].RoutingStrategy, loaded.Profiles[0].Models[0].RoutingStrategy);
        Assert.Equal(saved.Profiles[0].Models[0].Weight, loaded.Profiles[0].Models[0].Weight);
        Assert.Equal(saved.Profiles[0].Models[0].Limits, loaded.Profiles[0].Models[0].Limits);
        Assert.Equal(saved.Profiles[0].Models[0].Fallbacks, loaded.Profiles[0].Models[0].Fallbacks);
        Assert.True(File.Exists(store.Paths.ConfigurationFile));
    }

    [Fact]
    public async Task SecondSaveCreatesBackupOfPreviousRevision()
    {
        var store = CreateStore();
        var first = await store.SaveAsync(TestConfiguration.CreateComplete(), expectedRevision: 0);

        var second = await store.SaveAsync(
            first with { ActiveProfileId = first.ActiveProfileId },
            expectedRevision: first.Revision);

        Assert.Equal(2, second.Revision);
        Assert.True(File.Exists(store.Paths.BackupFile));
        var backup = ConfigurationJson.Deserialize(await File.ReadAllBytesAsync(store.Paths.BackupFile));
        Assert.Equal(1, backup.Revision);
    }

    [Fact]
    public async Task AccessDeniedReplaceFallsBackToAtomicMovesAndPreservesPreviousRevision()
    {
        var replaceAttempts = 0;
        var store = new ConfigurationStore(
            new ConfigurationPaths(temporaryDirectory),
            NoOpConfigurationFileSecurity.Instance,
            (_, _, _) =>
            {
                replaceAttempts++;
                throw new UnauthorizedAccessException("Injected ReplaceFileW denial.");
            },
            TimeSpan.FromMilliseconds(250));
        var first = await store.SaveAsync(TestConfiguration.CreateComplete(), expectedRevision: 0);

        var second = await store.SaveAsync(
            first with { ActiveProfileId = first.ActiveProfileId },
            expectedRevision: first.Revision);

        Assert.Equal(1, replaceAttempts);
        Assert.Equal(2, second.Revision);
        Assert.Equal(2, (await store.LoadAsync()).Revision);
        var backup = ConfigurationJson.Deserialize(await File.ReadAllBytesAsync(store.Paths.BackupFile));
        Assert.Equal(1, backup.Revision);
        Assert.Empty(Directory.GetFiles(temporaryDirectory, "*.tmp"));
    }

    [Fact]
    public async Task StaleRevisionFailsWithoutChangingFile()
    {
        var store = CreateStore();
        var first = await store.SaveAsync(TestConfiguration.CreateComplete(), expectedRevision: 0);
        var before = await File.ReadAllBytesAsync(store.Paths.ConfigurationFile);

        var exception = await Assert.ThrowsAsync<ConfigurationConcurrencyException>(() =>
            store.SaveAsync(first, expectedRevision: 0));

        Assert.Equal("aigw_config_concurrent_update", exception.ErrorCode);
        Assert.Equal(before, await File.ReadAllBytesAsync(store.Paths.ConfigurationFile));
    }

    [Fact]
    public async Task CorruptJsonFailsExplicitly()
    {
        var store = CreateStore();
        Directory.CreateDirectory(temporaryDirectory);
        await File.WriteAllTextAsync(store.Paths.ConfigurationFile, "{broken", Encoding.UTF8);

        var exception = await Assert.ThrowsAsync<ConfigurationException>(() => store.LoadAsync());

        Assert.Equal("aigw_config_corrupt", exception.ErrorCode);
    }

    [Fact]
    public async Task FutureSchemaFailsExplicitly()
    {
        var store = CreateStore();
        Directory.CreateDirectory(temporaryDirectory);
        await File.WriteAllTextAsync(
            store.Paths.ConfigurationFile,
            """
            {
              "schemaVersion": 999,
              "revision": 1,
              "activeProfileId": null,
              "profiles": []
            }
            """,
            Encoding.UTF8);

        var exception = await Assert.ThrowsAsync<ConfigurationValidationException>(() => store.LoadAsync());

        Assert.Equal("aigw_config_future_schema", exception.ErrorCode);
    }

    [Fact]
    public async Task InvalidCandidateDoesNotCreateConfigurationFile()
    {
        var store = CreateStore();
        var invalid = TestConfiguration.CreateComplete() with
        {
            Profiles = [TestConfiguration.CreateComplete().Profiles[0] with { Models = [] }],
        };

        await Assert.ThrowsAsync<ConfigurationValidationException>(() =>
            store.SaveAsync(invalid with { ActiveProfileId = "default" }, expectedRevision: 0));

        Assert.False(File.Exists(store.Paths.ConfigurationFile));
    }

    [Fact]
    public async Task HeldCrossProcessLockTimesOutWithoutWritingConfiguration()
    {
        Directory.CreateDirectory(temporaryDirectory);
        var store = new ConfigurationStore(
            new ConfigurationPaths(temporaryDirectory),
            NoOpConfigurationFileSecurity.Instance,
            TimeSpan.FromMilliseconds(100));
        await using var heldLock = new FileStream(
            store.Paths.LockFile,
            FileMode.OpenOrCreate,
            FileAccess.ReadWrite,
            FileShare.None);

        var exception = await Assert.ThrowsAsync<ConfigurationException>(() =>
            store.SaveAsync(TestConfiguration.CreateComplete(), expectedRevision: 0));

        Assert.Equal("aigw_config_lock_timeout", exception.ErrorCode);
        Assert.False(File.Exists(store.Paths.ConfigurationFile));
    }

    public void Dispose()
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private ConfigurationStore CreateStore() => new(
        new ConfigurationPaths(temporaryDirectory),
        NoOpConfigurationFileSecurity.Instance,
        TimeSpan.FromMilliseconds(250));
}
