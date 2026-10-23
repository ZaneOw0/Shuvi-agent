namespace LocalAIGateway.Launcher.Tests;

public sealed class ClientLaunchRequestFactoryTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-ClientAdapter-{Guid.NewGuid():N}");

    [Fact]
    public void Claude_adapter_uses_the_official_process_environment_contract_and_fixed_alias()
    {
        var executable = CreateExecutable("claude.exe");
        var factory = new ClientLaunchRequestFactory(
            new TestResolver(ClientKind.Claude, executable));

        var request = factory.CreateKnown(
            ClientKind.Claude,
            ["--print", "value with spaces"],
            testRoot);

        Assert.Equal(executable, request.ExecutablePath);
        Assert.Equal(
            ["--model", ClientLaunchRequestFactory.ClaudeModelAlias, "--print", "value with spaces"],
            request.Arguments);
        Assert.Equal("ANTHROPIC_BASE_URL", request.BaseUrlEnvironmentVariable);
        Assert.Equal("ANTHROPIC_AUTH_TOKEN", request.TokenEnvironmentVariable);
    }

    [Fact]
    public void Codex_adapter_uses_a_one_shot_responses_provider_without_a_config_file()
    {
        var executable = CreateExecutable("codex.exe");
        var factory = new ClientLaunchRequestFactory(
            new TestResolver(ClientKind.Codex, executable));

        var request = factory.CreateKnown(
            ClientKind.Codex,
            ["exec", "value with spaces"],
            testRoot);

        Assert.Equal(executable, request.ExecutablePath);
        Assert.Equal(
            [
                "--model", "aigw/codex/default",
                "--config", "model_provider=\"aigw\"",
                "--config", "model_providers.aigw.name=\"Local AI Gateway\"",
                "--config", "model_providers.aigw.base_url=\"http://127.0.0.1:4000/v1\"",
                "--config", "model_providers.aigw.env_key=\"AIGW_CODEX_API_KEY\"",
                "--config", "model_providers.aigw.wire_api=\"responses\"",
                "exec", "value with spaces",
            ],
            request.Arguments);
        Assert.Null(request.BaseUrlEnvironmentVariable);
        Assert.Equal("AIGW_CODEX_API_KEY", request.TokenEnvironmentVariable);
    }

    [Theory]
    [InlineData(ClientKind.Claude, "--model")]
    [InlineData(ClientKind.Claude, "--model=other")]
    [InlineData(ClientKind.Codex, "-m")]
    [InlineData(ClientKind.Codex, "--config=wire_api=chat")]
    [InlineData(ClientKind.Codex, "-c")]
    public void Known_adapters_reject_gateway_owned_option_overrides(
        ClientKind client,
        string conflictingArgument)
    {
        var executable = CreateExecutable(client == ClientKind.Claude ? "claude.exe" : "codex.exe");
        var factory = new ClientLaunchRequestFactory(new TestResolver(client, executable));

        var failure = Assert.Throws<ClientLaunchException>(() => factory.CreateKnown(
            client,
            [conflictingArgument],
            testRoot));

        Assert.Equal("aigw_launcher_option_conflict", failure.ErrorCode);
    }

    [Fact]
    public void Windows_resolver_uses_only_a_real_absolute_exe_from_path()
    {
        var first = Path.Combine(testRoot, "first");
        var second = Path.Combine(testRoot, "second");
        Directory.CreateDirectory(first);
        Directory.CreateDirectory(second);
        File.WriteAllText(Path.Combine(first, "claude.cmd"), "fixture");
        var expected = Path.Combine(second, "claude.exe");
        File.WriteAllText(expected, "fixture");
        var resolver = new WindowsClientExecutableResolver(
            string.Join(Path.PathSeparator, "relative", first, second));

        var resolved = resolver.Resolve(ClientKind.Claude);

        Assert.Equal(expected, resolved);
    }

    [Fact]
    public void Windows_resolver_fails_closed_when_the_native_executable_is_missing()
    {
        Directory.CreateDirectory(testRoot);
        var resolver = new WindowsClientExecutableResolver(testRoot);

        var failure = Assert.Throws<ClientLaunchException>(
            () => resolver.Resolve(ClientKind.Codex));

        Assert.Equal("aigw_launcher_client_not_found", failure.ErrorCode);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private string CreateExecutable(string fileName)
    {
        Directory.CreateDirectory(testRoot);
        var path = Path.Combine(testRoot, fileName);
        File.WriteAllText(path, "fixture");
        return path;
    }

    private sealed class TestResolver(ClientKind expectedClient, string executablePath)
        : IClientExecutableResolver
    {
        public string Resolve(ClientKind client)
        {
            Assert.Equal(expectedClient, client);
            return executablePath;
        }
    }
}
