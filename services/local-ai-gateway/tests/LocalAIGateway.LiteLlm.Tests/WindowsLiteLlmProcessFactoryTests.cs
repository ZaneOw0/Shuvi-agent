using System.Diagnostics;
using System.Net;
using System.Text;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.LiteLlm.Tests;

public sealed class WindowsLiteLlmProcessFactoryTests
{
    [Fact]
    public async Task Start_writes_a_protected_secret_free_config_and_stop_removes_the_owned_instance()
    {
        using var fixture = new FactoryFixture();
        var process = new FakeJobProcess();
        var launcher = new FakeJobProcessLauncher(process);
        var security = new RecordingFileSecurity();
        var factory = fixture.CreateFactory(launcher, security);
        const string secret = "factory-secret-canary";
        var plan = CreatePlan("model_list:\n  - model_name: aigw/default\n", secret);

        var managed = await factory.StartAsync(CreateProfile(), plan);
        var instanceDirectory = fixture.InstanceDirectory;
        var configurationPath = Path.Combine(instanceDirectory, "litellm.yaml");
        var callbackPath = Path.Combine(instanceDirectory, "aigw_usage_callback.py");
        var metadataPath = Path.Combine(instanceDirectory, "aigw-usage-metadata.json");

        Assert.Equal(new Uri("http://127.0.0.1:43123/"), managed.Instance.BaseAddress);
        Assert.Equal("internal-token", managed.Instance.InternalToken);
        Assert.Equal("model_list:\n  - model_name: aigw/default\n", await File.ReadAllTextAsync(configurationPath));
        Assert.DoesNotContain(secret, await File.ReadAllTextAsync(configurationPath), StringComparison.Ordinal);
        Assert.Contains(instanceDirectory, security.ProtectedDirectories);
        Assert.Contains(configurationPath, security.ProtectedFiles);
        Assert.Contains(callbackPath, security.ProtectedFiles);
        Assert.Contains(metadataPath, security.ProtectedFiles);
        Assert.Equal("callback", await File.ReadAllTextAsync(callbackPath));
        Assert.Equal("{}", await File.ReadAllTextAsync(metadataPath));
        Assert.True(Directory.Exists(Path.Combine(instanceDirectory, "runtime-state", "cache")));
        Assert.Contains(fixture.UsageRoot, security.ProtectedDirectories);
        Assert.NotNull(launcher.StartInfo);
        Assert.Equal(fixture.PythonPath, launcher.StartInfo.FileName);
        Assert.Contains(configurationPath, launcher.StartInfo.ArgumentList);
        Assert.DoesNotContain(launcher.StartInfo.ArgumentList, argument => argument.Contains(secret, StringComparison.Ordinal));
        Assert.Equal(secret, launcher.StartInfo.Environment["AIGW_UPSTREAM_000_API_KEY"]);
        Assert.Equal(fixture.UsageDatabasePath, launcher.StartInfo.Environment["AIGW_USAGE_DATABASE"]);
        Assert.Equal(metadataPath, launcher.StartInfo.Environment["AIGW_USAGE_METADATA"]);

        await managed.StopAsync();
        await managed.DisposeAsync();
        await managed.DisposeAsync();

        Assert.Equal(1, process.TerminateCount);
        Assert.Equal(1, process.DisposeCount);
        Assert.False(Directory.Exists(instanceDirectory));
        Assert.True(Directory.Exists(fixture.UsageRoot));
    }

    [Fact]
    public async Task Start_rejects_missing_usage_assets_before_launch_and_cleans_the_instance()
    {
        using var fixture = new FactoryFixture();
        var launcher = new FakeJobProcessLauncher(new FakeJobProcess());
        var factory = fixture.CreateFactory(launcher, new RecordingFileSecurity());
        var plan = new LiteLlmConfigurationPlan(
            Encoding.UTF8.GetBytes("model_list: []\n"),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["AIGW_LITELLM_MASTER_KEY"] = "internal-token",
            });

        var exception = await Assert.ThrowsAsync<LiteLlmException>(
            () => factory.StartAsync(CreateProfile(), plan));

        Assert.Equal("aigw_litellm_usage_callback_missing", exception.ErrorCode);
        Assert.Null(launcher.StartInfo);
        Assert.False(Directory.Exists(fixture.InstanceDirectory));
        Assert.True(Directory.Exists(fixture.UsageRoot));
    }

    [Fact]
    public async Task Probe_uses_the_private_liveliness_endpoint_and_stops_after_process_exit()
    {
        using var fixture = new FactoryFixture();
        var process = new FakeJobProcess();
        var handler = new RecordingHttpHandler(HttpStatusCode.OK);
        var factory = fixture.CreateFactory(
            new FakeJobProcessLauncher(process),
            new RecordingFileSecurity(),
            handler);
        var managed = await factory.StartAsync(CreateProfile(), CreatePlan("model_list: []\n", "secret"));

        Assert.True(await managed.ProbeReadyAsync());
        Assert.Equal(new Uri("http://127.0.0.1:43123/health/liveliness"), handler.RequestUri);

        process.HasExited = true;
        Assert.False(await managed.ProbeReadyAsync());
        Assert.Equal(1, handler.SendCount);

        await managed.DisposeAsync();
    }

    [Fact]
    public async Task Cancellation_after_native_start_terminates_the_job_and_removes_the_instance()
    {
        using var fixture = new FactoryFixture();
        using var cancellation = new CancellationTokenSource();
        var process = new FakeJobProcess();
        var launcher = new FakeJobProcessLauncher(process, cancellation.Cancel);
        var factory = fixture.CreateFactory(launcher, new RecordingFileSecurity());

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => factory.StartAsync(
            CreateProfile(),
            CreatePlan("model_list: []\n", "secret"),
            cancellation.Token));

        Assert.Equal(1, process.TerminateCount);
        Assert.Equal(1, process.DisposeCount);
        Assert.False(Directory.Exists(fixture.InstanceDirectory));
    }

    [Fact]
    public async Task Cancellation_cleanup_still_closes_the_job_when_explicit_termination_fails()
    {
        using var fixture = new FactoryFixture();
        using var cancellation = new CancellationTokenSource();
        var process = new FakeJobProcess { ThrowOnTerminate = true };
        var launcher = new FakeJobProcessLauncher(process, cancellation.Cancel);
        var factory = fixture.CreateFactory(launcher, new RecordingFileSecurity());

        var exception = await Assert.ThrowsAsync<LiteLlmException>(() => factory.StartAsync(
            CreateProfile(),
            CreatePlan("model_list: []\n", "secret"),
            cancellation.Token));

        Assert.Equal("aigw_litellm_start_cleanup_failed", exception.ErrorCode);
        Assert.Equal(1, process.TerminateCount);
        Assert.Equal(1, process.DisposeCount);
        Assert.False(Directory.Exists(fixture.InstanceDirectory));
    }

    [Fact]
    public async Task Stop_closes_the_job_after_termination_failure_and_retry_only_cleans_the_instance()
    {
        using var fixture = new FactoryFixture();
        var process = new FakeJobProcess { ThrowOnTerminate = true };
        var factory = fixture.CreateFactory(
            new FakeJobProcessLauncher(process),
            new RecordingFileSecurity());
        var managed = await factory.StartAsync(CreateProfile(), CreatePlan("model_list: []\n", "secret"));

        await Assert.ThrowsAsync<InvalidOperationException>(() => managed.StopAsync());

        Assert.Equal(1, process.TerminateCount);
        Assert.Equal(1, process.DisposeCount);
        Assert.True(Directory.Exists(fixture.InstanceDirectory));

        process.ThrowOnTerminate = false;
        await managed.StopAsync();
        await managed.DisposeAsync();

        Assert.Equal(1, process.TerminateCount);
        Assert.Equal(1, process.DisposeCount);
        Assert.False(Directory.Exists(fixture.InstanceDirectory));
    }

    private static LiteLlmConfigurationPlan CreatePlan(string yaml, string upstreamSecret) => new(
        Encoding.UTF8.GetBytes(yaml),
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["AIGW_LITELLM_MASTER_KEY"] = "internal-token",
            ["AIGW_UPSTREAM_000_API_KEY"] = upstreamSecret,
        },
        Encoding.UTF8.GetBytes("callback"),
        Encoding.UTF8.GetBytes("{}"));

    private static ProfileConfiguration CreateProfile() => new()
    {
        Id = "profile",
        Name = "Profile",
    };

    private sealed class FactoryFixture : IDisposable
    {
        private const string InstanceId = "00112233445566778899aabbccddeeff";

        public FactoryFixture()
        {
            Root = Path.Combine(
                Path.GetTempPath(),
                "LocalAIGateway.Tests",
                $"factory with spaces-{Guid.NewGuid():N}");
            ApplicationRoot = Path.Combine(Root, "application");
            RuntimeRoot = Path.Combine(Root, "data", "runtime");
            PythonPath = Path.Combine(ApplicationRoot, "runtime", "python", "python.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(PythonPath)!);
            File.WriteAllBytes(PythonPath, [0]);
        }

        public string Root { get; }

        public string ApplicationRoot { get; }

        public string RuntimeRoot { get; }

        public string PythonPath { get; }

        public string UsageRoot => Path.Combine(Root, "data", "usage");

        public string UsageDatabasePath => Path.Combine(UsageRoot, "usage.db");

        public string InstanceDirectory => Path.Combine(RuntimeRoot, "instances", InstanceId);

        public WindowsLiteLlmProcessFactory CreateFactory(
            IWindowsJobProcessLauncher launcher,
            IConfigurationFileSecurity security,
            HttpMessageHandler? handler = null) => new(
                ApplicationRoot,
                RuntimeRoot,
                security,
                TimeSpan.FromSeconds(5),
                launcher,
                () => 43123,
                () => InstanceId,
                () => handler ?? new RecordingHttpHandler(HttpStatusCode.OK));

        public void Dispose()
        {
            if (Directory.Exists(Root))
            {
                Directory.Delete(Root, recursive: true);
            }
        }
    }

    private sealed class FakeJobProcessLauncher(
        IWindowsJobProcess process,
        Action? afterStart = null) : IWindowsJobProcessLauncher
    {
        public ProcessStartInfo? StartInfo { get; private set; }

        public IWindowsJobProcess Start(ProcessStartInfo startInfo)
        {
            StartInfo = startInfo;
            afterStart?.Invoke();
            return process;
        }
    }

    private sealed class FakeJobProcess : IWindowsJobProcess
    {
        public int ProcessId => 12345;

        public bool HasExited { get; set; }

        public int TerminateCount { get; private set; }

        public int DisposeCount { get; private set; }

        public bool ThrowOnTerminate { get; set; }

        public Task TerminateAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
        {
            TerminateCount++;
            if (ThrowOnTerminate)
            {
                throw new InvalidOperationException("terminate failure");
            }
            HasExited = true;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            DisposeCount++;
            HasExited = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class RecordingFileSecurity : IConfigurationFileSecurity
    {
        public List<string> ProtectedDirectories { get; } = [];

        public List<string> ProtectedFiles { get; } = [];

        public void ProtectDirectory(string path) => ProtectedDirectories.Add(path);

        public void ProtectFile(string path) => ProtectedFiles.Add(path);
    }

    private sealed class RecordingHttpHandler(HttpStatusCode statusCode) : HttpMessageHandler
    {
        public Uri? RequestUri { get; private set; }

        public int SendCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SendCount++;
            RequestUri = request.RequestUri;
            return Task.FromResult(new HttpResponseMessage(statusCode));
        }
    }
}
