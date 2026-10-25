using System.Collections.Concurrent;
using System.Runtime.ExceptionServices;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;

namespace LocalAIGateway.Runtime;

public sealed record GatewayRuntimeStatus(
    bool Running,
    string ActiveProfileId,
    long ActiveConfigurationRevision,
    long? PendingConfigurationRevision,
    bool Switching,
    string? LastReloadErrorCode,
    IReadOnlyList<TargetCircuitStatus> TargetCircuits);

public sealed record GatewayReloadResult(bool Reloaded, GatewayRuntimeStatus Status);

internal sealed class GatewayRouteCoordinator : IAsyncDisposable
{
    private readonly IBackendHost backendHost;
    private readonly long maxRequestBodyBytes;
    private readonly TimeSpan readyTimeout;
    private readonly TimeSpan readyPollInterval;
    private readonly int circuitFailureThreshold;
    private readonly TimeSpan circuitOpenDuration;
    private readonly TimeProvider timeProvider;
    private readonly GatewayRequestLimitRegistry requestLimits;
    private readonly SemaphoreSlim reloadLock = new(1, 1);
    private readonly ConcurrentDictionary<long, Task> retirementTasks = new();
    private readonly ConcurrentQueue<Exception> retirementFailures = new();
    private GatewayRoute activeRoute;
    private long nextRetirementId;
    private long pendingRevision = -1;
    private string? lastReloadErrorCode;
    private int switching;
    private int disposed;

    private GatewayRouteCoordinator(
        IBackendHost backendHost,
        long maxRequestBodyBytes,
        TimeSpan readyTimeout,
        TimeSpan readyPollInterval,
        int circuitFailureThreshold,
        TimeSpan circuitOpenDuration,
        TimeProvider timeProvider,
        GatewayRequestLimitRegistry requestLimits,
        GatewayRoute activeRoute)
    {
        this.backendHost = backendHost;
        this.maxRequestBodyBytes = maxRequestBodyBytes;
        this.readyTimeout = readyTimeout;
        this.readyPollInterval = readyPollInterval;
        this.circuitFailureThreshold = circuitFailureThreshold;
        this.circuitOpenDuration = circuitOpenDuration;
        this.timeProvider = timeProvider;
        this.requestLimits = requestLimits;
        this.activeRoute = activeRoute;
    }

    public static async Task<GatewayRouteCoordinator> StartAsync(
        GatewayRuntimeOptions options,
        CancellationToken cancellationToken)
    {
        var profile = ResolveActiveProfile(options.Configuration);
        var requestLimits = new GatewayRequestLimitRegistry(options.TimeProvider);
        var route = await PrepareRouteAsync(
            options.BackendHost,
            options.Configuration,
            profile,
            options.MaxRequestBodyBytes,
            options.BackendReadyTimeout,
            options.BackendReadyPollInterval,
            options.CircuitFailureThreshold,
            options.CircuitOpenDuration,
            options.TimeProvider,
            requestLimits,
            "aigw_backend_unavailable",
            cancellationToken);
        return new GatewayRouteCoordinator(
            options.BackendHost,
            options.MaxRequestBodyBytes,
            options.BackendReadyTimeout,
            options.BackendReadyPollInterval,
            options.CircuitFailureThreshold,
            options.CircuitOpenDuration,
            options.TimeProvider,
            requestLimits,
            route);
    }

    public GatewayRouteLease Acquire()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        while (true)
        {
            var route = Volatile.Read(ref activeRoute);
            var lease = route.TryAcquire();
            if (lease is null)
            {
                Thread.Yield();
                continue;
            }

            if (ReferenceEquals(route, Volatile.Read(ref activeRoute)))
            {
                return lease;
            }

            lease.Dispose();
        }
    }

    public GatewayRuntimeStatus GetStatus()
    {
        var route = Volatile.Read(ref activeRoute);
        var pending = Volatile.Read(ref pendingRevision);
        return new GatewayRuntimeStatus(
            Running: Volatile.Read(ref disposed) == 0,
            route.Profile.Id,
            route.Configuration.Revision,
            pending >= 0 ? pending : null,
            Volatile.Read(ref switching) != 0,
            Volatile.Read(ref lastReloadErrorCode),
            route.GetCircuitStatuses());
    }

    internal int TrackedRetirementCount => retirementTasks.Count;

    public async Task<bool> ProbeReadyAsync(
        GatewayRoute route,
        CancellationToken cancellationToken)
    {
        foreach (var backend in route.Backends)
        {
            if (!await backendHost.ProbeReadyAsync(backend, cancellationToken))
            {
                return false;
            }
        }

        return true;
    }

    public async Task<GatewayReloadResult> ReloadAsync(
        GatewayConfiguration configuration,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        await reloadLock.WaitAsync(cancellationToken);
        try
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
            var currentRevision = Volatile.Read(ref activeRoute).Configuration.Revision;
            if (configuration.Revision == currentRevision)
            {
                return new GatewayReloadResult(false, GetStatus());
            }

            if (configuration.Revision < currentRevision)
            {
                throw new RuntimeGatewayException(
                    "aigw_runtime_configuration_revision_stale",
                    $"Configuration revision {configuration.Revision} is older than active revision {currentRevision}.");
            }

            Volatile.Write(ref pendingRevision, configuration.Revision);
            Volatile.Write(ref lastReloadErrorCode, null);
            Volatile.Write(ref switching, 1);
            GatewayRoute? candidate = null;
            try
            {
                var validation = ConfigurationValidator.Validate(configuration);
                if (!validation.IsValid)
                {
                    throw new ConfigurationValidationException(validation.Errors);
                }

                var profile = ResolveActiveProfile(configuration);
                candidate = await PrepareRouteAsync(
                    backendHost,
                    configuration,
                    profile,
                    maxRequestBodyBytes,
                    readyTimeout,
                    readyPollInterval,
                    circuitFailureThreshold,
                    circuitOpenDuration,
                    timeProvider,
                    requestLimits,
                    "aigw_backend_not_ready",
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);

                var retired = Interlocked.Exchange(ref activeRoute, candidate);
                candidate = null;
                retired.StopAccepting();
                Volatile.Write(ref pendingRevision, -1);
                Volatile.Write(ref lastReloadErrorCode, null);
                StartRetirement(retired);
                Volatile.Write(ref switching, 0);
                return new GatewayReloadResult(true, GetStatus());
            }
            catch (Exception exception)
            {
                Exception reportedFailure = exception;
                if (candidate is not null)
                {
                    var cleanupFailures = new List<Exception>();
                    foreach (var backend in candidate.Backends)
                    {
                        try
                        {
                            await backendHost.StopAsync(backend, CancellationToken.None);
                        }
                        catch (Exception cleanupFailure)
                        {
                            cleanupFailures.Add(cleanupFailure);
                        }
                    }

                    if (cleanupFailures.Count > 0)
                    {
                        reportedFailure = new RuntimeGatewayException(
                            "aigw_backend_candidate_cleanup_failed",
                            "An unpublished backend candidate could not be fully cleaned up.",
                            new AggregateException([exception, .. cleanupFailures]));
                    }
                }

                Volatile.Write(ref lastReloadErrorCode, ErrorCodeFor(reportedFailure));
                ExceptionDispatchInfo.Capture(reportedFailure).Throw();
                throw new InvalidOperationException("Unreachable reload failure path.");
            }
        }
        finally
        {
            Volatile.Write(ref switching, 0);
            reloadLock.Release();
        }
    }

    public async Task RecordReloadFailureAsync(
        string errorCode,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(errorCode);
        await reloadLock.WaitAsync(cancellationToken);
        try
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
            Volatile.Write(ref lastReloadErrorCode, errorCode);
        }
        finally
        {
            reloadLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        await reloadLock.WaitAsync();
        try
        {
            var active = Volatile.Read(ref activeRoute);
            active.StopAccepting();
            await active.WaitForLeasesAsync();

            var retirements = retirementTasks.Values.ToArray();
            var failures = new List<Exception>();
            await Task.WhenAll(retirements);
            while (retirementFailures.TryDequeue(out var retirementFailure))
            {
                failures.Add(retirementFailure);
            }

            await RetireRouteAsync(active, failures);
            ThrowCleanupFailures(failures);
        }
        finally
        {
            reloadLock.Release();
            reloadLock.Dispose();
        }
    }

    private void StartRetirement(GatewayRoute route)
    {
        var retirementId = Interlocked.Increment(ref nextRetirementId);
        var startGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var retirement = TrackRetirementAsync(retirementId, route, startGate.Task);
        if (!retirementTasks.TryAdd(retirementId, retirement))
        {
            throw new InvalidOperationException("Duplicate backend retirement identifier.");
        }

        startGate.TrySetResult();
    }

    private async Task TrackRetirementAsync(long retirementId, GatewayRoute route, Task startGate)
    {
        try
        {
            await startGate;
            await route.WaitForLeasesAsync();
            var failures = new List<Exception>();
            await RetireRouteAsync(route, failures);
            ThrowCleanupFailures(failures);
        }
        catch (Exception failure)
        {
            retirementFailures.Enqueue(failure);
            Volatile.Write(ref lastReloadErrorCode, "aigw_backend_retirement_failed");
        }
        finally
        {
            retirementTasks.TryRemove(retirementId, out _);
        }
    }

    private async Task RetireRouteAsync(GatewayRoute route, ICollection<Exception> failures)
    {
        foreach (var backend in route.Backends)
        {
            try
            {
                await backendHost.DrainAsync(backend);
            }
            catch (Exception failure)
            {
                failures.Add(failure);
            }
        }

        foreach (var backend in route.Backends)
        {
            try
            {
                await backendHost.StopAsync(backend);
            }
            catch (Exception failure)
            {
                failures.Add(failure);
            }
        }
    }

    private static async Task<GatewayRoute> PrepareRouteAsync(
        IBackendHost backendHost,
        GatewayConfiguration configuration,
        ProfileConfiguration profile,
        long maxRequestBodyBytes,
        TimeSpan readyTimeout,
        TimeSpan readyPollInterval,
        int circuitFailureThreshold,
        TimeSpan circuitOpenDuration,
        TimeProvider timeProvider,
        GatewayRequestLimitRegistry requestLimits,
        string notReadyErrorCode,
        CancellationToken cancellationToken)
    {
        var preparedBackends = new List<BackendInstance>();
        try
        {
            var primaryBackend = await PrepareBackendAsync(
                backendHost,
                profile,
                readyTimeout,
                readyPollInterval,
                notReadyErrorCode,
                cancellationToken);
            preparedBackends.Add(primaryBackend);

            var fallbackTargets = new List<PreparedFallbackTarget>();
            foreach (var model in profile.Models)
            {
                foreach (var fallback in model.Fallbacks)
                {
                    var provider = GatewayConfigurationManager.FindProvider(profile, fallback.ProviderId);
                    var targetProfile = profile with
                    {
                        Providers = [provider],
                        Models =
                        [
                            model with
                            {
                                ProviderId = fallback.ProviderId,
                                UpstreamModel = fallback.UpstreamModel,
                                IsDefault = true,
                                RoutingStrategy = ModelRoutingStrategy.OrderedFallback,
                                Weight = 1,
                                Fallbacks = [],
                            },
                        ],
                    };
                    var fallbackBackend = await PrepareBackendAsync(
                        backendHost,
                        targetProfile,
                        readyTimeout,
                        readyPollInterval,
                        notReadyErrorCode,
                        cancellationToken);
                    preparedBackends.Add(fallbackBackend);
                    fallbackTargets.Add(new PreparedFallbackTarget(
                        model.Alias,
                        fallback.ProviderId,
                        fallback.Weight,
                        provider.Limits,
                        fallbackBackend));
                }
            }

            return new GatewayRoute(
                configuration,
                profile,
                primaryBackend,
                fallbackTargets,
                new ModelRequestRewriter(profile, maxRequestBodyBytes),
                circuitFailureThreshold,
                circuitOpenDuration,
                timeProvider,
                requestLimits);
        }
        catch (Exception startupFailure)
        {
            if (preparedBackends.Count == 0)
            {
                throw;
            }

            var cleanupFailures = new List<Exception>();
            foreach (var backend in preparedBackends.AsEnumerable().Reverse())
            {
                try
                {
                    await backendHost.StopAsync(backend, CancellationToken.None);
                }
                catch (Exception cleanupFailure)
                {
                    cleanupFailures.Add(cleanupFailure);
                }
            }

            if (cleanupFailures.Count > 0)
            {
                throw new RuntimeGatewayException(
                    "aigw_backend_candidate_cleanup_failed",
                    "Backend candidate failed and could not be fully cleaned up.",
                    new AggregateException([startupFailure, .. cleanupFailures]));
            }

            ExceptionDispatchInfo.Capture(startupFailure).Throw();
            throw new InvalidOperationException("Unreachable backend preparation failure path.");
        }
    }

    private static async Task<BackendInstance> PrepareBackendAsync(
        IBackendHost backendHost,
        ProfileConfiguration profile,
        TimeSpan readyTimeout,
        TimeSpan readyPollInterval,
        string notReadyErrorCode,
        CancellationToken cancellationToken)
    {
        BackendInstance backend;
        try
        {
            backend = await backendHost.PrepareAsync(profile, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (BackendHostException exception) when (exception.Category == BackendFailureCategory.Credential)
        {
            throw new BackendCredentialException(exception.ErrorCode, exception.Message, exception);
        }
        catch (BackendHostException exception) when (exception.Category == BackendFailureCategory.Configuration)
        {
            throw new RuntimeGatewayException(exception.ErrorCode, exception.Message, exception);
        }
        catch (BackendHostException exception)
        {
            throw new BackendUnavailableException(exception.Message, exception, exception.ErrorCode);
        }
        catch (Exception exception)
        {
            throw new BackendUnavailableException("Backend preparation failed.", exception);
        }

        try
        {
            ValidateBackend(backend);
            bool ready;
            try
            {
                ready = await WaitForBackendReadyAsync(
                    backendHost,
                    backend,
                    readyTimeout,
                    readyPollInterval,
                    cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new BackendUnavailableException("Backend readiness probe failed.", exception);
            }

            if (!ready)
            {
                throw new BackendUnavailableException(
                    "Backend did not become ready within the configured startup timeout.",
                    errorCode: notReadyErrorCode);
            }

            return backend;
        }
        catch (Exception startupFailure)
        {
            try
            {
                await backendHost.StopAsync(backend, CancellationToken.None);
            }
            catch (Exception cleanupFailure)
            {
                throw new RuntimeGatewayException(
                    "aigw_backend_candidate_cleanup_failed",
                    "Backend candidate failed and could not be fully cleaned up.",
                    new AggregateException(startupFailure, cleanupFailure));
            }

            ExceptionDispatchInfo.Capture(startupFailure).Throw();
            throw new InvalidOperationException("Unreachable backend preparation failure path.");
        }
    }

    private static async Task<bool> WaitForBackendReadyAsync(
        IBackendHost backendHost,
        BackendInstance backend,
        TimeSpan timeout,
        TimeSpan pollInterval,
        CancellationToken cancellationToken)
    {
        using var readinessTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        readinessTimeout.CancelAfter(timeout);
        try
        {
            while (true)
            {
                if (await backendHost.ProbeReadyAsync(backend, readinessTimeout.Token))
                {
                    return true;
                }

                await Task.Delay(pollInterval, readinessTimeout.Token);
            }
        }
        catch (OperationCanceledException)
            when (!cancellationToken.IsCancellationRequested && readinessTimeout.IsCancellationRequested)
        {
            return false;
        }
    }

    private static ProfileConfiguration ResolveActiveProfile(GatewayConfiguration configuration)
    {
        if (configuration.ActiveProfileId is null)
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_active_profile_missing",
                "Gateway configuration does not have an active profile.");
        }

        var profile = GatewayConfigurationManager.FindProfile(configuration, configuration.ActiveProfileId);
        if (!ConfigurationValidator.IsActivatable(profile))
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_active_profile_incomplete",
                "Gateway active profile is incomplete.");
        }

        return profile;
    }

    private static void ValidateBackend(BackendInstance backend)
    {
        if (!backend.BaseAddress.IsAbsoluteUri ||
            !backend.BaseAddress.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(backend.BaseAddress.UserInfo) ||
            !string.IsNullOrEmpty(backend.BaseAddress.Query) ||
            !string.IsNullOrEmpty(backend.BaseAddress.Fragment) ||
            backend.BaseAddress.AbsolutePath != "/" ||
            !System.Net.IPAddress.TryParse(backend.BaseAddress.Host, out var address) ||
            !System.Net.IPAddress.IsLoopback(address))
        {
            throw new BackendUnavailableException("Backend endpoint must be an absolute HTTP loopback URI.");
        }

        if (string.IsNullOrWhiteSpace(backend.InternalToken) ||
            backend.InternalToken.Length > 1024 ||
            backend.InternalToken.Any(char.IsControl))
        {
            throw new BackendUnavailableException("Backend internal token is missing or malformed.");
        }
    }

    private static string ErrorCodeFor(Exception exception) => exception switch
    {
        RuntimeGatewayException runtime => runtime.ErrorCode,
        ConfigurationException configuration => configuration.ErrorCode,
        _ => "aigw_control_reload_failed",
    };

    private static void ThrowCleanupFailures(IReadOnlyCollection<Exception> failures)
    {
        if (failures.Count == 1)
        {
            ExceptionDispatchInfo.Capture(failures.First()).Throw();
        }

        if (failures.Count > 1)
        {
            throw new AggregateException("One or more backend routes could not be retired.", failures);
        }
    }
}

internal sealed class GatewayRoute
{
    private readonly object leaseLock = new();
    private readonly TaskCompletionSource leasesDrained =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool accepting = true;
    private int leaseCount;
    private readonly IReadOnlyDictionary<string, IReadOnlyList<GatewayRouteTarget>> targets;
    private readonly IReadOnlyDictionary<string, SmoothWeightedTargetSelector> weightedSelectors;
    private readonly GatewayRequestLimitRegistry requestLimits;

    public GatewayRoute(
        GatewayConfiguration configuration,
        ProfileConfiguration profile,
        BackendInstance primaryBackend,
        IReadOnlyList<PreparedFallbackTarget> fallbackTargets,
        ModelRequestRewriter modelRewriter,
        int circuitFailureThreshold,
        TimeSpan circuitOpenDuration,
        TimeProvider timeProvider,
        GatewayRequestLimitRegistry requestLimits)
    {
        Configuration = configuration;
        Profile = profile;
        ModelRewriter = modelRewriter;
        this.requestLimits = requestLimits;
        var providerLimits = profile.Providers.ToDictionary(
            provider => provider.Id,
            provider => provider.Limits,
            StringComparer.OrdinalIgnoreCase);
        targets = profile.Models.ToDictionary(
            model => model.Alias,
            model => (IReadOnlyList<GatewayRouteTarget>)
            [
                new GatewayRouteTarget(
                    model.ProviderId,
                    model.Weight,
                    providerLimits[model.ProviderId],
                    primaryBackend,
                    new GatewayCircuitBreaker(circuitFailureThreshold, circuitOpenDuration, timeProvider)),
                .. fallbackTargets
                    .Where(target => StringComparer.OrdinalIgnoreCase.Equals(target.PublicAlias, model.Alias))
                    .Select(target => new GatewayRouteTarget(
                        target.ProviderId,
                        target.Weight,
                        target.Limits,
                        target.Backend,
                        new GatewayCircuitBreaker(circuitFailureThreshold, circuitOpenDuration, timeProvider))),
            ],
            StringComparer.OrdinalIgnoreCase);
        weightedSelectors = profile.Models
            .Where(model => model.RoutingStrategy == ModelRoutingStrategy.WeightedRoundRobin)
            .ToDictionary(
                model => model.Alias,
                model => new SmoothWeightedTargetSelector(targets[model.Alias]),
                StringComparer.OrdinalIgnoreCase);
        Backends = targets.Values
            .SelectMany(modelTargets => modelTargets)
            .Select(target => target.Backend)
            .Distinct()
            .ToArray();
    }

    public GatewayConfiguration Configuration { get; }

    public ProfileConfiguration Profile { get; }

    public IReadOnlyList<BackendInstance> Backends { get; }

    public ModelRequestRewriter ModelRewriter { get; }

    public IReadOnlyList<GatewayRouteTarget> GetTargets(ModelConfiguration model)
    {
        if (!targets.TryGetValue(model.Alias, out var modelTargets))
        {
            throw new InvalidOperationException("The rewritten model does not belong to the active route.");
        }

        return modelTargets;
    }

    public bool TryReserveRequestLimits(
        ModelConfiguration model,
        out GatewayLimitReservation reservation,
        out GatewayLimitRejection? rejection) =>
        requestLimits.TryReserve(
            [GatewayLimitScope.Profile(Profile), GatewayLimitScope.Model(Profile.Id, model)],
            out reservation,
            out rejection);

    public bool TryReserveProviderLimits(
        GatewayRouteTarget target,
        out GatewayLimitReservation reservation,
        out GatewayLimitRejection? rejection) =>
        requestLimits.TryReserve(
            [GatewayLimitScope.Provider(Profile.Id, target)],
            out reservation,
            out rejection);

    public bool TryAcquireWeightedTarget(
        ModelConfiguration model,
        out GatewayRouteTarget? target,
        out GatewayCircuitPermit? permit,
        out TimeSpan retryAfter)
    {
        if (!weightedSelectors.TryGetValue(model.Alias, out var selector))
        {
            throw new InvalidOperationException("The rewritten model does not use weighted round robin.");
        }

        return selector.TryAcquire(out target, out permit, out retryAfter);
    }

    public IReadOnlyList<TargetCircuitStatus> GetCircuitStatuses() =>
        targets
            .SelectMany(pair => pair.Value.Select(target =>
            {
                var snapshot = target.Circuit.GetSnapshot();
                return new TargetCircuitStatus(
                    target.ProviderId,
                    pair.Key,
                    snapshot.State,
                    snapshot.ConsecutiveFailures,
                    snapshot.OpenUntilUtc);
            }))
            .ToArray();

    public GatewayRouteLease? TryAcquire()
    {
        lock (leaseLock)
        {
            if (!accepting)
            {
                return null;
            }

            leaseCount++;
            return new GatewayRouteLease(this);
        }
    }

    public void StopAccepting()
    {
        lock (leaseLock)
        {
            accepting = false;
            if (leaseCount == 0)
            {
                leasesDrained.TrySetResult();
            }
        }
    }

    public Task WaitForLeasesAsync() => leasesDrained.Task;

    public void Release()
    {
        lock (leaseLock)
        {
            if (leaseCount <= 0)
            {
                throw new InvalidOperationException("Gateway route lease count is invalid.");
            }

            leaseCount--;
            if (!accepting && leaseCount == 0)
            {
                leasesDrained.TrySetResult();
            }
        }
    }
}

internal sealed record PreparedFallbackTarget(
    string PublicAlias,
    string ProviderId,
    int Weight,
    RequestLimitConfiguration? Limits,
    BackendInstance Backend);

internal sealed record GatewayRouteTarget(
    string ProviderId,
    int Weight,
    RequestLimitConfiguration? Limits,
    BackendInstance Backend,
    GatewayCircuitBreaker Circuit);

internal sealed class SmoothWeightedTargetSelector(IReadOnlyList<GatewayRouteTarget> targets)
{
    private readonly object gate = new();
    private readonly long[] currentWeights = new long[targets.Count];

    public bool TryAcquire(
        out GatewayRouteTarget? target,
        out GatewayCircuitPermit? permit,
        out TimeSpan retryAfter)
    {
        lock (gate)
        {
            var selectedIndex = -1;
            var totalWeight = 0L;
            TimeSpan? shortestRetryAfter = null;
            for (var index = 0; index < targets.Count; index++)
            {
                var candidate = targets[index];
                if (!candidate.Circuit.CanAcquire(out var candidateRetryAfter))
                {
                    currentWeights[index] = 0;
                    if (shortestRetryAfter is null || candidateRetryAfter < shortestRetryAfter)
                    {
                        shortestRetryAfter = candidateRetryAfter;
                    }

                    continue;
                }

                currentWeights[index] += candidate.Weight;
                totalWeight += candidate.Weight;
                if (selectedIndex < 0 || currentWeights[index] > currentWeights[selectedIndex])
                {
                    selectedIndex = index;
                }
            }

            if (selectedIndex < 0)
            {
                target = null;
                permit = null;
                retryAfter = shortestRetryAfter ?? TimeSpan.FromSeconds(1);
                return false;
            }

            currentWeights[selectedIndex] -= totalWeight;
            target = targets[selectedIndex];
            if (!target.Circuit.TryAcquire(out permit, out retryAfter))
            {
                throw new InvalidOperationException("A weighted target became unavailable during serialized selection.");
            }

            return true;
        }
    }
}

internal sealed class GatewayRouteLease : IDisposable
{
    private GatewayRoute? route;

    public GatewayRouteLease(GatewayRoute route)
    {
        this.route = route;
        Route = route;
    }

    public GatewayRoute Route { get; }

    public void Dispose()
    {
        Interlocked.Exchange(ref route, null)?.Release();
    }
}
