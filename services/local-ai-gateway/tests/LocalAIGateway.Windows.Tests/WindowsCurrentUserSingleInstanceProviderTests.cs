using LocalAIGateway.Windows;

namespace LocalAIGateway.Windows.Tests;

public sealed class WindowsCurrentUserSingleInstanceProviderTests
{
    [Fact]
    public void Same_current_user_scope_conflicts_until_the_original_lease_is_released()
    {
        var provider = new WindowsCurrentUserSingleInstanceProvider($"test-{Guid.NewGuid():N}");
        var first = provider.TryAcquire();

        Assert.NotNull(first);
        Assert.Null(provider.TryAcquire());

        first.Dispose();
        first.Dispose();

        using var replacement = provider.TryAcquire();
        Assert.NotNull(replacement);
    }
}
