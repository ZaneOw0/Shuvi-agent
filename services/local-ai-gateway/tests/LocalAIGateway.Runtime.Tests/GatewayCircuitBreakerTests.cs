using LocalAIGateway.Core.Control;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayCircuitBreakerTests
{
    private static readonly DateTimeOffset Start =
        new(2026, 9, 15, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Consecutive_transient_failures_open_the_circuit_and_success_resets_the_streak()
    {
        var time = new MutableTimeProvider(Start);
        var circuit = new GatewayCircuitBreaker(3, TimeSpan.FromSeconds(30), time);

        Complete(circuit, transientFailure: true);
        Complete(circuit, transientFailure: false);
        Complete(circuit, transientFailure: true);
        Complete(circuit, transientFailure: true);

        var closed = circuit.GetSnapshot();
        Assert.Equal(CircuitStates.Closed, closed.State);
        Assert.Equal(2, closed.ConsecutiveFailures);

        Complete(circuit, transientFailure: true);

        var opened = circuit.GetSnapshot();
        Assert.Equal(CircuitStates.Open, opened.State);
        Assert.Equal(3, opened.ConsecutiveFailures);
        Assert.Equal(Start.AddSeconds(30), opened.OpenUntilUtc);
        Assert.False(circuit.CanAcquire(out var availabilityRetryAfter));
        Assert.Equal(TimeSpan.FromSeconds(30), availabilityRetryAfter);
        Assert.False(circuit.TryAcquire(out var rejected, out var retryAfter));
        Assert.Null(rejected);
        Assert.Equal(TimeSpan.FromSeconds(30), retryAfter);
    }

    [Fact]
    public void Expired_open_circuit_allows_one_half_open_probe_and_success_closes_it()
    {
        var time = new MutableTimeProvider(Start);
        var circuit = new GatewayCircuitBreaker(1, TimeSpan.FromSeconds(30), time);
        Complete(circuit, transientFailure: true);
        time.Advance(TimeSpan.FromSeconds(30));

        Assert.True(circuit.CanAcquire(out _));
        Assert.True(circuit.TryAcquire(out var probe, out _));
        using (probe)
        {
            Assert.Equal(CircuitStates.HalfOpen, circuit.GetSnapshot().State);
            Assert.False(circuit.CanAcquire(out var availabilityRetryAfter));
            Assert.Equal(TimeSpan.FromSeconds(1), availabilityRetryAfter);
            Assert.False(circuit.TryAcquire(out var concurrent, out var retryAfter));
            Assert.Null(concurrent);
            Assert.Equal(TimeSpan.FromSeconds(1), retryAfter);
            probe!.Complete(transientFailure: false);
        }

        var closed = circuit.GetSnapshot();
        Assert.Equal(CircuitStates.Closed, closed.State);
        Assert.Equal(0, closed.ConsecutiveFailures);
        Assert.Null(closed.OpenUntilUtc);
    }

    [Fact]
    public void Failed_half_open_probe_reopens_and_abandoned_probe_can_be_replaced()
    {
        var time = new MutableTimeProvider(Start);
        var circuit = new GatewayCircuitBreaker(1, TimeSpan.FromSeconds(20), time);
        Complete(circuit, transientFailure: true);
        time.Advance(TimeSpan.FromSeconds(20));

        Assert.True(circuit.TryAcquire(out var abandoned, out _));
        abandoned!.Dispose();
        Assert.True(circuit.TryAcquire(out var replacement, out _));
        replacement!.Complete(transientFailure: true);

        var reopened = circuit.GetSnapshot();
        Assert.Equal(CircuitStates.Open, reopened.State);
        Assert.Equal(Start.AddSeconds(40), reopened.OpenUntilUtc);
    }

    [Fact]
    public void Abandoned_closed_request_does_not_count_or_reset_target_failures()
    {
        var circuit = new GatewayCircuitBreaker(3, TimeSpan.FromSeconds(20), new MutableTimeProvider(Start));
        Complete(circuit, transientFailure: true);

        Assert.True(circuit.TryAcquire(out var abandoned, out _));
        abandoned!.Dispose();

        var snapshot = circuit.GetSnapshot();
        Assert.Equal(CircuitStates.Closed, snapshot.State);
        Assert.Equal(1, snapshot.ConsecutiveFailures);
    }

    private static void Complete(GatewayCircuitBreaker circuit, bool transientFailure)
    {
        Assert.True(circuit.TryAcquire(out var permit, out _));
        permit!.Complete(transientFailure);
    }

    private sealed class MutableTimeProvider(DateTimeOffset now) : TimeProvider
    {
        private DateTimeOffset utcNow = now;

        public override DateTimeOffset GetUtcNow() => utcNow;

        public void Advance(TimeSpan value) => utcNow += value;
    }
}
