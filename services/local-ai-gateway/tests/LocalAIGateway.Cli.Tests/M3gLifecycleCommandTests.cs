using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Windows.Installation;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Cli.Tests;

public sealed class M3gLifecycleCommandTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CliLifecycle-{Guid.NewGuid():N}");

    [Fact]
    public async Task Root_help_lists_the_lifecycle_commands()
    {
        var result = await RunAsync(CreateServices(), "--help");

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("install", result.Output, StringComparison.Ordinal);
        Assert.Contains("restart", result.Output, StringComparison.Ordinal);
        Assert.Contains("status", result.Output, StringComparison.Ordinal);
        Assert.Contains("doctor", result.Output, StringComparison.Ordinal);
        Assert.Contains("autostart", result.Output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Install_uses_the_fixed_plan_defaults_to_both_autostarts_and_never_returns_the_runtime_token()
    {
        var installation = new TestInstallationCoordinator();
        var services = CreateServices(installation: installation);

        var result = await RunAsync(services, "install", "--autostart", "enable", "--json");

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(string.Empty, result.Error);
        using var document = JsonDocument.Parse(result.Output);
        var data = document.RootElement.GetProperty("data");
        Assert.True(data.GetProperty("installed").GetBoolean());
        Assert.True(data.GetProperty("runtimeCredentialCreated").GetBoolean());
        Assert.True(data.GetProperty("autostartEnabled").GetBoolean());
        Assert.True(data.GetProperty("runtimeAutostart").GetProperty("owned").GetBoolean());
        Assert.True(data.GetProperty("trayAutostart").GetProperty("owned").GetBoolean());
        Assert.True(data.GetProperty("userPath").GetProperty("owned").GetBoolean());
        Assert.True(data.GetProperty("startMenu").GetProperty("owned").GetBoolean());
        Assert.DoesNotContain("token", result.Output, StringComparison.OrdinalIgnoreCase);
        Assert.NotNull(installation.InstallPlan);
        Assert.Equal(services.Operations!.Target.InstallRoot, installation.InstallPlan.InstallRoot);
        Assert.Equal(["autostart.enable"], installation.AutostartCalls);
    }

    [Fact]
    public async Task Install_explicit_disable_removes_owned_autostart_without_prompting()
    {
        var installation = new TestInstallationCoordinator();
        var services = CreateServices(installation: installation);

        var result = await RunAsync(services, "install", "--autostart", "disable", "--json");

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(string.Empty, result.Error);
        using var document = JsonDocument.Parse(result.Output);
        Assert.False(document.RootElement.GetProperty("data").GetProperty("autostartEnabled").GetBoolean());
        Assert.Equal(["autostart.disable"], installation.AutostartCalls);
    }

    [Fact]
    public async Task Json_install_requires_an_explicit_autostart_choice_before_mutation()
    {
        var installation = new TestInstallationCoordinator();

        var result = await RunAsync(CreateServices(installation: installation), "install", "--json");

        Assert.Equal(CliApplication.FileOrPermissionErrorExitCode, result.ExitCode);
        Assert.Equal("aigw_install_autostart_choice_required", ErrorCode(result.Error));
        Assert.Null(installation.InstallPlan);
        Assert.Empty(installation.AutostartCalls);
    }

    [Fact]
    public async Task Interactive_install_prompts_and_accepts_no_for_both_autostarts()
    {
        var installation = new TestInstallationCoordinator();

        var result = await RunWithInputAsync(
            CreateServices(installation: installation),
            "n\n",
            "install");

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("[Y/n]", result.Error, StringComparison.Ordinal);
        Assert.Equal(["autostart.disable"], installation.AutostartCalls);
    }

    [Fact]
    public async Task Interactive_install_reprompts_invalid_input_and_empty_answer_uses_enabled_default()
    {
        var installation = new TestInstallationCoordinator();

        var result = await RunWithInputAsync(
            CreateServices(installation: installation),
            "later\n\n",
            "install");

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("Enter Y or N.", result.Error, StringComparison.Ordinal);
        Assert.Equal(["autostart.enable"], installation.AutostartCalls);
    }

    [Fact]
    public async Task Uninstall_stops_the_daemon_before_removing_owned_files_and_credential()
    {
        var calls = new List<string>();
        var installation = new TestInstallationCoordinator(calls);
        var daemon = new TestDaemonController(calls);
        var services = CreateServices(installation, daemon);

        var result = await RunAsync(services, "uninstall", "--json");

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(["stop", "uninstall"], calls);
        using var document = JsonDocument.Parse(result.Output);
        Assert.True(document.RootElement.GetProperty("data").GetProperty("runtimeCredentialDeleted").GetBoolean());
        Assert.True(document.RootElement.GetProperty("data").GetProperty("autostartRemoved").GetBoolean());
        Assert.True(document.RootElement.GetProperty("data").GetProperty("shellIntegrationRemoved").GetBoolean());
    }

    [Fact]
    public async Task Autostart_commands_delegate_and_return_only_stable_ownership_fields()
    {
        var installation = new TestInstallationCoordinator();
        var services = CreateServices(installation: installation);

        var enabled = await RunAsync(services, "autostart", "enable", "--json");
        var status = await RunAsync(services, "autostart", "status", "--json");
        var disabled = await RunAsync(services, "autostart", "disable", "--json");

        Assert.Equal(0, enabled.ExitCode);
        Assert.Equal(0, status.ExitCode);
        Assert.Equal(0, disabled.ExitCode);
        Assert.Equal(["autostart.enable", "autostart.status", "autostart.disable"], installation.AutostartCalls);
        using var document = JsonDocument.Parse(status.Output);
        var data = document.RootElement.GetProperty("data");
        Assert.Equal("\\LocalAIGateway.Runtime", data.GetProperty("taskPath").GetString());
        Assert.True(data.GetProperty("registered").GetBoolean());
        Assert.True(data.GetProperty("owned").GetBoolean());
        Assert.False(data.GetProperty("conflict").GetBoolean());
        Assert.False(data.GetProperty("incomplete").GetBoolean());
        Assert.Equal("\\LocalAIGateway.Tray", data.GetProperty("tray").GetProperty("taskPath").GetString());
        Assert.True(data.GetProperty("tray").GetProperty("owned").GetBoolean());
        Assert.DoesNotContain("sid", status.Output, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Uninstall_rejects_execution_from_inside_the_install_root_before_stopping_daemon()
    {
        var calls = new List<string>();
        var installation = new TestInstallationCoordinator(calls);
        var daemon = new TestDaemonController(calls);
        var services = CreateServices(installation, daemon);
        services = services with
        {
            Operations = services.Operations! with
            {
                CommandBaseDirectory = Path.Combine(services.Operations.Target.InstallRoot, "tools"),
            },
        };

        var result = await RunAsync(services, "uninstall", "--json");

        Assert.Equal(15, result.ExitCode);
        Assert.Equal("aigw_uninstall_running_from_install_root", ErrorCode(result.Error));
        Assert.Empty(calls);
    }

    [Fact]
    public async Task Status_exposes_only_the_stable_daemon_status_fields()
    {
        var services = CreateServices(daemon: new TestDaemonController
        {
            Status = new GatewayDaemonStatus(
                true,
                "work",
                9,
                null,
                false,
                null,
                [new TargetCircuitStatus("provider", "public-chat", CircuitStates.Open, 5, DateTimeOffset.UtcNow.AddSeconds(30))]),
        });

        var result = await RunAsync(services, "status", "--json");

        Assert.Equal(0, result.ExitCode);
        using var document = JsonDocument.Parse(result.Output);
        var data = document.RootElement.GetProperty("data");
        Assert.True(data.GetProperty("running").GetBoolean());
        Assert.Equal("work", data.GetProperty("activeProfileId").GetString());
        Assert.Equal(9, data.GetProperty("activeConfigurationRevision").GetInt64());
        Assert.Equal("open", data.GetProperty("targetCircuits")[0].GetProperty("state").GetString());
        Assert.DoesNotContain("token", result.Output, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("port", result.Output, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Start_stop_and_restart_delegate_to_the_daemon_controller()
    {
        var daemon = new TestDaemonController();
        var services = CreateServices(daemon: daemon);

        Assert.Equal(0, (await RunAsync(services, "start")).ExitCode);
        Assert.Equal(0, (await RunAsync(services, "stop")).ExitCode);
        Assert.Equal(0, (await RunAsync(services, "restart")).ExitCode);

        Assert.Equal(["start", "stop", "restart"], daemon.Calls);
    }

    [Fact]
    public async Task Installation_and_daemon_failures_use_the_locked_exit_codes()
    {
        var installation = new TestInstallationCoordinator
        {
            InstallFailure = new InstallationException("aigw_install_busy", "Fixture busy."),
        };
        var daemon = new TestDaemonController
        {
            StatusFailure = new GatewayDaemonException("aigw_daemon_fixture", "Fixture daemon failure."),
        };
        var services = CreateServices(installation, daemon);

        var install = await RunAsync(services, "install", "--autostart", "disable", "--json");
        var status = await RunAsync(services, "status", "--json");

        Assert.Equal(15, install.ExitCode);
        Assert.Equal("aigw_install_busy", ErrorCode(install.Error));
        Assert.Equal(12, status.ExitCode);
        Assert.Equal("aigw_daemon_fixture", ErrorCode(status.Error));
    }

    [Fact]
    public async Task Doctor_is_read_only_and_explicitly_never_performs_a_model_probe()
    {
        var daemon = new TestDaemonController();
        var services = CreateServices(daemon: daemon);

        var result = await RunAsync(services, "doctor", "--json");

        Assert.Equal(0, result.ExitCode);
        using var document = JsonDocument.Parse(result.Output);
        var data = document.RootElement.GetProperty("data");
        Assert.False(data.GetProperty("healthy").GetBoolean());
        Assert.False(data.GetProperty("modelProbePerformed").GetBoolean());
        Assert.False(data.GetProperty("upstreamContacted").GetBoolean());
        Assert.Contains(
            data.GetProperty("issues").EnumerateArray().Select(value => value.GetString()),
            value => value == "aigw_doctor_install_missing");
        Assert.Equal(["status"], daemon.Calls);
        Assert.False(Directory.Exists(services.Operations!.Target.InstallRoot));
        Assert.False(File.Exists(services.Configuration.Paths.ConfigurationFile));
    }

    [Fact]
    public async Task Doctor_reports_open_target_circuits_without_performing_an_upstream_probe()
    {
        var daemon = new TestDaemonController
        {
            Status = new GatewayDaemonStatus(
                true,
                "work",
                9,
                null,
                false,
                null,
                [new TargetCircuitStatus("provider", "public-chat", CircuitStates.HalfOpen, 5, null)]),
        };
        var services = CreateServices(daemon: daemon);

        var result = await RunAsync(services, "doctor", "--json");

        Assert.Equal(0, result.ExitCode);
        using var document = JsonDocument.Parse(result.Output);
        var data = document.RootElement.GetProperty("data");
        Assert.Contains(
            data.GetProperty("issues").EnumerateArray().Select(value => value.GetString()),
            value => value == "aigw_doctor_target_circuit_open");
        var circuit = data.GetProperty("checks").GetProperty("targetCircuits")[0];
        Assert.Equal("half-open", circuit.GetProperty("state").GetString());
        Assert.False(data.GetProperty("modelProbePerformed").GetBoolean());
        Assert.False(data.GetProperty("upstreamContacted").GetBoolean());
        Assert.Equal(["status"], daemon.Calls);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private CliServices CreateServices(
        TestInstallationCoordinator? installation = null,
        TestDaemonController? daemon = null)
    {
        installation ??= new TestInstallationCoordinator();
        daemon ??= new TestDaemonController();
        var localAppData = Path.Combine(testRoot, "Local AppData");
        var packageRoot = Path.Combine(testRoot, "Package Source");
        var target = CurrentUserInstallationPlan.CreateTarget(localAppData);
        var configuration = new GatewayConfigurationManager(
            new ConfigurationStore(
                new ConfigurationPaths(Path.Combine(testRoot, "Configuration")),
                NoOpConfigurationFileSecurity.Instance),
            new MemoryCredentialStore());
        return new CliServices(
            configuration,
            new CliOperationalServices(
                installation,
                daemon,
                target,
                () => CurrentUserInstallationPlan.Create(packageRoot, localAppData),
                packageRoot));
    }

    private static async Task<CliRunResult> RunAsync(CliServices services, params string[] args)
        => await RunWithInputAsync(services, string.Empty, args);

    private static async Task<CliRunResult> RunWithInputAsync(
        CliServices services,
        string inputText,
        params string[] args)
    {
        using var input = new StringReader(inputText);
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = await CliApplication.RunAsync(args, input, output, error, services);
        return new CliRunResult(exitCode, output.ToString(), error.ToString());
    }

    private static string? ErrorCode(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.GetProperty("error").GetProperty("code").GetString();
    }

    private sealed record CliRunResult(int ExitCode, string Output, string Error);

    private sealed class TestInstallationCoordinator(List<string>? calls = null) : ICurrentUserInstallationCoordinator
    {
        public List<string> AutostartCalls { get; } = [];

        public CurrentUserInstallationPlan? InstallPlan { get; private set; }

        public Exception? InstallFailure { get; init; }

        public Task<CurrentUserInstallationResult> InstallAsync(
            CurrentUserInstallationPlan plan,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (InstallFailure is not null)
            {
                return Task.FromException<CurrentUserInstallationResult>(InstallFailure);
            }

            InstallPlan = plan;
            return Task.FromResult(new CurrentUserInstallationResult(
                new PackageInstallationResult(true, false, plan.InstallRoot),
                true));
        }

        public async Task<CurrentUserInstallExperienceResult> InstallAsync(
            CurrentUserInstallationPlan plan,
            bool enableAutostart,
            CancellationToken cancellationToken = default)
        {
            var installation = await InstallAsync(plan, cancellationToken);
            var autostart = enableAutostart
                ? await EnableAutostartAsync(plan.Target, cancellationToken)
                : await DisableAutostartAsync(plan.Target, cancellationToken);
            return new CurrentUserInstallExperienceResult(
                installation,
                autostart,
                new CurrentUserShellIntegrationOperationResult(true, ShellIntegrationStatus()));
        }

        public Task<CurrentUserUninstallationResult> UninstallAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            calls?.Add("uninstall");
            return Task.FromResult(new CurrentUserUninstallationResult(
                new PackageUninstallationResult(true, false, []),
                true,
                true,
                true));
        }

        public Task<CurrentUserAutostartStatus> GetAutostartStatusAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            AutostartCalls.Add("autostart.status");
            return Task.FromResult(AutostartStatus(registered: true, owned: true));
        }

        public Task<CurrentUserAutostartOperationResult> EnableAutostartAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            AutostartCalls.Add("autostart.enable");
            return Task.FromResult(new CurrentUserAutostartOperationResult(
                true,
                AutostartStatus(registered: true, owned: true)));
        }

        public Task<CurrentUserAutostartOperationResult> DisableAutostartAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            AutostartCalls.Add("autostart.disable");
            return Task.FromResult(new CurrentUserAutostartOperationResult(
                true,
                AutostartStatus(registered: false, owned: false)));
        }

        private static CurrentUserAutostartStatus AutostartStatus(bool registered, bool owned) => new(
            new CurrentUserAutostartComponentStatus(
                "\\LocalAIGateway.Runtime",
                registered,
                owned,
                false),
            new CurrentUserAutostartComponentStatus(
                "\\LocalAIGateway.Tray",
                registered,
                owned,
                false));

        private static CurrentUserShellIntegrationStatus ShellIntegrationStatus() => new(
            new CurrentUserShellIntegrationComponentStatus(
                @"HKEY_CURRENT_USER\Environment\Path",
                true,
                true,
                false),
            new CurrentUserShellIntegrationComponentStatus(
                @"C:\Fixture\Local AI Gateway.lnk",
                true,
                true,
                false));
    }

    private sealed class TestDaemonController(List<string>? sharedCalls = null) : IGatewayDaemonController
    {
        public List<string> Calls { get; } = sharedCalls ?? [];

        public GatewayDaemonStatus Status { get; init; } =
            new(false, null, null, null, false, null, []);

        public Exception? StatusFailure { get; init; }

        public Task<GatewayDaemonStatus> GetStatusAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add("status");
            if (StatusFailure is not null)
            {
                return Task.FromException<GatewayDaemonStatus>(StatusFailure);
            }

            return Task.FromResult(Status);
        }

        public Task<GatewayDaemonOperationResult> StartAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            Calls.Add("start");
            return Task.FromResult(new GatewayDaemonOperationResult(true, Status with { Running = true }));
        }

        public Task<GatewayDaemonOperationResult> StopAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("stop");
            return Task.FromResult(new GatewayDaemonOperationResult(Status.Running, Status with { Running = false }));
        }

        public Task<GatewayDaemonOperationResult> RestartAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            Calls.Add("restart");
            return Task.FromResult(new GatewayDaemonOperationResult(true, Status with { Running = true }));
        }

        public Task<GatewayDaemonOperationResult> ReloadAsync(
            CancellationToken cancellationToken = default)
        {
            Calls.Add("reload");
            return Task.FromResult(new GatewayDaemonOperationResult(true, Status));
        }
    }

    private sealed class MemoryCredentialStore : ICredentialStore
    {
        public ValueTask SetSecretAsync(string target, string secret, CancellationToken cancellationToken = default) =>
            ValueTask.CompletedTask;

        public ValueTask<string?> GetSecretAsync(string target, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult<string?>(null);

        public ValueTask DeleteSecretAsync(string target, CancellationToken cancellationToken = default) =>
            ValueTask.CompletedTask;
    }
}
