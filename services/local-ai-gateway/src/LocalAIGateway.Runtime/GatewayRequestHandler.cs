using System.Net;
using System.Net.Http;
using System.Text.Json;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Yarp.ReverseProxy.Forwarder;

namespace LocalAIGateway.Runtime;

internal sealed class GatewayRequestHandler
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly GatewayAuthentication authentication;
    private readonly GatewayRouteCoordinator routeCoordinator;
    private readonly IHttpForwarder forwarder;
    private readonly HttpMessageInvoker httpClient;
    private readonly ForwarderRequestConfig forwarderConfig;
    private readonly TimeProvider timeProvider;

    public GatewayRequestHandler(
        GatewayRuntimeOptions options,
        GatewayRouteCoordinator routeCoordinator,
        IHttpForwarder forwarder,
        HttpMessageInvoker httpClient)
    {
        authentication = new GatewayAuthentication(options.ClientToken);
        this.routeCoordinator = routeCoordinator;
        this.forwarder = forwarder;
        this.httpClient = httpClient;
        timeProvider = options.TimeProvider;
        forwarderConfig = new ForwarderRequestConfig
        {
            ActivityTimeout = options.ForwardingTimeout,
            AllowResponseBuffering = false,
        };
    }

    public async Task AuthenticateAsync(HttpContext context, RequestDelegate next)
    {
        if (!authentication.Authenticate(context.Request))
        {
            await GatewayErrorWriter.WriteAsync(
                context,
                StatusCodes.Status401Unauthorized,
                "aigw_auth_invalid",
                "Local gateway authentication failed.");
            return;
        }

        await next(context);
    }

    public async Task HealthAsync(HttpContext context)
    {
        using var lease = routeCoordinator.Acquire();
        await WriteJsonAsync(context, StatusCodes.Status200OK, new { status = "healthy" });
    }

    public async Task ReadyAsync(HttpContext context)
    {
        using var lease = routeCoordinator.Acquire();
        var route = lease.Route;
        bool ready;
        try
        {
            ready = await routeCoordinator.ProbeReadyAsync(route, context.RequestAborted);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            ready = false;
        }

        if (!ready)
        {
            await GatewayErrorWriter.WriteAsync(
                context,
                StatusCodes.Status503ServiceUnavailable,
                "aigw_backend_not_ready",
                "Gateway backend is not ready.");
            return;
        }

        await WriteJsonAsync(
            context,
            StatusCodes.Status200OK,
            new { status = "ready", configurationRevision = route.Configuration.Revision });
    }

    public async Task ModelsAsync(HttpContext context)
    {
        using var lease = routeCoordinator.Acquire();
        var models = lease.Route.Profile.Models.Select(model => new
        {
            id = model.Alias,
            @object = "model",
            created = 0,
            owned_by = "local-ai-gateway",
        }).ToArray();
        await WriteJsonAsync(context, StatusCodes.Status200OK, new { @object = "list", data = models });
    }

    public async Task ProxyAsync(HttpContext context)
    {
        using var lease = routeCoordinator.Acquire();
        var route = lease.Route;
        var rewrite = await route.ModelRewriter.RewriteAsync(context, context.RequestAborted);
        if (!rewrite.IsSuccess)
        {
            await GatewayErrorWriter.WriteAsync(
                context,
                rewrite.StatusCode,
                rewrite.ErrorCode!,
                rewrite.ErrorMessage!);
            return;
        }

        var model = rewrite.Model!;
        if (!route.TryReserveRequestLimits(model, out var requestLimits, out var requestLimitRejection))
        {
            await WriteLimitRejectionAsync(context, requestLimitRejection!);
            return;
        }

        using (requestLimits)
        {
            if (model.RoutingStrategy == ModelRoutingStrategy.WeightedRoundRobin)
            {
                if (!route.TryAcquireWeightedTarget(model, out var target, out var permit, out var retryAfter))
                {
                    await GatewayErrorWriter.WriteAsync(
                        context,
                        StatusCodes.Status503ServiceUnavailable,
                        "aigw_target_circuit_open",
                        "All weighted gateway targets are temporarily unavailable.",
                        retryAfter);
                    return;
                }

                using (permit)
                {
                    if (!route.TryReserveProviderLimits(
                            target!,
                            out var providerLimits,
                            out var providerLimitRejection))
                    {
                        await WriteLimitRejectionAsync(context, providerLimitRejection!);
                        return;
                    }

                    using (providerLimits)
                    {
                        requestLimits.Commit();
                        providerLimits.Commit();
                        await ForwardTargetAsync(
                            context,
                            target!,
                            permit!,
                            requestLimits,
                            providerLimits,
                            captureTransientForFallback: false);
                    }
                }

                return;
            }

            var targets = route.GetTargets(model);
            var attemptedTarget = false;
            TimeSpan? shortestRetryAfter = null;
            for (var targetIndex = 0; targetIndex < targets.Count; targetIndex++)
            {
                var target = targets[targetIndex];
                if (!target.Circuit.TryAcquire(out var circuitPermit, out var retryAfter))
                {
                    if (shortestRetryAfter is null || retryAfter < shortestRetryAfter)
                    {
                        shortestRetryAfter = retryAfter;
                    }

                    continue;
                }

                attemptedTarget = true;
                var mayFallback = targetIndex < targets.Count - 1;
                using (circuitPermit)
                {
                    if (!route.TryReserveProviderLimits(
                            target,
                            out var providerLimits,
                            out var providerLimitRejection))
                    {
                        await WriteLimitRejectionAsync(context, providerLimitRejection!);
                        return;
                    }

                    using (providerLimits)
                    {
                        requestLimits.Commit();
                        providerLimits.Commit();
                        var outcome = await ForwardTargetAsync(
                            context,
                            target,
                            circuitPermit!,
                            requestLimits,
                            providerLimits,
                            captureTransientForFallback: mayFallback);
                        if (outcome != TargetForwardOutcome.TransientBeforeResponse)
                        {
                            return;
                        }
                    }
                }

                await PrepareRetryAsync(context, TimeSpan.Zero);
            }

            await GatewayErrorWriter.WriteAsync(
                context,
                StatusCodes.Status503ServiceUnavailable,
                attemptedTarget ? "aigw_all_targets_unavailable" : "aigw_target_circuit_open",
                attemptedTarget
                    ? "All configured gateway targets are temporarily unavailable."
                    : "The selected gateway target is temporarily unavailable.",
                shortestRetryAfter);
        }
    }

    private static Task WriteLimitRejectionAsync(HttpContext context, GatewayLimitRejection rejection) =>
        GatewayErrorWriter.WriteAsync(
            context,
            StatusCodes.Status429TooManyRequests,
            rejection.ErrorCode,
            rejection.Message,
            rejection.RetryAfter);

    private async Task<TargetForwardOutcome> ForwardTargetAsync(
        HttpContext context,
        GatewayRouteTarget target,
        GatewayCircuitPermit circuitPermit,
        GatewayLimitReservation requestLimits,
        GatewayLimitReservation providerLimits,
        bool captureTransientForFallback)
    {
        for (var attempt = 0; ; attempt++)
        {
            var retryNumber = attempt + 1;
            var forwardingAttempt = new GatewayForwardingAttempt(
                retryNumber <= GatewayRetryPolicy.MaximumRetryCount ? retryNumber : null,
                captureTransientForFallback,
                timeProvider);
            var usageTracker = requestLimits.TracksTokens || providerLimits.TracksTokens
                ? new GatewayResponseUsageTracker(totalTokens =>
                {
                    requestLimits.RecordTokens(totalTokens);
                    providerLimits.RecordTokens(totalTokens);
                })
                : null;
            context.Features.Set<IForwarderErrorFeature>(null);
            var error = await forwarder.SendAsync(
                context,
                target.Backend.BaseAddress.AbsoluteUri,
                httpClient,
                forwarderConfig,
                new GatewayHttpTransformer(target.Backend.InternalToken, forwardingAttempt, usageTracker),
                context.RequestAborted);
            if (context.RequestAborted.IsCancellationRequested)
            {
                return TargetForwardOutcome.Completed;
            }

            if (forwardingAttempt.Delay is TimeSpan responseDelay)
            {
                await PrepareRetryAsync(context, responseDelay);
                continue;
            }

            if (forwardingAttempt.SuppressForFallback)
            {
                circuitPermit.Complete(transientFailure: true);
                return TargetForwardOutcome.TransientBeforeResponse;
            }

            if (error != ForwarderError.None &&
                !context.Response.HasStarted &&
                retryNumber <= GatewayRetryPolicy.MaximumRetryCount &&
                GatewayRetryPolicy.TryGetForwarderRetryDelay(error, retryNumber, out var errorDelay))
            {
                await PrepareRetryAsync(context, errorDelay);
                continue;
            }

            var circuitFailure = ClassifyCircuitOutcome(
                error,
                context.Response.HasStarted,
                forwardingAttempt.ResponseStatusCode);
            if (circuitFailure is bool transientFailure)
            {
                circuitPermit.Complete(transientFailure);
            }

            if (circuitFailure == true && captureTransientForFallback && !context.Response.HasStarted)
            {
                return TargetForwardOutcome.TransientBeforeResponse;
            }

            if (error != ForwarderError.None && !context.Response.HasStarted)
            {
                var gatewayStatusCode = error is ForwarderError.RequestTimedOut or ForwarderError.UpgradeActivityTimeout
                    ? StatusCodes.Status504GatewayTimeout
                    : StatusCodes.Status502BadGateway;
                await GatewayErrorWriter.WriteAsync(
                    context,
                    gatewayStatusCode,
                    "aigw_backend_proxy_failed",
                    "Gateway backend request failed.");
            }

            return TargetForwardOutcome.Completed;
        }
    }

    private enum TargetForwardOutcome
    {
        Completed,
        TransientBeforeResponse,
    }

    private static bool? ClassifyCircuitOutcome(
        ForwarderError error,
        bool responseStarted,
        System.Net.HttpStatusCode? responseStatusCode)
    {
        if (error == ForwarderError.None && responseStatusCode is System.Net.HttpStatusCode statusCode)
        {
            return GatewayRetryPolicy.IsRetryableStatusCode(statusCode);
        }

        if (!responseStarted && GatewayRetryPolicy.IsRetryableForwarderError(error))
        {
            return true;
        }

        return null;
    }

    private static async Task PrepareRetryAsync(HttpContext context, TimeSpan delay)
    {
        if (context.Response.HasStarted)
        {
            throw new InvalidOperationException("A gateway retry cannot start after the response has started.");
        }

        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.Headers.Clear();
        context.Features.Get<IHttpResponseFeature>()!.ReasonPhrase = null;
        if (!context.Request.Body.CanSeek)
        {
            throw new InvalidOperationException("The rewritten gateway request body is not replayable.");
        }

        context.Request.Body.Position = 0;
        if (delay > TimeSpan.Zero)
        {
            await Task.Delay(delay, context.RequestAborted);
        }
    }

    private static Task WriteJsonAsync(HttpContext context, int statusCode, object value)
    {
        context.Response.StatusCode = statusCode;
        context.Response.ContentType = "application/json; charset=utf-8";
        return context.Response.WriteAsync(JsonSerializer.Serialize(value, JsonOptions), context.RequestAborted);
    }
}
