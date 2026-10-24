namespace LocalAIGateway.Launcher.Tests;

public sealed class LauncherArgumentsTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-LauncherArguments-{Guid.NewGuid():N}");

    [Fact]
    public void Parse_requires_explicit_environment_names_and_preserves_all_client_arguments_after_separator()
    {
        Directory.CreateDirectory(testRoot);
        var executable = Path.Combine(testRoot, "client.exe");
        File.WriteAllText(executable, "fixture");

        var parsed = LauncherArguments.Parse([
            "--client", executable,
            "--base-url-env", "OPENAI_BASE_URL",
            "--token-env", "OPENAI_API_KEY",
            "--working-directory", testRoot,
            "--",
            "--model", "aigw/default", "value with spaces",
        ]);

        Assert.Equal(executable, parsed.Request.ExecutablePath);
        Assert.Equal(["--model", "aigw/default", "value with spaces"], parsed.Request.Arguments);
        Assert.Equal(testRoot, parsed.Request.WorkingDirectory);
    }

    [Theory]
    [InlineData()]
    [InlineData("--client", "client.exe")]
    [InlineData("--token-env", "TOKEN", "--", "arg")]
    [InlineData("--unknown", "value", "--")]
    public void Parse_rejects_incomplete_duplicate_or_unknown_launcher_options(params string[] args)
    {
        var failure = Assert.Throws<ClientLaunchException>(() => LauncherArguments.Parse(args));

        Assert.Equal("aigw_launcher_arguments_invalid", failure.ErrorCode);
    }

    [Fact]
    public void Parse_accepts_the_official_claude_vscode_wrapper_invocation_shape()
    {
        var executable = Path.GetFullPath("bundled-claude.exe");

        var parsed = LauncherArguments.Parse(
            [executable, "--print", "value with spaces"]);

        Assert.Equal(executable, parsed.Request.ExecutablePath);
        Assert.Equal(
            ["--model", "aigw/default", "--print", "value with spaces"],
            parsed.Request.Arguments);
        Assert.Equal("ANTHROPIC_BASE_URL", parsed.Request.BaseUrlEnvironmentVariable);
        Assert.Equal("ANTHROPIC_AUTH_TOKEN", parsed.Request.TokenEnvironmentVariable);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }
}
