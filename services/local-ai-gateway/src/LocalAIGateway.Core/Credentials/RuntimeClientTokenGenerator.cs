using System.Security.Cryptography;

namespace LocalAIGateway.Core.Credentials;

public static class RuntimeClientTokenGenerator
{
    public const int EntropyBytes = 32;
    public const int EncodedLength = EntropyBytes * 2;

    public static string Generate()
    {
        Span<byte> entropy = stackalloc byte[EntropyBytes];
        try
        {
            RandomNumberGenerator.Fill(entropy);
            return Convert.ToHexStringLower(entropy);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(entropy);
        }
    }

    public static bool IsGeneratedFormat(string? token) =>
        token is { Length: EncodedLength } &&
        token.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');
}
