using System.Text.Json;
using LocalAIGateway.ProcessFixture;

namespace LocalAIGateway.Launcher.Tests;

public sealed class ClientProcessRunnerTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-ClientProcess-{Guid.NewGuid():N}");

    [Fact]
    public async Task Runner_uses_no_shell_preserves_arguments_injects_child_environment_and_returns_exit_code()
    {
        Directory.CreateDirectory(testRoot);
        var output = Path.Combine(testRoot, "capture.json");
        var executable = Path.ChangeExtension(
            typeof(ProcessFixtureMarker).Assembly.Location,
            ".exe");
        var unusualArguments = new[]
        {
            "plain",
            "with spaces",
            "quote\"inside",
            "& whoami",
            "$(Get-ChildItem)",
            "ends-with-backslash\\",
            string.Empty,
        };
        var request = new ClientLaunchRequest(
            executable,
            ["capture", output, "37", .. unusualArguments],
            testRoot,
            "AIGW_TEST_BASE_URL",
            "AIGW_TEST_TOKEN");
        const string token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

        var exitCode = await new ClientProcessRunner().RunAsync(
            request,
            GatewayClientLauncher.GatewayBaseUrl,
            token,
            CancellationToken.None);

        Assert.Equal(37, exitCode);
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(output));
        var root = document.RootElement;
        Assert.Equal(unusualArguments, root.GetProperty("arguments").EnumerateArray().Select(value => value.GetString()));
        Assert.Equal(testRoot, root.GetProperty("workingDirectory").GetString());
        Assert.Equal(GatewayClientLauncher.GatewayBaseUrl, root.GetProperty("baseUrl").GetString());
        Assert.Equal(token, root.GetProperty("token").GetString());
        Assert.Null(Environment.GetEnvironmentVariable("AIGW_TEST_TOKEN"));
    }

    [Fact]
    public void Validation_rejects_missing_or_relative_executables_and_malformed_environment_names()
    {
        Directory.CreateDirectory(testRoot);
        var validExecutable = Path.Combine(testRoot, "client.exe");
        File.WriteAllText(validExecutable, "fixture");

        var relative = Assert.Throws<ClientLaunchException>(() => ClientLaunchValidation.Validate(
            new ClientLaunchRequest(
                "client.exe",
                [],
                testRoot,
                "BASE_URL",
                "TOKEN")));
        var malformedEnvironment = Assert.Throws<ClientLaunchException>(() => ClientLaunchValidation.Validate(
            new ClientLaunchRequest(
                validExecutable,
                [],
                testRoot,
                "BASE=URL",
                "TOKEN")));

        Assert.Equal("aigw_launcher_request_invalid", relative.ErrorCode);
        Assert.Equal("aigw_launcher_request_invalid", malformedEnvironment.ErrorCode);
    }

    [Fact]
    public async Task Runner_supports_a_token_only_client_contract()
    {
        Directory.CreateDirectory(testRoot);
        var output = Path.Combine(testRoot, "capture.json");
        var executable = Path.ChangeExtension(
            typeof(ProcessFixtureMarker).Assembly.Location,
            ".exe");
        var request = new ClientLaunchRequest(
            executable,
            ["capture", output, "0"],
            testRoot,
            null,
            "AIGW_TEST_TOKEN");
        const string token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

        var exitCode = await new ClientProcessRunner().RunAsync(
            request,
            GatewayClientLauncher.GatewayBaseUrl,
            token,
            CancellationToken.None);

        Assert.Equal(0, exitCode);
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(output));
        Assert.Null(document.RootElement.GetProperty("baseUrl").GetString());
        Assert.Equal(token, document.RootElement.GetProperty("token").GetString());
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }
}
