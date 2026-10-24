using System.Net;
using System.Net.Http.Headers;
using Yarp.ReverseProxy.Forwarder;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayRetryPolicyTests
{
    [Theory]
    [InlineData(HttpStatusCode.TooManyRequests)]
    [InlineData(HttpStatusCode.BadGateway)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    [InlineData(HttpStatusCode.GatewayTimeout)]
    public void Retryable_status_without_header_uses_bounded_exponential_delay(HttpStatusCode statusCode)
    {
        using var response = new HttpResponseMessage(statusCode);

        Assert.True(GatewayRetryPolicy.TryGetResponseRetryDelay(
            response,
            retryNumber: 1,
            DateTimeOffset.UnixEpoch,
            out var firstDelay));
        Assert.True(GatewayRetryPolicy.TryGetResponseRetryDelay(
            response,
            retryNumber: 2,
            DateTimeOffset.UnixEpoch,
            out var secondDelay));

        Assert.Equal(TimeSpan.FromMilliseconds(100), firstDelay);
        Assert.Equal(TimeSpan.FromMilliseconds(200), secondDelay);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.InternalServerError)]
    public void Non_retryable_status_is_rejected(HttpStatusCode statusCode)
    {
        using var response = new HttpResponseMessage(statusCode);

        Assert.False(GatewayRetryPolicy.TryGetResponseRetryDelay(
            response,
            retryNumber: 1,
            DateTimeOffset.UnixEpoch,
            out _));
    }

    [Fact]
    public void Retry_after_delta_is_used_exactly()
    {
        using var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
        response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromSeconds(7));

        Assert.True(GatewayRetryPolicy.TryGetResponseRetryDelay(
            response,
            retryNumber: 1,
            DateTimeOffset.UnixEpoch,
            out var delay));

        Assert.Equal(TimeSpan.FromSeconds(7), delay);
    }

    [Fact]
    public void Retry_after_date_is_resolved_against_current_utc_time()
    {
        var now = DateTimeOffset.Parse("2026-09-15T10:00:00Z");
        using var response = new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        response.Headers.RetryAfter = new RetryConditionHeaderValue(now.AddSeconds(9));

        Assert.True(GatewayRetryPolicy.TryGetResponseRetryDelay(response, 1, now, out var delay));

        Assert.Equal(TimeSpan.FromSeconds(9), delay);
    }

    [Fact]
    public void Retry_after_beyond_bound_preserves_response_without_retrying_early()
    {
        using var response = new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromSeconds(61));

        Assert.False(GatewayRetryPolicy.TryGetResponseRetryDelay(
            response,
            retryNumber: 1,
            DateTimeOffset.UnixEpoch,
            out _));
    }

    [Theory]
    [InlineData(ForwarderError.Request, true)]
    [InlineData(ForwarderError.RequestTimedOut, true)]
    [InlineData(ForwarderError.RequestCanceled, false)]
    [InlineData(ForwarderError.RequestBodyClient, false)]
    [InlineData(ForwarderError.RequestBodyDestination, false)]
    [InlineData(ForwarderError.ResponseHeaders, false)]
    [InlineData(ForwarderError.ResponseBodyDestination, false)]
    public void Only_pre_response_request_or_timeout_forwarder_errors_retry(
        ForwarderError error,
        bool expected)
    {
        Assert.Equal(expected, GatewayRetryPolicy.TryGetForwarderRetryDelay(error, 1, out _));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    public void Invalid_retry_number_is_rejected(int retryNumber)
    {
        using var response = new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);

        Assert.Throws<ArgumentOutOfRangeException>(() =>
            GatewayRetryPolicy.TryGetResponseRetryDelay(
                response,
                retryNumber,
                DateTimeOffset.UnixEpoch,
                out _));
    }
}
