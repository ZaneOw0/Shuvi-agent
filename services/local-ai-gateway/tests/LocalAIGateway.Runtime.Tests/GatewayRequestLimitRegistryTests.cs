using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayRequestLimitRegistryTests
{
    private static readonly DateTimeOffset Start =
        new(2026, 9, 17, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Concurrency_is_reserved_atomically_and_released_even_without_commit()
    {
        var registry = new GatewayRequestLimitRegistry(new MutableTimeProvider(Start));
        var scope = Scope(GatewayLimitScopeKind.Profile, "profile", new() { MaxConcurrentRequests = 1 });

        Assert.True(registry.TryReserve([scope], out var first, out _));
        Assert.False(registry.TryReserve([scope], out _, out var rejected));
        Assert.Equal("aigw_concurrency_limit_exceeded", rejected!.ErrorCode);

        first.Dispose();
        Assert.True(registry.TryReserve([scope], out var replacement, out _));
        replacement.Dispose();
    }

    [Fact]
    public void Rpm_uses_a_strict_rolling_minute_and_counts_only_committed_admissions()
    {
        var time = new MutableTimeProvider(Start);
        var registry = new GatewayRequestLimitRegistry(time);
        var scope = Scope(GatewayLimitScopeKind.Profile, "profile", new() { RequestsPerMinute = 2 });

        ReserveCommitDispose(registry, scope);
        Assert.True(registry.TryReserve([scope], out var abandoned, out _));
        abandoned.Dispose();
        ReserveCommitDispose(registry, scope);

        Assert.False(registry.TryReserve([scope], out _, out var rejected));
        Assert.Equal("aigw_rpm_limit_exceeded", rejected!.ErrorCode);
        Assert.Equal(TimeSpan.FromMinutes(1), rejected.RetryAfter);

        time.Advance(TimeSpan.FromSeconds(60));
        Assert.True(registry.TryReserve([scope], out var next, out _));
        next.Dispose();
    }

    [Fact]
    public void Tpm_uses_recorded_response_usage_and_allows_one_completed_request_to_cross_the_limit()
    {
        var time = new MutableTimeProvider(Start);
        var registry = new GatewayRequestLimitRegistry(time);
        var scope = Scope(GatewayLimitScopeKind.Model, "chat", new() { TokensPerMinute = 10 });

        Assert.True(registry.TryReserve([scope], out var first, out _));
        first.Commit();
        first.RecordTokens(12);
        first.Dispose();

        Assert.False(registry.TryReserve([scope], out _, out var rejected));
        Assert.Equal("aigw_tpm_limit_exceeded", rejected!.ErrorCode);
        Assert.Equal(TimeSpan.FromMinutes(1), rejected.RetryAfter);

        time.Advance(TimeSpan.FromMinutes(1));
        Assert.True(registry.TryReserve([scope], out var afterWindow, out _));
        afterWindow.Dispose();
    }

    [Fact]
    public void All_configured_layers_are_checked_and_the_longest_retry_after_is_returned()
    {
        var time = new MutableTimeProvider(Start);
        var registry = new GatewayRequestLimitRegistry(time);
        var profile = Scope(GatewayLimitScopeKind.Profile, "profile", new() { RequestsPerMinute = 1 });
        var model = Scope(GatewayLimitScopeKind.Model, "chat", new() { TokensPerMinute = 1 });

        ReserveCommitDispose(registry, profile);
        time.Advance(TimeSpan.FromSeconds(10));
        Assert.True(registry.TryReserve([model], out var tokenPermit, out _));
        tokenPermit.Commit();
        tokenPermit.RecordTokens(1);
        tokenPermit.Dispose();

        Assert.False(registry.TryReserve([profile, model], out _, out var rejected));
        Assert.Equal("aigw_tpm_limit_exceeded", rejected!.ErrorCode);
        Assert.Equal(TimeSpan.FromMinutes(1), rejected.RetryAfter);
    }

    [Fact]
    public void State_is_shared_across_case_variants_and_updated_limit_snapshots()
    {
        var registry = new GatewayRequestLimitRegistry(new MutableTimeProvider(Start));
        ReserveCommitDispose(
            registry,
            new GatewayLimitScope(
                GatewayLimitScopeKind.Provider,
                "Profile",
                "Provider",
                new RequestLimitConfiguration { RequestsPerMinute = 5 }));

        var tightened = new GatewayLimitScope(
            GatewayLimitScopeKind.Provider,
            "profile",
            "provider",
            new RequestLimitConfiguration { RequestsPerMinute = 1 });
        Assert.False(registry.TryReserve([tightened], out _, out var rejected));
        Assert.Equal("aigw_rpm_limit_exceeded", rejected!.ErrorCode);
    }

    private static GatewayLimitScope Scope(
        GatewayLimitScopeKind kind,
        string id,
        RequestLimitConfiguration limits) => new(kind, "profile", id, limits);

    private static void ReserveCommitDispose(
        GatewayRequestLimitRegistry registry,
        GatewayLimitScope scope)
    {
        Assert.True(registry.TryReserve([scope], out var permit, out _));
        permit.Commit();
        permit.Dispose();
    }

    private sealed class MutableTimeProvider(DateTimeOffset now) : TimeProvider
    {
        private DateTimeOffset utcNow = now;

        public override DateTimeOffset GetUtcNow() => utcNow;

        public void Advance(TimeSpan value) => utcNow += value;
    }
}
