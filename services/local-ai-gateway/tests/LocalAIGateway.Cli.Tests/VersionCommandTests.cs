using System.Text.Json;

namespace LocalAIGateway.Cli.Tests;

public sealed class VersionCommandTests
{
    [Fact]
    public async Task HumanVersionIsAvailable()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--version"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.StartsWith("Local AI Gateway 0.1.0-dev", output.ToString());
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task JsonVersionUsesStableEnvelope()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--json", "--version"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Equal(string.Empty, error.ToString());

        using var document = JsonDocument.Parse(output.ToString());
        var root = document.RootElement;
        Assert.Equal(1, root.GetProperty("schemaVersion").GetInt32());
        Assert.True(root.GetProperty("ok").GetBoolean());
        Assert.Equal("version", root.GetProperty("command").GetString());
        Assert.Equal(
            "Local AI Gateway",
            root.GetProperty("data").GetProperty("product").GetString());
        Assert.False(string.IsNullOrWhiteSpace(
            root.GetProperty("data").GetProperty("version").GetString()));
    }
}
