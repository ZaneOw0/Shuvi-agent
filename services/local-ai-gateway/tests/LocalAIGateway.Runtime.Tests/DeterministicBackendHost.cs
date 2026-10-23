using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Backend;
using LocalAIGateway.Core.Configuration;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace LocalAIGateway.Runtime.Tests;

internal sealed class DeterministicBackendHost : IBackendHost, IAsyncDisposable
{
    private readonly ConcurrentQueue<BackendRequest> requests = new();
    private readonly ConcurrentDictionary<string, int> faultAttempts = new(StringComparer.Ordinal);
    private int prepareCount;
    private int probeCount;
    private int drainCount;
    private int stopCount;
    private int rejectedReadyProbeCount;
    private WebApplication? application;

    public bool IsReady { get; set; } = true;

    public int? ReadyAfterProbeCount { get; init; }

    public string InternalToken { get; } = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));

    public int PrepareCount => Volatile.Read(ref prepareCount);

    public int ProbeCount => Volatile.Read(ref probeCount);

    public int DrainCount => Volatile.Read(ref drainCount);

    public int StopCount => Volatile.Read(ref stopCount);

    public int RejectedReadyProbeCount => Volatile.Read(ref rejectedReadyProbeCount);

    public int RequestCount => requests.Count;

    public IReadOnlyList<BackendRequest> Requests => requests.ToArray();

    public TaskCompletionSource FirstSseEventWritten { get; } =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public TaskCompletionSource ReleaseFinalSseEvent { get; } =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public TaskCompletionSource ReleaseSseDisconnect { get; } =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public TaskCompletionSource FaultRequestReceived { get; } =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public TaskCompletionSource RequestAbortedObserved { get; } =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public async Task<BackendInstance> PrepareAsync(
        ProfileConfiguration profile,
        CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref prepareCount);
        if (application is not null)
        {
            throw new InvalidOperationException("The deterministic backend was prepared twice.");
        }

        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(server =>
        {
            server.AddServerHeader = false;
            server.Listen(IPAddress.Loopback, 0, listen => listen.Protocols = HttpProtocols.Http1);
        });
        application = builder.Build();
        application.MapGet("/ready", async context =>
        {
            if (!string.Equals(
                    context.Request.Headers.Authorization,
                    $"Bearer {InternalToken}",
                    StringComparison.Ordinal))
            {
                Interlocked.Increment(ref rejectedReadyProbeCount);
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                return;
            }

            context.Response.StatusCode = IsReady ? StatusCodes.Status200OK : StatusCodes.Status503ServiceUnavailable;
            await context.Response.WriteAsync(IsReady ? "ready" : "not-ready", context.RequestAborted);
        });
        application.MapPost("/{**path}", HandleRequestAsync);
        await application.StartAsync(cancellationToken);

        var address = application.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()?.Addresses.Single()
            ?? throw new InvalidOperationException("Backend address was not reported.");
        return new BackendInstance(new Uri(address), InternalToken);
    }

    public async Task<bool> ProbeReadyAsync(
        BackendInstance backend,
        CancellationToken cancellationToken = default)
    {
        var currentProbeCount = Interlocked.Increment(ref probeCount);
        if (ReadyAfterProbeCount is int readyAfter && currentProbeCount >= readyAfter)
        {
            IsReady = true;
        }
        using var client = new HttpClient(new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
        });
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(backend.BaseAddress, "/ready"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", backend.InternalToken);
        using var response = await client.SendAsync(request, cancellationToken);
        return response.IsSuccessStatusCode;
    }

    public Task DrainAsync(BackendInstance backend, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref drainCount);
        return Task.CompletedTask;
    }

    public async Task StopAsync(BackendInstance backend, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref stopCount);
        var backendApplication = Interlocked.Exchange(ref application, null);
        if (backendApplication is not null)
        {
            await backendApplication.StopAsync(cancellationToken);
            await backendApplication.DisposeAsync();
        }
    }

    public async ValueTask DisposeAsync()
    {
        var backendApplication = Interlocked.Exchange(ref application, null);
        if (backendApplication is not null)
        {
            await backendApplication.StopAsync();
            await backendApplication.DisposeAsync();
        }
    }

    private async Task HandleRequestAsync(HttpContext context)
    {
        string body;
        using (var reader = new StreamReader(context.Request.Body, Encoding.UTF8))
        {
            body = await reader.ReadToEndAsync(context.RequestAborted);
        }

        var headers = context.Request.Headers.ToDictionary(
            pair => pair.Key,
            pair => pair.Value.ToString(),
            StringComparer.OrdinalIgnoreCase);
        requests.Enqueue(new BackendRequest(context.Request.Path.Value!, headers, body));

        using var document = JsonDocument.Parse(body);
        var fault = document.RootElement.TryGetProperty("test_fault", out var faultProperty) &&
            faultProperty.ValueKind == JsonValueKind.String
                ? faultProperty.GetString()
                : null;
        if (fault is not null)
        {
            FaultRequestReceived.TrySetResult();
            var faultAttempt = faultAttempts.AddOrUpdate(fault, 1, static (_, current) => current + 1);
            if (TryResolveStatusFault(
                    fault,
                    faultAttempt,
                    out var statusCode,
                    out var responseBody,
                    out var retryAfterSeconds))
            {
                if (statusCode is int resolvedStatusCode)
                {
                    context.Response.StatusCode = resolvedStatusCode;
                    context.Response.ContentType = "application/json";
                    if (retryAfterSeconds is int seconds)
                    {
                        context.Response.Headers.RetryAfter = seconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    }

                    await context.Response.WriteAsync(responseBody, context.RequestAborted);
                    return;
                }
            }
            else if (fault == "disconnect-before-headers")
            {
                context.Abort();
                return;
            }
            else if (fault == "wait-for-cancel")
            {
                try
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, context.RequestAborted);
                }
                catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
                {
                    RequestAbortedObserved.TrySetResult();
                }

                return;
            }
            else if (fault == "disconnect-after-sse")
            {
                context.Response.ContentType = "text/event-stream";
                await context.Response.WriteAsync("data: {\"event\":1}\n\n", context.RequestAborted);
                await context.Response.Body.FlushAsync(context.RequestAborted);
                FirstSseEventWritten.TrySetResult();
                await ReleaseSseDisconnect.Task.WaitAsync(context.RequestAborted);
                context.Abort();
                return;
            }
            else
            {
                throw new InvalidOperationException($"Unknown deterministic backend fault '{fault}'.");
            }
        }

        var isStreaming = context.Request.Query.ContainsKey("stream") ||
            (document.RootElement.TryGetProperty("stream", out var streamProperty) &&
             streamProperty.ValueKind == JsonValueKind.True);

        if (isStreaming)
        {
            context.Response.ContentType = "text/event-stream";
            await context.Response.WriteAsync("data: {\"event\":1}\n\n", context.RequestAborted);
            await context.Response.Body.FlushAsync(context.RequestAborted);
            FirstSseEventWritten.TrySetResult();
            await ReleaseFinalSseEvent.Task.WaitAsync(context.RequestAborted);
            await context.Response.WriteAsync("data: [DONE]\n\n", context.RequestAborted);
            await context.Response.Body.FlushAsync(context.RequestAborted);
            return;
        }

        context.Response.ContentType = "application/json";
        context.Response.Headers.SetCookie = "backend-cookie=must-not-leak";
        var model = document.RootElement.GetProperty("model").GetString();
        if (document.RootElement.TryGetProperty("tools", out _))
        {
            var toolPayload = context.Request.Path.Value switch
            {
                "/v1/chat/completions" =>
                    "{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"call_fixed\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Shanghai\\\"}\"}}]}}]}",
                "/v1/responses" =>
                    "{\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_fixed\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Shanghai\\\"}\"}]}",
                "/v1/messages" =>
                    "{\"content\":[{\"type\":\"tool_use\",\"id\":\"call_fixed\",\"name\":\"get_weather\",\"input\":{\"city\":\"Shanghai\"}}]}",
                _ => throw new InvalidOperationException("Unexpected tool endpoint."),
            };
            await context.Response.WriteAsync(toolPayload, context.RequestAborted);
            return;
        }

        await context.Response.WriteAsJsonAsync(
            new { ok = true, path = context.Request.Path.Value, model },
            context.RequestAborted);
    }

    private static bool TryResolveStatusFault(
        string fault,
        int attempt,
        out int? statusCode,
        out string responseBody,
        out int? retryAfterSeconds)
    {
        retryAfterSeconds = null;
        (statusCode, responseBody) = fault switch
        {
            "status-400" => (StatusCodes.Status400BadRequest, "{\"upstream\":\"bad-request\"}"),
            "status-401" => (StatusCodes.Status401Unauthorized, "{\"upstream\":\"unauthorized\"}"),
            "status-403" => (StatusCodes.Status403Forbidden, "{\"upstream\":\"forbidden\"}"),
            "status-429" => (StatusCodes.Status429TooManyRequests, "{\"upstream\":\"rate-limited\"}"),
            "status-500" => (StatusCodes.Status500InternalServerError, "{\"upstream\":\"internal-error\"}"),
            "status-502" => (StatusCodes.Status502BadGateway, "{\"upstream\":\"bad-gateway\"}"),
            "status-503" => (StatusCodes.Status503ServiceUnavailable, "{\"upstream\":\"unavailable\"}"),
            "status-504" => (StatusCodes.Status504GatewayTimeout, "{\"upstream\":\"gateway-timeout\"}"),
            "transient-status-429-once" when attempt == 1 =>
                (StatusCodes.Status429TooManyRequests, "{\"upstream\":\"rate-limited\"}"),
            "transient-status-502-once" when attempt == 1 =>
                (StatusCodes.Status502BadGateway, "{\"upstream\":\"bad-gateway\"}"),
            "transient-status-503-once" when attempt == 1 =>
                (StatusCodes.Status503ServiceUnavailable, "{\"upstream\":\"unavailable\"}"),
            "transient-status-504-once" when attempt == 1 =>
                (StatusCodes.Status504GatewayTimeout, "{\"upstream\":\"gateway-timeout\"}"),
            "transient-status-503-twice" when attempt <= 2 =>
                (StatusCodes.Status503ServiceUnavailable, "{\"upstream\":\"unavailable\"}"),
            "retry-after-429-once" when attempt == 1 =>
                (StatusCodes.Status429TooManyRequests, "{\"upstream\":\"rate-limited\"}"),
            "retry-after-503-too-long" =>
                (StatusCodes.Status503ServiceUnavailable, "{\"upstream\":\"unavailable\"}"),
            "retry-after-503-cancel" =>
                (StatusCodes.Status503ServiceUnavailable, "{\"upstream\":\"unavailable\"}"),
            "transient-status-429-once" or
            "transient-status-502-once" or
            "transient-status-503-once" or
            "transient-status-504-once" or
            "transient-status-503-twice" or
            "retry-after-429-once" => ((int?)null, string.Empty),
            _ => ((int?)null, string.Empty),
        };
        retryAfterSeconds = fault switch
        {
            "retry-after-429-once" when attempt == 1 => 1,
            "retry-after-503-too-long" => 61,
            "retry-after-503-cancel" => 5,
            _ => null,
        };
        return statusCode is not null || fault.StartsWith("transient-status-", StringComparison.Ordinal) ||
            fault == "retry-after-429-once" ||
            fault == "retry-after-503-too-long" ||
            fault == "retry-after-503-cancel";
    }
}

internal sealed record BackendRequest(
    string Path,
    IReadOnlyDictionary<string, string> Headers,
    string Body);
