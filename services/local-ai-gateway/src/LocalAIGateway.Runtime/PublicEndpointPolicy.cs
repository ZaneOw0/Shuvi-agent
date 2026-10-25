using Microsoft.AspNetCore.Http;

namespace LocalAIGateway.Runtime;

internal static class PublicEndpointPolicy
{
    private static readonly IReadOnlyDictionary<string, string> AllowedEndpoints =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["/health"] = HttpMethods.Get,
            ["/ready"] = HttpMethods.Get,
            ["/v1/models"] = HttpMethods.Get,
            ["/v1/chat/completions"] = HttpMethods.Post,
            ["/v1/responses"] = HttpMethods.Post,
            ["/v1/messages"] = HttpMethods.Post,
        };

    public static async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        if (!AllowedEndpoints.TryGetValue(context.Request.Path.Value ?? string.Empty, out var method))
        {
            context.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }

        if (!string.Equals(context.Request.Method, method, StringComparison.OrdinalIgnoreCase))
        {
            context.Response.StatusCode = StatusCodes.Status405MethodNotAllowed;
            context.Response.Headers.Allow = method;
            return;
        }

        await next(context);
    }
}
