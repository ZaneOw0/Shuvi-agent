using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Windows;

namespace LocalAIGateway.Windows.Tests;

public sealed class WindowsCredentialStoreValidationTests
{
    [Fact]
    public async Task RejectsTargetOutsideOwnedNamespaceBeforeNativeCall()
    {
        var store = new WindowsCredentialStore();

        var exception = await Assert.ThrowsAsync<CredentialException>(async () =>
            await store.SetSecretAsync("OtherProduct/key", "secret"));

        Assert.Equal("aigw_credential_target_invalid", exception.ErrorCode);
    }

    [Fact]
    public async Task RejectsEmptySecretBeforeNativeCall()
    {
        var store = new WindowsCredentialStore();

        var exception = await Assert.ThrowsAsync<CredentialException>(async () =>
            await store.SetSecretAsync("LocalAIGateway/test/provider/api-key", string.Empty));

        Assert.Equal("aigw_credential_empty", exception.ErrorCode);
    }

    [Fact]
    public async Task RejectsOversizeSecretBeforeNativeCall()
    {
        var store = new WindowsCredentialStore();

        var exception = await Assert.ThrowsAsync<CredentialException>(async () =>
            await store.SetSecretAsync(
                "LocalAIGateway/test/provider/api-key",
                new string('x', 2561)));

        Assert.Equal("aigw_credential_too_large", exception.ErrorCode);
    }

    [Fact]
    public async Task Enumeration_rejects_any_prefix_outside_the_exact_owned_namespace()
    {
        var store = new WindowsCredentialStore();

        var exception = await Assert.ThrowsAsync<CredentialException>(async () =>
            await store.ListTargetsAsync("LocalAIGateway/test/"));

        Assert.Equal("aigw_credential_prefix_invalid", exception.ErrorCode);
    }

    [Fact]
    public void Enumeration_filter_keeps_only_generic_exact_prefix_targets_in_stable_order()
    {
        var targets = WindowsCredentialStore.FilterOwnedTargets(
        [
            (1u, "LocalAIGateway/z/provider/api-key"),
            (2u, "LocalAIGateway/a/provider/api-key"),
            (1u, "OtherProduct/a"),
            (1u, "LocalAIGateway/a/provider/api-key"),
            (1u, "LocalAIGateway/a/provider/api-key"),
            (1u, null),
        ], "LocalAIGateway/");

        Assert.Equal(
        [
            "LocalAIGateway/a/provider/api-key",
            "LocalAIGateway/z/provider/api-key",
        ], targets);
    }
}
