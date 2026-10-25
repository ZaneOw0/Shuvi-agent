using System.Text.Json;
using System.Text.Json.Nodes;
using LocalAIGateway.Core.Configuration;
using Microsoft.AspNetCore.Http;

namespace LocalAIGateway.Runtime;

internal sealed class ModelRequestRewriter
{
    private static readonly StringComparer AliasComparer = StringComparer.OrdinalIgnoreCase;
    private readonly IReadOnlyDictionary<string, ModelConfiguration> models;
    private readonly IReadOnlySet<string> tokenLimitedProviders;
    private readonly bool profileTokenLimited;
    private readonly long maxRequestBodyBytes;

    public ModelRequestRewriter(ProfileConfiguration profile, long maxRequestBodyBytes)
    {
        models = profile.Models.ToDictionary(model => model.Alias, AliasComparer);
        tokenLimitedProviders = profile.Providers
            .Where(provider => provider.Limits?.TokensPerMinute is not null)
            .Select(provider => provider.Id)
            .ToHashSet(AliasComparer);
        profileTokenLimited = profile.Limits?.TokensPerMinute is not null;
        this.maxRequestBodyBytes = maxRequestBodyBytes;
    }

    public async Task<ModelRewriteResult> RewriteAsync(
        HttpContext context,
        CancellationToken cancellationToken)
    {
        if (context.Request.ContentLength is > 0 && context.Request.ContentLength > maxRequestBodyBytes)
        {
            return ModelRewriteResult.Failure(
                StatusCodes.Status413PayloadTooLarge,
                "aigw_request_too_large",
                "Request body exceeds the gateway limit.");
        }

        if (!context.Request.HasJsonContentType())
        {
            return ModelRewriteResult.Failure(
                StatusCodes.Status415UnsupportedMediaType,
                "aigw_request_content_type_invalid",
                "Request content type must be application/json.");
        }

        byte[] bytes;
        try
        {
            await using var buffer = new MemoryStream();
            var chunk = new byte[16 * 1024];
            while (true)
            {
                var read = await context.Request.Body.ReadAsync(chunk, cancellationToken);
                if (read == 0)
                {
                    break;
                }

                if (buffer.Length + read > maxRequestBodyBytes)
                {
                    return ModelRewriteResult.Failure(
                        StatusCodes.Status413PayloadTooLarge,
                        "aigw_request_too_large",
                        "Request body exceeds the gateway limit.");
                }

                await buffer.WriteAsync(chunk.AsMemory(0, read), cancellationToken);
            }

            bytes = buffer.ToArray();
        }
        catch (BadHttpRequestException)
        {
            return ModelRewriteResult.Failure(
                StatusCodes.Status400BadRequest,
                "aigw_request_body_invalid",
                "Request body could not be read.");
        }

        JsonObject body;
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64,
            });
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                document.RootElement.EnumerateObject().Count(property => property.NameEquals("model")) != 1)
            {
                return ModelRewriteResult.Failure(
                    StatusCodes.Status400BadRequest,
                    "aigw_model_required",
                    "Request must contain exactly one model field.");
            }

            body = JsonNode.Parse(bytes, documentOptions: new JsonDocumentOptions { MaxDepth = 64 }) as JsonObject
                ?? throw new JsonException("Request body must be an object.");
        }
        catch (JsonException)
        {
            return ModelRewriteResult.Failure(
                StatusCodes.Status400BadRequest,
                "aigw_request_json_invalid",
                "Request body must be valid JSON.");
        }

        if (body["model"] is not JsonValue modelValue ||
            !modelValue.TryGetValue<string>(out var alias) ||
            string.IsNullOrWhiteSpace(alias))
        {
            return ModelRewriteResult.Failure(
                StatusCodes.Status400BadRequest,
                "aigw_model_required",
                "Request model must be a non-empty string.");
        }

        if (!models.TryGetValue(alias, out var model))
        {
            return ModelRewriteResult.Failure(
                StatusCodes.Status400BadRequest,
                "aigw_model_unknown",
                "Requested model alias is not configured in the active profile.");
        }

        body["model"] = model.Alias;
        if (RequiresTokenUsage(model) &&
            context.Request.Path.Equals("/v1/chat/completions", StringComparison.OrdinalIgnoreCase) &&
            body["stream"] is JsonValue streamValue &&
            streamValue.TryGetValue<bool>(out var streaming) &&
            streaming)
        {
            var streamOptions = body["stream_options"] as JsonObject ?? new JsonObject();
            streamOptions["include_usage"] = true;
            body["stream_options"] = streamOptions;
        }

        var rewrittenBytes = JsonSerializer.SerializeToUtf8Bytes(body);
        var stream = new MemoryStream(rewrittenBytes, writable: false);
        context.Response.RegisterForDispose(stream);
        context.Request.Body = stream;
        context.Request.ContentLength = rewrittenBytes.Length;
        context.Request.ContentType = "application/json";
        return ModelRewriteResult.Success(model);
    }

    private bool RequiresTokenUsage(ModelConfiguration model) =>
        profileTokenLimited ||
        model.Limits?.TokensPerMinute is not null ||
        tokenLimitedProviders.Contains(model.ProviderId) ||
        model.Fallbacks.Any(fallback => tokenLimitedProviders.Contains(fallback.ProviderId));
}

internal sealed record ModelRewriteResult(
    bool IsSuccess,
    ModelConfiguration? Model,
    int StatusCode,
    string? ErrorCode,
    string? ErrorMessage)
{
    public static ModelRewriteResult Success(ModelConfiguration model) =>
        new(true, model, StatusCodes.Status200OK, null, null);

    public static ModelRewriteResult Failure(int statusCode, string code, string message) =>
        new(false, null, statusCode, code, message);
}
