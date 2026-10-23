using LocalAIGateway.Core.Runtime;

namespace LocalAIGateway.Tray;

public sealed class TrayApplicationLifetime : IDisposable
{
    private readonly ISingleInstanceLease lease;
    private readonly CancellationTokenSource shutdown = new();
    private int disposed;

    private TrayApplicationLifetime(ISingleInstanceLease lease)
    {
        this.lease = lease;
        ShutdownToken = shutdown.Token;
    }

    public CancellationToken ShutdownToken { get; }

    public static TrayApplicationLifetime? TryCreate(ISingleInstanceProvider provider)
    {
        ArgumentNullException.ThrowIfNull(provider);
        var lease = provider.TryAcquire();
        return lease is null ? null : new TrayApplicationLifetime(lease);
    }

    public void RequestShutdown()
    {
        if (Volatile.Read(ref disposed) == 0)
        {
            shutdown.Cancel();
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        shutdown.Cancel();
        shutdown.Dispose();
        lease.Dispose();
    }
}
