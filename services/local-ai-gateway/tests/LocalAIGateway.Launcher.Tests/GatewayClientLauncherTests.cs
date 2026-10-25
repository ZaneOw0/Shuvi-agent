using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Launcher.Tests;

public sealed class GatewayClientLauncherTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-Launcher-{Guid.NewGuid():N}");

    [Fact]
    public async Task Launch_reads_the_installed_token_starts_the_daemon_and_injects_only_into_the_child_plan()
    {
        var calls = new List<string>();
        var credentialStore = new TestCredentialStore(calls)
        {
            Secret = RuntimeClientTokenGenerator.Generate(),
        };
        var daemon = new TestDaemonController(calls);
        var processRunner = new TestProcessRunner(calls) { ExitCode = 23 };
        var target = CreateTarget();
        var request = CreateRequest();
        var launcher = new GatewayClientLauncher(
            daemon,
            credentialStore,
            processRunner,
            target);

        var exitCode = await launcher.LaunchAsync(request);

        Assert.Equal(23, exitCode);
        Assert.Equal(["credential", "daemon", "client"], calls);
        Assert.Equal(target.RuntimeCredentialTarget, credentialStore.Target);
        Assert.Same(target, daemon.Target);
        Assert.Same(request, processRunner.Request);
        Assert.Equal(GatewayClientLauncher.GatewayBaseUrl, processRunner.BaseUrl);
        Assert.Equal(credentialStore.Secret, processRunner.Token);
        Assert.Null(Environment.GetEnvironmentVariable(request.TokenEnvironmentVariable));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not-a-generated-runtime-token")]
    public async Task Launch_rejects_a_missing_or_malformed_runtime_token_before_starting_any_process(string? token)
    {
        var calls = new List<string>();
        var credentialStore = new TestCredentialStore(calls) { Secret = token };
        var daemon = new TestDaemonController(calls);
        var processRunner = new TestProcessRunner(calls);
        var launcher = new GatewayClientLauncher(
            daemon,
            credentialStore,
            processRunner,
            CreateTarget());

        var failure = await Assert.ThrowsAsync<ClientLaunchException>(
            () => launcher.LaunchAsync(CreateRequest()));

        Assert.Equal("aigw_launcher_runtime_credential_invalid", failure.ErrorCode);
        Assert.Equal(["credential"], calls);
        Assert.Null(processRunner.Token);
    }

    [Fact]
    public async Task Launch_rejects_invalid_requests_before_reading_the_runtime_token()
    {
        var calls = new List<string>();
        var launcher = new GatewayClientLauncher(
            new TestDaemonController(calls),
            new TestCredentialStore(calls) { Secret = RuntimeClientTokenGenerator.Generate() },
            new TestProcessRunner(calls),
            CreateTarget());
        var request = CreateRequest() with
        {
            BaseUrlEnvironmentVariable = "SAME",
            TokenEnvironmentVariable = "same",
        };

        var failure = await Assert.ThrowsAsync<ClientLaunchException>(
            () => launcher.LaunchAsync(request));

        Assert.Equal("aigw_launcher_request_invalid", failure.ErrorCode);
        Assert.Empty(calls);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private CurrentUserInstallationTarget CreateTarget()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(
            Path.Combine(testRoot, "Local AppData"));
        Directory.CreateDirectory(target.InstallRoot);
        File.WriteAllText(target.RuntimeExecutablePath, "fixture");
        return target;
    }

    private ClientLaunchRequest CreateRequest()
    {
        Directory.CreateDirectory(testRoot);
        var executable = Path.Combine(testRoot, "client.exe");
        File.WriteAllText(executable, "fixture");
        return new ClientLaunchRequest(
            executable,
            ["argument"],
            testRoot,
            "AIGW_TEST_BASE_URL",
            "AIGW_TEST_TOKEN");
    }

    private sealed class TestCredentialStore(List<string> calls) : ICredentialStore
    {
        public string? Secret { get; init; }

        public string? Target { get; private set; }

        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default)
        {
            calls.Add("credential");
            Target = target;
            return ValueTask.FromResult(Secret);
        }

        public ValueTask SetSecretAsync(
            string target,
            string secret,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public ValueTask DeleteSecretAsync(
            string target,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class TestDaemonController(List<string> calls) : IGatewayDaemonController
    {
        public CurrentUserInstallationTarget? Target { get; private set; }

        public Task<GatewayDaemonOperationResult> StartAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            calls.Add("daemon");
            Target = target;
            return Task.FromResult(new GatewayDaemonOperationResult(
                true,
                new GatewayDaemonStatus(true, "profile", 1, null, false, null, [])));
        }

        public Task<GatewayDaemonStatus> GetStatusAsync(CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<GatewayDaemonOperationResult> StopAsync(CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<GatewayDaemonOperationResult> RestartAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<GatewayDaemonOperationResult> ReloadAsync(
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class TestProcessRunner(List<string> calls) : IClientProcessRunner
    {
        public int ExitCode { get; init; }

        public ClientLaunchRequest? Request { get; private set; }

        public string? BaseUrl { get; private set; }

        public string? Token { get; private set; }

        public Task<int> RunAsync(
            ClientLaunchRequest request,
            string baseUrl,
            string token,
            CancellationToken cancellationToken)
        {
            calls.Add("client");
            Request = request;
            BaseUrl = baseUrl;
            Token = token;
            return Task.FromResult(ExitCode);
        }
    }
}
