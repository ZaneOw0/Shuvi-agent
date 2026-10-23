using System.Net;
using System.Net.Http.Headers;
using Yarp.ReverseProxy.Forwarder;

namespace LocalAIGateway.Runtime;

internal static class GatewayRetryPolicy
{
    public const int MaximumRetryCount = 2;

    private static readonly TimeSpan BaseDelay = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan MaximumRetryAfterDelay = TimeSpan.FromSeconds(60);

    public static bool TryGetResponseRetryDelay(
        HttpResponseMessage response,
        int retryNumber,
        DateTimeOffset utcNow,
        out TimeSpan delay)
    {
        ArgumentNullException.ThrowIfNull(response);
        ValidateRetryNumber(retryNumber);

        if (!IsRetryableStatusCode(response.StatusCode))
        {
            delay = default;
            return false;
        }

        var retryAfter = response.Headers.RetryAfter;
        if (retryAfter is null)
        {
            delay = Backoff(retryNumber);
            return true;
        }

        delay = ResolveRetryAfter(retryAfter, utcNow);
        return delay <= MaximumRetryAfterDelay;
    }

    public static bool TryGetForwarderRetryDelay(
        ForwarderError error,
        int retryNumber,
        out TimeSpan delay)
    {
        ValidateRetryNumber(retryNumber);
        if (!IsRetryableForwarderError(error))
        {
            delay = default;
            return false;
        }

        delay = Backoff(retryNumber);
        return true;
    }

    public static bool IsRetryableStatusCode(HttpStatusCode statusCode) => statusCode is
        HttpStatusCode.TooManyRequests or
        HttpStatusCode.BadGateway or
        HttpStatusCode.ServiceUnavailable or
        HttpStatusCode.GatewayTimeout;

    public static bool IsRetryableForwarderError(ForwarderError error) => error is
        ForwarderError.Request or ForwarderError.RequestTimedOut;

    private static TimeSpan ResolveRetryAfter(RetryConditionHeaderValue retryAfter, DateTimeOffset utcNow)
    {
        if (retryAfter.Delta is TimeSpan delta)
        {
            return delta < TimeSpan.Zero ? TimeSpan.Zero : delta;
        }

        if (retryAfter.Date is DateTimeOffset date)
        {
            var delay = date - utcNow;
            return delay < TimeSpan.Zero ? TimeSpan.Zero : delay;
        }

        return TimeSpan.Zero;
    }

    private static TimeSpan Backoff(int retryNumber) =>
        TimeSpan.FromTicks(BaseDelay.Ticks * (1L << (retryNumber - 1)));

    private static void ValidateRetryNumber(int retryNumber)
    {
        if (retryNumber is < 1 or > MaximumRetryCount)
        {
            throw new ArgumentOutOfRangeException(nameof(retryNumber));
        }
    }
}
