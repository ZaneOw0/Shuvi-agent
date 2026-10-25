using System.Net.Http.Headers;
using Microsoft.AspNetCore.Http;
using Yarp.ReverseProxy.Forwarder;

namespace LocalAIGateway.Runtime;

internal sealed class GatewayHttpTransformer(
    string internalToken,
    GatewayForwardingAttempt? forwardingAttempt = null,
    GatewayResponseUsageTracker? usageTracker = null) : HttpTransformer
{
    private static readonly string[] RemovedRequestHeaders =
    [
        "Authorization",
        "x-api-key",
        "Cookie",
        "Proxy-Authorization",
        "X-Forwarded-For",
        "X-Forwarded-Host",
        "X-Forwarded-Proto",
    ];

    public override async ValueTask TransformRequestAsync(
        HttpContext httpContext,
        HttpRequestMessage proxyRequest,
        string destinationPrefix,
        CancellationToken cancellationToken)
    {
        await base.TransformRequestAsync(httpContext, proxyRequest, destinationPrefix, cancellationToken);
        foreach (var header in RemovedRequestHeaders)
        {
            proxyRequest.Headers.Remove(header);
        }

        var forwardedHeaders = proxyRequest.Headers
            .Select(header => header.Key)
            .Where(header =>
                header.Equals("Forwarded", StringComparison.OrdinalIgnoreCase) ||
                header.Equals("X-Real-IP", StringComparison.OrdinalIgnoreCase) ||
                header.StartsWith("X-Forwarded-", StringComparison.OrdinalIgnoreCase))
            .ToArray();
        foreach (var header in forwardedHeaders)
        {
            proxyRequest.Headers.Remove(header);
        }

        proxyRequest.Headers.Host = null;
        proxyRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", internalToken);
    }

    public override async ValueTask<bool> TransformResponseAsync(
        HttpContext httpContext,
        HttpResponseMessage? proxyResponse,
        CancellationToken cancellationToken)
    {
        if (proxyResponse is not null && forwardingAttempt?.TryCapture(proxyResponse) == true)
        {
            return false;
        }

        if (proxyResponse?.Content is HttpContent content && usageTracker is not null)
        {
            proxyResponse.Content = new GatewayUsageTrackingContent(content, usageTracker);
        }

        var copyBody = await base.TransformResponseAsync(httpContext, proxyResponse, cancellationToken);
        httpContext.Response.Headers.Remove("Server");
        httpContext.Response.Headers.Remove("Set-Cookie");
        return copyBody;
    }
}

internal sealed class GatewayForwardingAttempt(
    int? retryNumber,
    bool captureTerminalTransient,
    TimeProvider timeProvider)
{
    public System.Net.HttpStatusCode? ResponseStatusCode { get; private set; }

    public TimeSpan? Delay { get; private set; }

    public bool SuppressForFallback { get; private set; }

    public bool TryCapture(HttpResponseMessage response)
    {
        ResponseStatusCode = response.StatusCode;
        if (retryNumber is not int currentRetryNumber ||
            !GatewayRetryPolicy.TryGetResponseRetryDelay(
                response,
                currentRetryNumber,
                timeProvider.GetUtcNow(),
                out var delay))
        {
            if (captureTerminalTransient && GatewayRetryPolicy.IsRetryableStatusCode(response.StatusCode))
            {
                SuppressForFallback = true;
                return true;
            }

            return false;
        }

        Delay = delay;
        return true;
    }
}
