using System.Text.Json;

namespace LocalAIGateway.Cli.Tests;

public sealed class HelpCommandTests
{
    [Fact]
    public async Task Install_help_surfaces_the_autostart_choice()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["install", "--lang", "en", "--help"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Contains("--autostart <enable|disable>", output.ToString(), StringComparison.Ordinal);
        Assert.Contains("user PATH", output.ToString(), StringComparison.Ordinal);
        Assert.Contains("Tray Start Menu shortcut", output.ToString(), StringComparison.Ordinal);
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task EnglishHelpListsStableGlobalOptions()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--lang", "en", "--help", "--no-color"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Contains("Usage:", output.ToString());
        Assert.Contains("--json", output.ToString());
        Assert.Contains("--verbose", output.ToString());
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task ChineseHelpIsLocalized()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--lang", "zh-CN", "--help"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Contains("用法：", output.ToString());
        Assert.Contains("显示版本。", output.ToString());
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task NoArgumentsShowsHelp()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync([], output, error);

        Assert.Equal(0, exitCode);
        Assert.Contains("Local AI Gateway", output.ToString());
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task JsonHelpUsesStableEnvelope()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["--json", "--help"],
            output,
            error);

        Assert.Equal(0, exitCode);
        using var document = JsonDocument.Parse(output.ToString());
        var root = document.RootElement;
        Assert.Equal(1, root.GetProperty("schemaVersion").GetInt32());
        Assert.True(root.GetProperty("ok").GetBoolean());
        Assert.Equal("help", root.GetProperty("command").GetString());
        Assert.Equal("aigw [options]", root.GetProperty("data").GetProperty("usage").GetString());
        Assert.Equal(
            ["profile", "provider", "model", "limits", "config", "install", "uninstall", "start", "stop", "restart", "status", "doctor", "autostart", "run", "integrate", "usage", "backup", "update"],
            root.GetProperty("data").GetProperty("commands").EnumerateArray().Select(item => item.GetString()));
        Assert.Equal(string.Empty, error.ToString());
    }

    [Theory]
    [InlineData("limits", "aigw limits <command> [options]", "profile", "provider", "model")]
    [InlineData("limits profile", "aigw limits profile <command> [options]", "set", "clear", null)]
    [InlineData("update", "aigw update <command> [options]", "inspect", "apply", null)]
    [InlineData("run", "aigw run --client", "claude", "codex", null)]
    public async Task GroupHelpListsItsOwnSubcommands(
        string commandPath,
        string usage,
        string firstSubcommand,
        string secondSubcommand,
        string? thirdSubcommand)
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            [.. commandPath.Split(' '), "--lang", "en", "--help"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Contains(usage, output.ToString(), StringComparison.Ordinal);
        Assert.Contains("Subcommands:", output.ToString(), StringComparison.Ordinal);
        Assert.Contains($"  {firstSubcommand}{Environment.NewLine}", output.ToString(), StringComparison.Ordinal);
        Assert.Contains($"  {secondSubcommand}{Environment.NewLine}", output.ToString(), StringComparison.Ordinal);
        if (thirdSubcommand is not null)
        {
            Assert.Contains($"  {thirdSubcommand}{Environment.NewLine}", output.ToString(), StringComparison.Ordinal);
        }
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task LeafHelpListsRegisteredCommandOptions()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["update", "apply", "--lang", "en", "--help"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Contains("aigw update apply [options]", output.ToString(), StringComparison.Ordinal);
        Assert.Contains("--expected-manifest-sha256", output.ToString(), StringComparison.Ordinal);
        Assert.Contains("Candidate manifest SHA-256 returned by update inspect. (required)", output.ToString(), StringComparison.Ordinal);
        Assert.Contains("--allow-unsigned-development", output.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("Subcommands:", output.ToString(), StringComparison.Ordinal);
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task NestedJsonHelpExposesSelectedSubcommandsAndOptions()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["limits", "profile", "--json", "--help"],
            output,
            error);

        Assert.Equal(0, exitCode);
        using var document = JsonDocument.Parse(output.ToString());
        var data = document.RootElement.GetProperty("data");
        Assert.Equal("aigw limits profile <command> [options]", data.GetProperty("usage").GetString());
        Assert.Equal(
            ["set", "clear"],
            data.GetProperty("subcommands").EnumerateArray().Select(item => item.GetString()));
        Assert.Empty(data.GetProperty("options").EnumerateArray());
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task EveryRegisteredCommandHasReachableJsonHelp()
    {
        var pending = new Queue<string[]>();
        pending.Enqueue([]);
        var visited = new HashSet<string>(StringComparer.Ordinal);

        while (pending.TryDequeue(out var path))
        {
            Assert.True(path.Length < 6, "The help command tree is unexpectedly deep.");
            Assert.True(visited.Count < 200, "The help command tree is unexpectedly large.");
            using var output = new StringWriter();
            using var error = new StringWriter();
            var exitCode = await CliApplication.RunAsync(
                [.. path, "--json", "--help"],
                output,
                error);

            Assert.Equal(0, exitCode);
            Assert.Equal(string.Empty, error.ToString());
            using var document = JsonDocument.Parse(output.ToString());
            var data = document.RootElement.GetProperty("data");
            Assert.True(document.RootElement.GetProperty("ok").GetBoolean());
            Assert.Contains($"aigw {string.Join(' ', path)}".TrimEnd(), data.GetProperty("usage").GetString(), StringComparison.Ordinal);
            Assert.True(visited.Add(string.Join(' ', path)));

            foreach (var subcommand in data.GetProperty("subcommands").EnumerateArray())
            {
                pending.Enqueue([.. path, subcommand.GetString()!]);
            }
        }

        Assert.True(visited.Count > 50, $"Only {visited.Count} help paths were visited.");
    }

    [Fact]
    public async Task LeafHelpDoesNotRequireOperationalArguments()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["provider", "add", "--lang", "en", "--help"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Contains("aigw provider add --profile <id>", output.ToString(), StringComparison.Ordinal);
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task Uninstall_help_surfaces_explicit_category_contract()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["uninstall", "--lang", "en", "--help"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Contains("--program <keep|remove>", output.ToString(), StringComparison.Ordinal);
        Assert.Contains("--backups <keep|remove>", output.ToString(), StringComparison.Ordinal);
        Assert.Contains("--confirm UNINSTALL", output.ToString(), StringComparison.Ordinal);
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task RecursiveVersionDoesNotRequireOperationalArguments()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await CliApplication.RunAsync(
            ["provider", "add", "--version"],
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.StartsWith("Local AI Gateway ", output.ToString(), StringComparison.Ordinal);
        Assert.Equal(string.Empty, error.ToString());
    }
}
