using LocalAIGateway.Core.Control;

namespace LocalAIGateway.Runtime;

internal sealed class GatewayCircuitBreaker
{
    private readonly object gate = new();
    private readonly int failureThreshold;
    private readonly TimeSpan openDuration;
    private readonly TimeProvider timeProvider;
    private string state = CircuitStates.Closed;
    private int consecutiveFailures;
    private DateTimeOffset? openUntilUtc;
    private bool halfOpenProbeActive;

    public GatewayCircuitBreaker(
        int failureThreshold,
        TimeSpan openDuration,
        TimeProvider timeProvider)
    {
        if (failureThreshold <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(failureThreshold));
        }

        if (openDuration <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(openDuration));
        }

        this.failureThreshold = failureThreshold;
        this.openDuration = openDuration;
        this.timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
    }

    public bool TryAcquire(out GatewayCircuitPermit? permit, out TimeSpan retryAfter)
    {
        lock (gate)
        {
            var now = timeProvider.GetUtcNow();
            if (state == CircuitStates.Open)
            {
                if (openUntilUtc > now)
                {
                    permit = null;
                    retryAfter = openUntilUtc.Value - now;
                    return false;
                }

                state = CircuitStates.HalfOpen;
                openUntilUtc = null;
                halfOpenProbeActive = false;
            }

            if (state == CircuitStates.HalfOpen)
            {
                if (halfOpenProbeActive)
                {
                    permit = null;
                    retryAfter = TimeSpan.FromSeconds(1);
                    return false;
                }

                halfOpenProbeActive = true;
                permit = new GatewayCircuitPermit(this, isHalfOpenProbe: true);
                retryAfter = TimeSpan.Zero;
                return true;
            }

            permit = new GatewayCircuitPermit(this, isHalfOpenProbe: false);
            retryAfter = TimeSpan.Zero;
            return true;
        }
    }

    public bool CanAcquire(out TimeSpan retryAfter)
    {
        lock (gate)
        {
            var now = timeProvider.GetUtcNow();
            PromoteExpiredOpenCircuit(now);
            if (state == CircuitStates.Open)
            {
                retryAfter = openUntilUtc!.Value - now;
                return false;
            }

            if (state == CircuitStates.HalfOpen && halfOpenProbeActive)
            {
                retryAfter = TimeSpan.FromSeconds(1);
                return false;
            }

            retryAfter = TimeSpan.Zero;
            return true;
        }
    }

    public GatewayCircuitSnapshot GetSnapshot()
    {
        lock (gate)
        {
            PromoteExpiredOpenCircuit(timeProvider.GetUtcNow());
            return new GatewayCircuitSnapshot(state, consecutiveFailures, openUntilUtc);
        }
    }

    internal void Complete(bool isHalfOpenProbe, bool transientFailure)
    {
        lock (gate)
        {
            if (isHalfOpenProbe)
            {
                halfOpenProbeActive = false;
                if (transientFailure)
                {
                    Open(timeProvider.GetUtcNow());
                }
                else
                {
                    Close();
                }

                return;
            }

            if (state != CircuitStates.Closed)
            {
                return;
            }

            if (!transientFailure)
            {
                consecutiveFailures = 0;
                return;
            }

            consecutiveFailures++;
            if (consecutiveFailures >= failureThreshold)
            {
                Open(timeProvider.GetUtcNow());
            }
        }
    }

    internal void Abandon(bool isHalfOpenProbe)
    {
        if (!isHalfOpenProbe)
        {
            return;
        }

        lock (gate)
        {
            if (state == CircuitStates.HalfOpen)
            {
                halfOpenProbeActive = false;
            }
        }
    }

    private void PromoteExpiredOpenCircuit(DateTimeOffset now)
    {
        if (state == CircuitStates.Open && openUntilUtc <= now)
        {
            state = CircuitStates.HalfOpen;
            openUntilUtc = null;
            halfOpenProbeActive = false;
        }
    }

    private void Open(DateTimeOffset now)
    {
        state = CircuitStates.Open;
        consecutiveFailures = failureThreshold;
        openUntilUtc = now + openDuration;
        halfOpenProbeActive = false;
    }

    private void Close()
    {
        state = CircuitStates.Closed;
        consecutiveFailures = 0;
        openUntilUtc = null;
        halfOpenProbeActive = false;
    }
}

internal sealed class GatewayCircuitPermit : IDisposable
{
    private GatewayCircuitBreaker? circuit;
    private readonly bool isHalfOpenProbe;

    public GatewayCircuitPermit(GatewayCircuitBreaker circuit, bool isHalfOpenProbe)
    {
        this.circuit = circuit;
        this.isHalfOpenProbe = isHalfOpenProbe;
    }

    public void Complete(bool transientFailure)
    {
        var owner = Interlocked.Exchange(ref circuit, null)
            ?? throw new InvalidOperationException("The circuit permit is already complete.");
        owner.Complete(isHalfOpenProbe, transientFailure);
    }

    public void Dispose()
    {
        Interlocked.Exchange(ref circuit, null)?.Abandon(isHalfOpenProbe);
    }
}

internal sealed record GatewayCircuitSnapshot(
    string State,
    int ConsecutiveFailures,
    DateTimeOffset? OpenUntilUtc);
