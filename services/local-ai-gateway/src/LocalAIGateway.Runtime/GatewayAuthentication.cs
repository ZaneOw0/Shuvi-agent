using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Primitives;

namespace LocalAIGateway.Runtime;

internal sealed class GatewayAuthentication
{
    private readonly byte[] expectedToken;

    public GatewayAuthentication(string token)
    {
        if (string.IsNullOrWhiteSpace(token) || token.Length > 1024 || token.Any(char.IsControl))
        {
            throw new RuntimeGatewayException(
                "aigw_runtime_client_token_invalid",
                "The local client token is missing or malformed.");
        }

        expectedToken = Encoding.UTF8.GetBytes(token);
    }

    public bool Authenticate(HttpRequest request)
    {
        var bearerPresent = request.Headers.ContainsKey("Authorization");
        var apiKeyPresent = request.Headers.ContainsKey("x-api-key");
        var bearer = ReadBearer(request.Headers.Authorization);
        var apiKey = ReadSingle(request.Headers["x-api-key"]);
        try
        {
            if ((bearerPresent && bearer is null) ||
                (apiKeyPresent && apiKey is null) ||
                (!bearerPresent && !apiKeyPresent))
            {
                return false;
            }

            if (bearer is not null && apiKey is not null && !FixedTimeEquals(bearer, apiKey))
            {
                return false;
            }

            return FixedTimeEquals(bearer ?? apiKey!, expectedToken);
        }
        finally
        {
            if (bearer is not null)
            {
                CryptographicOperations.ZeroMemory(bearer);
            }

            if (apiKey is not null)
            {
                CryptographicOperations.ZeroMemory(apiKey);
            }
        }
    }

    private static byte[]? ReadBearer(StringValues values)
    {
        var value = ReadSingle(values);
        if (value is null)
        {
            return null;
        }

        const string prefix = "Bearer ";
        var text = Encoding.UTF8.GetString(value);
        if (!text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            CryptographicOperations.ZeroMemory(value);
            return null;
        }

        var token = Encoding.UTF8.GetBytes(text[prefix.Length..]);
        CryptographicOperations.ZeroMemory(value);
        return token.Length == 0 ? null : token;
    }

    private static byte[]? ReadSingle(StringValues values)
    {
        if (values.Count != 1)
        {
            return null;
        }

        var value = values[0];
        if (string.IsNullOrWhiteSpace(value) || value.Contains(',', StringComparison.Ordinal))
        {
            return null;
        }

        return Encoding.UTF8.GetBytes(value);
    }

    private static bool FixedTimeEquals(byte[] left, byte[] right)
        => left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);
}
