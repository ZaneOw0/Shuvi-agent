using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.Core.Tests;

public sealed class RuntimeClientTokenGeneratorTests
{
    [Fact]
    public void Generate_returns_256_bit_lowercase_hex_tokens()
    {
        var tokens = Enumerable.Range(0, 64)
            .Select(_ => RuntimeClientTokenGenerator.Generate())
            .ToArray();

        Assert.All(tokens, token =>
        {
            Assert.Equal(64, token.Length);
            Assert.All(token, character => Assert.True(
                character is >= '0' and <= '9' or >= 'a' and <= 'f'));
        });
        Assert.Equal(tokens.Length, tokens.Distinct(StringComparer.Ordinal).Count());
    }

    [Theory]
    [InlineData("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", true)]
    [InlineData("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF", false)]
    [InlineData("short", false)]
    [InlineData("", false)]
    public void IsGeneratedFormat_recognizes_only_the_install_token_format(string token, bool expected)
    {
        Assert.Equal(expected, RuntimeClientTokenGenerator.IsGeneratedFormat(token));
    }
}
