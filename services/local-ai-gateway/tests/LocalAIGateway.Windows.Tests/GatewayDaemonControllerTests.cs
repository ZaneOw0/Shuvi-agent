using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.ProcessFixture;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Windows.Tests;

public sealed class GatewayDaemonControllerTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-DaemonController-{Guid.NewGuid():N}");

    [Fact]
    public async Task Status_reports_stopped_when_the_current_user_pipe_is_unavailable()
    {
        var control = new TestControlClient();
        control.EnqueueUnavailable();
        var controller = CreateController(control, new TestProcessLauncher());

        var status = await controller.GetStatusAsync();

        Assert.False(status.Running);
        Assert.Null(status.ActiveProfileId);
    }

    [Fact]
    public async Task Start_is_idempotent_when_the_daemon_is_already_running()
    {
        var control = new TestControlClient();
        control.EnqueueStatus(running: true, revision: 7);
        var launcher = new TestProcessLauncher();
        var controller = CreateController(control, launcher);

        var result = await controller.StartAsync(CreateTarget());

        Assert.False(result.Changed);
        Assert.True(result.Status.Running);
        Assert.Equal(0, launcher.StartCount);
    }

    [Fact]
    public async Task Start_launches_only_the_fixed_runtime_and_waits_for_pipe_readiness()
    {
        var target = CreateTarget();
        var control = new TestControlClient();
        control.EnqueueUnavailable();
        control.EnqueueStatus(
            running: true,
            revision: 11,
            circuits: [new TargetCircuitStatus("provider", "public-chat", CircuitStates.Open, 5, DateTimeOffset.UtcNow.AddSeconds(30))]);
        var launcher = new TestProcessLauncher();
        var controller = CreateController(control, launcher);

        var result = await controller.StartAsync(target);

        Assert.True(result.Changed);
        Assert.True(result.Status.Running);
        Assert.Equal(11, result.Status.ActiveConfigurationRevision);
        Assert.Equal(CircuitStates.Open, Assert.Single(result.Status.TargetCircuits).State);
        Assert.Equal(target.RuntimeExecutablePath, launcher.ExecutablePath);
        Assert.Equal(target.InstallRoot, launcher.WorkingDirectory);
        Assert.False(launcher.Process.KillCalled);
    }

    [Fact]
    public async Task Start_rejects_a_missing_runtime_before_process_creation()
    {
        var target = CreateTarget(createRuntime: false);
        var control = new TestControlClient();
        control.EnqueueUnavailable();
        var launcher = new TestProcessLauncher();
        var controller = CreateController(control, launcher);

        var failure = await Assert.ThrowsAsync<InstallationException>(
            () => controller.StartAsync(target));

        Assert.Equal("aigw_install_runtime_missing", failure.ErrorCode);
        Assert.Equal(0, launcher.StartCount);
    }

    [Fact]
    public async Task Start_failure_reports_the_child_exit_code_without_retrying_process_creation()
    {
        var control = new TestControlClient();
        control.EnqueueUnavailable();
        var launcher = new TestProcessLauncher();
        launcher.Process.Exited = true;
        launcher.Process.ConfiguredExitCode = 12;
        var controller = CreateController(control, launcher);

        var failure = await Assert.ThrowsAsync<GatewayDaemonException>(
            () => controller.StartAsync(CreateTarget()));

        Assert.Equal("aigw_daemon_start_failed", failure.ErrorCode);
        Assert.Contains("12", failure.Message, StringComparison.Ordinal);
        Assert.Equal(1, launcher.StartCount);
        Assert.False(launcher.Process.KillCalled);
    }

    [Fact]
    public async Task Start_timeout_kills_only_the_process_started_by_this_call()
    {
        var control = new TestControlClient();
        control.EnqueueUnavailable();
        var launcher = new TestProcessLauncher();
        var now = DateTime.UtcNow;
        var calls = 0;
        var controller = CreateController(
            control,
            launcher,
            utcNow: () => calls++ == 0 ? now : now.AddMinutes(1));

        var failure = await Assert.ThrowsAsync<GatewayDaemonException>(
            () => controller.StartAsync(CreateTarget()));

        Assert.Equal("aigw_daemon_start_timeout", failure.ErrorCode);
        Assert.True(launcher.Process.KillCalled);
    }

    [Fact]
    public async Task Start_cleanup_failure_preserves_both_startup_and_cleanup_errors()
    {
        var control = new TestControlClient();
        control.EnqueueUnavailable();
        var launcher = new TestProcessLauncher();
        launcher.Process.ThrowOnKill = true;
        var now = DateTime.UtcNow;
        var calls = 0;
        var controller = CreateController(
            control,
            launcher,
            utcNow: () => calls++ == 0 ? now : now.AddMinutes(1));

        var failure = await Assert.ThrowsAsync<GatewayDaemonException>(
            () => controller.StartAsync(CreateTarget()));

        Assert.Equal("aigw_daemon_start_cleanup_failed", failure.ErrorCode);
        var aggregate = Assert.IsType<AggregateException>(failure.InnerException);
        Assert.Equal(2, aggregate.InnerExceptions.Count);
    }

    [Fact]
    public async Task Stop_is_idempotent_and_waits_until_the_pipe_disappears()
    {
        var control = new TestControlClient();
        control.EnqueueStatus(running: true, revision: 3);
        control.EnqueueStatus(running: true, revision: 3);
        control.EnqueueUnavailable();
        var controller = CreateController(control, new TestProcessLauncher());

        var result = await controller.StopAsync();

        Assert.True(result.Changed);
        Assert.False(result.Status.Running);
        Assert.Equal(
            [ControlCommands.Status, ControlCommands.Stop, ControlCommands.Status],
            control.Commands);
    }

    [Fact]
    public async Task Restart_stops_the_old_daemon_before_starting_the_fixed_runtime()
    {
        var control = new TestControlClient();
        control.EnqueueStatus(running: true, revision: 3);
        control.EnqueueStatus(running: true, revision: 3);
        control.EnqueueUnavailable();
        control.EnqueueUnavailable();
        control.EnqueueStatus(running: true, revision: 4);
        var launcher = new TestProcessLauncher();
        var controller = CreateController(control, launcher);

        var result = await controller.RestartAsync(CreateTarget());

        Assert.True(result.Changed);
        Assert.True(result.Status.Running);
        Assert.Equal(4, result.Status.ActiveConfigurationRevision);
        Assert.Equal(1, launcher.StartCount);
    }

    [Fact]
    public async Task Reload_uses_the_existing_control_protocol_and_returns_the_new_active_profile()
    {
        var control = new TestControlClient();
        control.EnqueueStatus(running: true, revision: 3, profileId: "first");
        control.EnqueueStatus(running: true, revision: 4, profileId: "second");
        var controller = CreateController(control, new TestProcessLauncher());

        var result = await controller.ReloadAsync();

        Assert.True(result.Changed);
        Assert.Equal("second", result.Status.ActiveProfileId);
        Assert.Equal(4, result.Status.ActiveConfigurationRevision);
        Assert.Equal([ControlCommands.Status, ControlCommands.Reload], control.Commands);
    }

    [Fact]
    public async Task Reload_is_a_no_op_when_the_daemon_is_stopped()
    {
        var control = new TestControlClient();
        control.EnqueueUnavailable();
        var controller = CreateController(control, new TestProcessLauncher());

        var result = await controller.ReloadAsync();

        Assert.False(result.Changed);
        Assert.False(result.Status.Running);
        Assert.Equal([ControlCommands.Status], control.Commands);
    }

    [Fact]
    public async Task Windows_launcher_restricts_inheritance_and_redirects_all_standard_handles_to_null()
    {
        var executable = Path.ChangeExtension(
            typeof(ProcessFixtureMarker).Assembly.Location,
            ".exe");
        Directory.CreateDirectory(testRoot);
        var marker = Path.Combine(testRoot, "daemon-standard-handles.txt");
        using var process = new WindowsGatewayDaemonProcessLauncher().Start(executable, testRoot);
        try
        {
            var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
            while (!File.Exists(marker) && DateTime.UtcNow < deadline)
            {
                await Task.Delay(25);
            }

            Assert.True(File.Exists(marker));
            Assert.Equal("2,2,2", await File.ReadAllTextAsync(marker));
        }
        finally
        {
            if (!process.HasExited)
            {
                process.KillTree();
            }
        }
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private CurrentUserInstallationTarget CreateTarget(bool createRuntime = true)
    {
        var target = CurrentUserInstallationPlan.CreateTarget(
            Path.Combine(testRoot, "Local AppData"));
        Directory.CreateDirectory(target.InstallRoot);
        if (createRuntime)
        {
            File.WriteAllText(target.RuntimeExecutablePath, "fixture");
        }

        return target;
    }

    private static GatewayDaemonController CreateController(
        TestControlClient control,
        TestProcessLauncher launcher,
        Func<DateTime>? utcNow = null) =>
        new(
            control,
            launcher,
            TimeSpan.FromSeconds(10),
            TimeSpan.FromSeconds(10),
            TimeSpan.FromMilliseconds(1),
            static (_, cancellationToken) => Task.Delay(0, cancellationToken),
            utcNow ?? (() => DateTime.UtcNow));

    private sealed class TestControlClient : IControlClient
    {
        private readonly Queue<Func<ControlResponse>> responses = new();

        public List<string> Commands { get; } = [];

        public void EnqueueUnavailable() => responses.Enqueue(() => throw new ControlProtocolException(
            "aigw_control_unavailable",
            "Fixture pipe unavailable."));

        public void EnqueueStatus(
            bool running,
            long? revision,
            string profileId = "default",
            IReadOnlyList<TargetCircuitStatus>? circuits = null) => responses.Enqueue(() => new ControlResponse(
            ControlProtocol.Version,
            true,
            new ControlStatus(running, running ? profileId : null, revision, null, false, null, circuits ?? []),
            null));

        public Task<ControlResponse> SendAsync(
            string command,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Commands.Add(command);
            if (responses.Count == 0)
            {
                throw new InvalidOperationException("No fixture control response remains.");
            }

            return Task.FromResult(responses.Dequeue().Invoke());
        }
    }

    private sealed class TestProcessLauncher : IGatewayDaemonProcessLauncher
    {
        public TestProcess Process { get; } = new();

        public int StartCount { get; private set; }

        public string? ExecutablePath { get; private set; }

        public string? WorkingDirectory { get; private set; }

        public IGatewayDaemonProcess Start(string executablePath, string workingDirectory)
        {
            StartCount++;
            ExecutablePath = executablePath;
            WorkingDirectory = workingDirectory;
            return Process;
        }
    }

    private sealed class TestProcess : IGatewayDaemonProcess
    {
        public bool Exited { get; set; }

        public int ConfiguredExitCode { get; set; }

        public bool KillCalled { get; private set; }

        public bool ThrowOnKill { get; set; }

        public bool HasExited => Exited;

        public int ExitCode => ConfiguredExitCode;

        public void KillTree()
        {
            KillCalled = true;
            if (ThrowOnKill)
            {
                throw new InvalidOperationException("Fixture cleanup failure.");
            }

            Exited = true;
        }

        public void Dispose()
        {
        }
    }
}
