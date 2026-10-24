using LocalAIGateway.Core.Runtime;
using LocalAIGateway.Tray;

namespace LocalAIGateway.Tray.Tests;

public sealed class TrayApplicationLifetimeTests
{
    [Fact]
    public void TryCreate_rejects_a_second_instance_without_creating_a_lifetime()
    {
        var provider = new TestProvider { Lease = null };

        var lifetime = TrayApplicationLifetime.TryCreate(provider);

        Assert.Null(lifetime);
        Assert.Equal(1, provider.AcquireCount);
    }

    [Fact]
    public void Dispose_cancels_shutdown_and_releases_the_single_instance_lease_once()
    {
        var lease = new TestLease();
        var provider = new TestProvider { Lease = lease };
        var lifetime = Assert.IsType<TrayApplicationLifetime>(
            TrayApplicationLifetime.TryCreate(provider));

        lifetime.Dispose();
        lifetime.Dispose();

        Assert.True(lifetime.ShutdownToken.IsCancellationRequested);
        Assert.Equal(1, lease.DisposeCount);
    }

    [Fact]
    public void RequestShutdown_cancels_work_but_retains_the_lease_until_disposal()
    {
        var lease = new TestLease();
        using var lifetime = Assert.IsType<TrayApplicationLifetime>(
            TrayApplicationLifetime.TryCreate(new TestProvider { Lease = lease }));

        lifetime.RequestShutdown();

        Assert.True(lifetime.ShutdownToken.IsCancellationRequested);
        Assert.Equal(0, lease.DisposeCount);
    }

    private sealed class TestProvider : ISingleInstanceProvider
    {
        public ISingleInstanceLease? Lease { get; init; }

        public int AcquireCount { get; private set; }

        public ISingleInstanceLease? TryAcquire()
        {
            AcquireCount++;
            return Lease;
        }
    }

    private sealed class TestLease : ISingleInstanceLease
    {
        public int DisposeCount { get; private set; }

        public void Dispose() => DisposeCount++;
    }
}
