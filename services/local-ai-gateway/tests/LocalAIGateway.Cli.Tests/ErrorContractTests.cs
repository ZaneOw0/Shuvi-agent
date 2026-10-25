using System.Text;
using System.Text.Json;

namespace LocalAIGateway.Cli.Tests;

public sealed class ErrorContractTests
{
    [Fact]
    public async Task UnknownArgumentReturnsExitCodeTwo()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--lang", "en", "--unknown"],
            output,
            error);

        Assert.Equal(2, exitCode);
        Assert.Equal(string.Empty, output.ToString());
        Assert.Contains("Invalid command-line arguments", error.ToString());
    }

    [Fact]
    public async Task JsonArgumentErrorUsesStableMachineContract()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--json", "--unknown"],
            output,
            error);

        Assert.Equal(2, exitCode);
        Assert.Equal(string.Empty, output.ToString());
        using var document = JsonDocument.Parse(error.ToString());
        var root = document.RootElement;
        Assert.Equal(1, root.GetProperty("schemaVersion").GetInt32());
        Assert.False(root.GetProperty("ok").GetBoolean());
        Assert.Equal("aigw_invalid_arguments", root.GetProperty("error").GetProperty("code").GetString());
        Assert.Equal(0, root.GetProperty("error").GetProperty("details").GetArrayLength());
    }

    [Fact]
    public async Task VerboseJsonArgumentErrorIncludesParserDetails()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--json", "--verbose", "--unknown"],
            output,
            error);

        Assert.Equal(2, exitCode);
        using var document = JsonDocument.Parse(error.ToString());
        Assert.NotEqual(
            0,
            document.RootElement.GetProperty("error").GetProperty("details").GetArrayLength());
    }

    [Fact]
    public async Task ConflictingModesReturnExitCodeTwo()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--help", "--version"],
            output,
            error);

        Assert.Equal(2, exitCode);
        Assert.Equal(string.Empty, output.ToString());
        Assert.NotEqual(string.Empty, error.ToString());
    }

    [Fact]
    public async Task UnexpectedWriterFailureReturnsExitCodeSeventy()
    {
        using var output = new ThrowingTextWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--lang", "en", "--version"],
            output,
            error);

        Assert.Equal(70, exitCode);
        Assert.Contains("unexpected internal error", error.ToString());
    }

    private sealed class ThrowingTextWriter : TextWriter
    {
        public override Encoding Encoding => Encoding.UTF8;

        public override Task WriteLineAsync(string? value) =>
            throw new IOException("Synthetic writer failure.");
    }
}
