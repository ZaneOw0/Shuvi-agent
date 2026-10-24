using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Runtime;

internal enum GatewayLimitScopeKind
{
    Profile,
    Provider,
    Model,
}

internal readonly record struct GatewayLimitScope(
    GatewayLimitScopeKind Kind,
    string ProfileId,
    string SubjectId,
    RequestLimitConfiguration? Limits)
{
    public static GatewayLimitScope Profile(ProfileConfiguration profile) =>
        new(GatewayLimitScopeKind.Profile, profile.Id, profile.Id, profile.Limits);

    public static GatewayLimitScope Provider(string profileId, GatewayRouteTarget target) =>
        new(GatewayLimitScopeKind.Provider, profileId, target.ProviderId, target.Limits);

    public static GatewayLimitScope Model(string profileId, ModelConfiguration model) =>
        new(GatewayLimitScopeKind.Model, profileId, model.Alias, model.Limits);
}

internal sealed record GatewayLimitRejection(string ErrorCode, string Message, TimeSpan RetryAfter);

internal sealed class GatewayRequestLimitRegistry(TimeProvider timeProvider)
{
    private static readonly TimeSpan Window = TimeSpan.FromMinutes(1);
    private readonly object gate = new();
    private readonly Dictionary<LimitKey, LimitState> states = [];

    public bool TryReserve(
        IReadOnlyList<GatewayLimitScope> scopes,
        out GatewayLimitReservation reservation,
        out GatewayLimitRejection? rejection)
    {
        lock (gate)
        {
            var now = timeProvider.GetUtcNow();
            var active = scopes
                .Where(scope => HasLimits(scope.Limits))
                .Select(scope => (scope, state: GetState(scope)))
                .ToArray();
            GatewayLimitRejection? selectedRejection = null;
            foreach (var (scope, state) in active)
            {
                Prune(state, now);
                var candidate = GetRejection(scope, state, now);
                if (candidate is not null &&
                    (selectedRejection is null || candidate.RetryAfter > selectedRejection.RetryAfter))
                {
                    selectedRejection = candidate;
                }
            }

            if (selectedRejection is not null)
            {
                reservation = GatewayLimitReservation.Empty;
                rejection = selectedRejection;
                return false;
            }

            foreach (var (_, state) in active)
            {
                state.ConcurrentRequests++;
            }

            reservation = active.Length == 0
                ? GatewayLimitReservation.Empty
                : new GatewayLimitReservation(
                    this,
                    active.Select(item => item.state).ToArray(),
                    active
                        .Where(item => item.scope.Limits!.RequestsPerMinute is not null)
                        .Select(item => item.state)
                        .ToArray(),
                    active
                        .Where(item => item.scope.Limits!.TokensPerMinute is not null)
                        .Select(item => item.state)
                        .ToArray());
            rejection = null;
            return true;
        }
    }

    internal void Commit(IReadOnlyList<LimitState> reservedStates)
    {
        lock (gate)
        {
            var now = timeProvider.GetUtcNow();
            foreach (var state in reservedStates)
            {
                state.Requests.Enqueue(now);
            }
        }
    }

    internal void RecordTokens(IReadOnlyList<LimitState> reservedStates, long totalTokens)
    {
        if (totalTokens < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(totalTokens));
        }

        if (totalTokens == 0)
        {
            return;
        }

        lock (gate)
        {
            var now = timeProvider.GetUtcNow();
            foreach (var state in reservedStates)
            {
                state.TokenEvents.Enqueue(new TokenEvent(now, totalTokens));
                state.RollingTokens += (UInt128)totalTokens;
            }
        }
    }

    internal void Release(IReadOnlyList<LimitState> reservedStates)
    {
        lock (gate)
        {
            foreach (var state in reservedStates)
            {
                if (state.ConcurrentRequests <= 0)
                {
                    throw new InvalidOperationException("Gateway limit concurrency state is invalid.");
                }

                state.ConcurrentRequests--;
            }
        }
    }

    private GatewayLimitRejection? GetRejection(
        GatewayLimitScope scope,
        LimitState state,
        DateTimeOffset now)
    {
        var limits = scope.Limits!;
        if (limits.MaxConcurrentRequests is int concurrency && state.ConcurrentRequests >= concurrency)
        {
            return Rejection(
                "aigw_concurrency_limit_exceeded",
                scope,
                "concurrent request",
                TimeSpan.FromSeconds(1));
        }

        if (limits.RequestsPerMinute is int rpm && state.Requests.Count >= rpm)
        {
            return Rejection(
                "aigw_rpm_limit_exceeded",
                scope,
                "requests-per-minute",
                RetryAfter(state.Requests.Peek(), now));
        }

        if (limits.TokensPerMinute is long tpm && state.RollingTokens >= (UInt128)tpm)
        {
            return Rejection(
                "aigw_tpm_limit_exceeded",
                scope,
                "tokens-per-minute",
                RetryAfter(state.TokenEvents.Peek().OccurredUtc, now));
        }

        return null;
    }

    private static GatewayLimitRejection Rejection(
        string code,
        GatewayLimitScope scope,
        string label,
        TimeSpan retryAfter) => new(
            code,
            $"The {ScopeLabel(scope.Kind)} {label} limit has been reached.",
            retryAfter);

    private static string ScopeLabel(GatewayLimitScopeKind kind) => kind switch
    {
        GatewayLimitScopeKind.Profile => "profile",
        GatewayLimitScopeKind.Provider => "provider",
        GatewayLimitScopeKind.Model => "model",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static TimeSpan RetryAfter(DateTimeOffset oldest, DateTimeOffset now)
    {
        var delay = oldest + Window - now;
        return delay > TimeSpan.Zero ? delay : TimeSpan.FromSeconds(1);
    }

    private static bool HasLimits(RequestLimitConfiguration? limits) =>
        limits is not null &&
        (limits.MaxConcurrentRequests is not null ||
         limits.RequestsPerMinute is not null ||
         limits.TokensPerMinute is not null);

    private LimitState GetState(GatewayLimitScope scope)
    {
        var key = new LimitKey(
            scope.Kind,
            scope.ProfileId.ToUpperInvariant(),
            scope.SubjectId.ToUpperInvariant());
        if (!states.TryGetValue(key, out var state))
        {
            state = new LimitState();
            states.Add(key, state);
        }

        return state;
    }

    private static void Prune(LimitState state, DateTimeOffset now)
    {
        var start = now - Window;
        while (state.Requests.TryPeek(out var occurredUtc) && occurredUtc <= start)
        {
            state.Requests.Dequeue();
        }

        while (state.TokenEvents.TryPeek(out var tokenEvent) && tokenEvent.OccurredUtc <= start)
        {
            state.TokenEvents.Dequeue();
            state.RollingTokens -= (UInt128)tokenEvent.TotalTokens;
        }
    }

    private readonly record struct LimitKey(GatewayLimitScopeKind Kind, string ProfileId, string SubjectId);
    internal readonly record struct TokenEvent(DateTimeOffset OccurredUtc, long TotalTokens);

    internal sealed class LimitState
    {
        public int ConcurrentRequests { get; set; }
        public Queue<DateTimeOffset> Requests { get; } = new();
        public Queue<TokenEvent> TokenEvents { get; } = new();
        public UInt128 RollingTokens { get; set; }
    }
}

internal sealed class GatewayLimitReservation : IDisposable
{
    public static GatewayLimitReservation Empty => new(null, [], [], []);

    private GatewayRequestLimitRegistry? registry;
    private readonly IReadOnlyList<GatewayRequestLimitRegistry.LimitState> states;
    private readonly IReadOnlyList<GatewayRequestLimitRegistry.LimitState> rpmStates;
    private readonly IReadOnlyList<GatewayRequestLimitRegistry.LimitState> tokenStates;
    private int committed;

    internal GatewayLimitReservation(
        GatewayRequestLimitRegistry? registry,
        IReadOnlyList<GatewayRequestLimitRegistry.LimitState> states,
        IReadOnlyList<GatewayRequestLimitRegistry.LimitState> rpmStates,
        IReadOnlyList<GatewayRequestLimitRegistry.LimitState> tokenStates)
    {
        this.registry = registry;
        this.states = states;
        this.rpmStates = rpmStates;
        this.tokenStates = tokenStates;
    }

    public bool TracksTokens => tokenStates.Count > 0;

    public void Commit()
    {
        var current = Volatile.Read(ref registry);
        if (current is not null && Interlocked.Exchange(ref committed, 1) == 0)
        {
            current.Commit(rpmStates);
        }
    }

    public void RecordTokens(long totalTokens)
    {
        var current = Volatile.Read(ref registry);
        if (current is not null && Volatile.Read(ref committed) != 0)
        {
            current.RecordTokens(tokenStates, totalTokens);
        }
    }

    public void Dispose()
    {
        Interlocked.Exchange(ref registry, null)?.Release(states);
    }
}
