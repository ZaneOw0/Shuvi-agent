using System.Text.Json;
using Microsoft.AspNetCore.Http;

namespace LocalAIGateway.Runtime;

internal static class GatewayErrorWriter
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static Task WriteAsync(
        HttpContext context,
        int statusCode,
        string code,
        string message,
        TimeSpan? retryAfter = null)
    {
        context.Response.Clear();
        context.Response.StatusCode = statusCode;
        context.Response.ContentType = "application/json; charset=utf-8";
        if (statusCode == StatusCodes.Status401Unauthorized)
        {
            context.Response.Headers.WWWAuthenticate = "Bearer";
        }

        if (retryAfter is TimeSpan delay)
        {
            var seconds = Math.Max(1, (long)Math.Ceiling(delay.TotalSeconds));
            context.Response.Headers.RetryAfter = seconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        var errorType = statusCode switch
        {
            StatusCodes.Status401Unauthorized => "authentication_error",
            >= StatusCodes.Status500InternalServerError => "server_error",
            _ => "invalid_request_error",
        };
        object body = context.Request.Path.Equals("/v1/messages", StringComparison.OrdinalIgnoreCase)
            ? new
            {
                type = "error",
                error = new
                {
                    type = statusCode >= StatusCodes.Status500InternalServerError ? "api_error" : errorType,
                    code,
                    message,
                },
            }
            : new
            {
                error = new { type = errorType, code, message },
            };
        return context.Response.WriteAsync(JsonSerializer.Serialize(body, JsonOptions), context.RequestAborted);
    }
}
