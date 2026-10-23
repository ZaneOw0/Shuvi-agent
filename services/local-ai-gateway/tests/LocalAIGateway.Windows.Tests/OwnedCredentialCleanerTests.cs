using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Windows.Uninstall;

namespace LocalAIGateway.Windows.Tests;

public sealed class OwnedCredentialCleanerTests
{
    [Fact]
    public async Task Selected_runtime_and_provider_credentials_are_deleted_without_reading_secrets()
    {
        var store = new MemoryCredentialStore(
        [
            CredentialTargets.RuntimeClientToken,
            "LocalAIGateway/work/openai/api-key",
            "LocalAIGateway/orphan/azure/api-key",
            "LocalAIGateway/unrecognized",
        ]);

        var result = await new OwnedCredentialCleaner(store, store).CleanAsync(new(true, true));

        Assert.True(result.RuntimeDeleted);
        Assert.Equal(2, result.DeletedProviderTargets.Count);
        Assert.Equal(["LocalAIGateway/unrecognized"], result.PreservedTargets);
        Assert.Equal(["LocalAIGateway/unrecognized"], store.Targets);
        Assert.Equal(0, store.SecretReads);
    }

    [Fact]
    public async Task Unselected_categories_are_preserved_and_reported()
    {
        var provider = "LocalAIGateway/work/openai/api-key";
        var store = new MemoryCredentialStore([CredentialTargets.RuntimeClientToken, provider]);

        var result = await new OwnedCredentialCleaner(store, store).CleanAsync(new(false, true));

        Assert.False(result.RuntimeSelected);
        Assert.False(result.RuntimeDeleted);
        Assert.Equal([CredentialTargets.RuntimeClientToken], result.PreservedTargets);
        Assert.Equal([CredentialTargets.RuntimeClientToken], store.Targets);
    }

    [Fact]
    public async Task Cancellation_before_mutation_preserves_every_credential()
    {
        var store = new MemoryCredentialStore(
            [CredentialTargets.RuntimeClientToken, "LocalAIGateway/work/openai/api-key"]);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new OwnedCredentialCleaner(store, store).CleanAsync(new(true, true), cancellation.Token));

        Assert.Equal(2, store.Targets.Count);
        Assert.Empty(store.DeletedTargets);
    }

    [Fact]
    public async Task Deletion_failure_is_redacted_and_stable()
    {
        var store = new MemoryCredentialStore([CredentialTargets.RuntimeClientToken])
        {
            DeleteFailure = new CredentialException("fixture", "secret-bearing fixture"),
        };

        var failure = await Assert.ThrowsAsync<InstallationException>(() =>
            new OwnedCredentialCleaner(store, store).CleanAsync(new(true, false)));

        Assert.Equal("aigw_uninstall_credential_failed", failure.ErrorCode);
        Assert.DoesNotContain("secret-bearing", failure.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("LocalAIGateway/p/q/api-key", true)]
    [InlineData("LocalAIGateway/runtime/client-token", false)]
    [InlineData("LocalAIGateway/p/q/API-KEY", false)]
    [InlineData("LocalAIGateway/p/q/extra/api-key", false)]
    [InlineData("OtherProduct/p/q/api-key", false)]
    public void Provider_target_classification_is_exact(string target, bool expected)
    {
        Assert.Equal(expected, OwnedCredentialCleaner.IsProviderTarget(target));
    }

    private sealed class MemoryCredentialStore(IEnumerable<string> targets)
        : ICredentialStore, ICredentialTargetCatalog
    {
        public List<string> Targets { get; } = targets.OrderBy(value => value, StringComparer.Ordinal).ToList();
        public List<string> DeletedTargets { get; } = [];
        public int SecretReads { get; private set; }
        public Exception? DeleteFailure { get; init; }

        public ValueTask<IReadOnlyList<string>> ListTargetsAsync(
            string ownedPrefix,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult<IReadOnlyList<string>>(Targets.ToArray());
        }

        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default)
        {
            SecretReads++;
            return ValueTask.FromResult<string?>(null);
        }

        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default)
        {
            if (DeleteFailure is not null)
            {
                return ValueTask.FromException(DeleteFailure);
            }
            Targets.Remove(target);
            DeletedTargets.Add(target);
            return ValueTask.CompletedTask;
        }
    }
}
