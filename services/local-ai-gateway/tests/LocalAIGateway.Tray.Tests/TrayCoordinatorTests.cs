using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Usage;
using LocalAIGateway.Tray;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Tray.Tests;

public sealed class TrayCoordinatorTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 10, 8, 30, 0, TimeSpan.Zero);

    [Fact]
    public async Task Refresh_reads_daemon_configuration_and_today_usage_with_visible_transitions()
    {
        var profiles = new TestProfileStore();
        var daemon = new TestDaemonController
        {
            Status = Running("first", 7) with
            {
                TargetCircuits =
                [
                    new TargetCircuitStatus(
                        "provider",
                        "public-chat",
                        CircuitStates.Open,
                        5,
                        Now.AddSeconds(30)),
                ],
            },
        };
        var usage = new TestUsageReader { Summary = Summary(totalTokens: 42) };
        using var coordinator = CreateCoordinator(profiles, daemon, usage);
        var activities = new List<TrayActivity>();
        coordinator.StateChanged += state => activities.Add(state.Activity);

        var state = await coordinator.RefreshAsync();

        Assert.Equal(TrayActivity.Idle, state.Activity);
        Assert.True(state.Daemon.Running);
        Assert.Equal("first", state.Daemon.ActiveProfileId);
        Assert.Equal(CircuitStates.Open, Assert.Single(state.Daemon.TargetCircuits).State);
        Assert.Equal(42, state.Usage.Totals.TotalTokens);
        Assert.Equal(TrayActivity.Refreshing, activities.First());
        Assert.Equal(TrayActivity.Idle, activities.Last());
        Assert.DoesNotContain(activities, activity => activity is not TrayActivity.Refreshing and not TrayActivity.Idle);
        Assert.Equal(new DateTimeOffset(2026, 9, 10, 0, 0, 0, TimeSpan.Zero), usage.WindowStart);
        Assert.Equal(Now, usage.WindowEnd);
    }

    [Fact]
    public async Task Start_stop_and_restart_delegate_to_the_fixed_target_and_update_state()
    {
        var daemon = new TestDaemonController();
        using var coordinator = CreateCoordinator(new TestProfileStore(), daemon, new TestUsageReader());

        Assert.True((await coordinator.StartAsync()).Daemon.Running);
        Assert.False((await coordinator.StopAsync()).Daemon.Running);
        Assert.True((await coordinator.RestartAsync()).Daemon.Running);

        Assert.Equal(["start", "status", "stop", "status", "restart", "status"], daemon.Calls);
        Assert.NotNull(daemon.Target);
        Assert.EndsWith("aigw-runtime.exe", daemon.Target.RuntimeExecutablePath, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Running_profile_switch_saves_configuration_then_uses_blue_green_reload()
    {
        var profiles = new TestProfileStore();
        var daemon = new TestDaemonController { Status = Running("first", 1) };
        using var coordinator = CreateCoordinator(profiles, daemon, new TestUsageReader());

        var state = await coordinator.SwitchProfileAsync("second");

        Assert.Equal(["second"], profiles.Selections);
        Assert.Equal(["status", "reload", "status"], daemon.Calls);
        Assert.Equal("second", state.Configuration.SelectedProfileId);
        Assert.Equal("second", state.Daemon.ActiveProfileId);
        Assert.Equal(2, state.Daemon.ActiveConfigurationRevision);
    }

    [Fact]
    public async Task Stopped_profile_switch_changes_the_source_without_starting_or_reloading_daemon()
    {
        var profiles = new TestProfileStore();
        var daemon = new TestDaemonController();
        using var coordinator = CreateCoordinator(profiles, daemon, new TestUsageReader());

        var state = await coordinator.SwitchProfileAsync("second");

        Assert.Equal(["second"], profiles.Selections);
        Assert.Equal(["status", "status"], daemon.Calls);
        Assert.False(state.Daemon.Running);
        Assert.Equal("second", state.Configuration.SelectedProfileId);
    }

    [Fact]
    public async Task Reload_failure_keeps_the_saved_selection_and_reports_a_stable_error()
    {
        var profiles = new TestProfileStore();
        var daemon = new TestDaemonController
        {
            Status = Running("first", 1),
            ReloadFailure = new GatewayDaemonException("aigw_fixture_reload", "Fixture reload failed."),
        };
        using var coordinator = CreateCoordinator(profiles, daemon, new TestUsageReader());

        var state = await coordinator.SwitchProfileAsync("second");

        Assert.Equal("second", state.Configuration.SelectedProfileId);
        Assert.Equal("first", state.Daemon.ActiveProfileId);
        Assert.Equal("aigw_fixture_reload", state.Error?.Code);
        Assert.Equal(TrayActivity.Idle, state.Activity);
    }

    [Fact]
    public async Task Usage_failure_is_contained_as_a_redacted_tray_error()
    {
        var usage = new TestUsageReader
        {
            Failure = new UsageException("aigw_usage_fixture", "Fixture usage failed."),
        };
        var daemon = new TestDaemonController { Status = Running("first", 3) };
        using var coordinator = CreateCoordinator(new TestProfileStore(), daemon, usage);

        var state = await coordinator.RefreshAsync();

        Assert.Equal("aigw_usage_fixture", state.Error?.Code);
        Assert.Equal("Fixture usage failed.", state.Error?.Message);
        Assert.True(state.Daemon.Running);
        Assert.Equal(TrayActivity.Idle, state.Activity);
    }

    [Fact]
    public async Task Unexpected_failures_do_not_expose_exception_details()
    {
        var profiles = new TestProfileStore
        {
            Failure = new InvalidOperationException("sensitive fixture detail"),
        };
        using var coordinator = CreateCoordinator(profiles, new TestDaemonController(), new TestUsageReader());

        var state = await coordinator.RefreshAsync();

        Assert.Equal("aigw_tray_unexpected", state.Error?.Code);
        Assert.DoesNotContain("sensitive", state.Error?.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Cancellation_propagates_and_returns_the_state_machine_to_idle()
    {
        var profiles = new TestProfileStore { WaitForCancellation = true };
        using var coordinator = CreateCoordinator(profiles, new TestDaemonController(), new TestUsageReader());
        using var cancellation = new CancellationTokenSource();
        var refresh = coordinator.RefreshAsync(cancellation.Token);
        await profiles.LoadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => refresh);
        Assert.Equal(TrayActivity.Idle, coordinator.State.Activity);
    }

    private static TrayCoordinator CreateCoordinator(
        ITrayProfileStore profiles,
        IGatewayDaemonController daemon,
        IUsageSummaryReader usage) =>
        new(
            profiles,
            daemon,
            usage,
            CurrentUserInstallationPlan.CreateTarget(Path.Combine(Path.GetTempPath(), "LocalAIGateway-Tray-Fixture")),
            new FixedTimeProvider(Now, TimeZoneInfo.Utc));

    private static GatewayDaemonStatus Running(string profileId, long revision) =>
        new(true, profileId, revision, null, false, null, []);

    private static UsageSummary Summary(long totalTokens = 0) =>
        new(
            true,
            0,
            1,
            new UsageTotals(1, 1, 0, totalTokens, 0, totalTokens),
            [],
            []);

    private sealed class TestProfileStore : ITrayProfileStore
    {
        public List<string> Selections { get; } = [];

        public bool WaitForCancellation { get; init; }

        public Exception? Failure { get; init; }

        public TaskCompletionSource LoadStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public string Selected { get; private set; } = "first";

        public async Task<TrayConfigurationSnapshot> LoadAsync(
            CancellationToken cancellationToken = default)
        {
            LoadStarted.TrySetResult();
            if (WaitForCancellation)
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }

            if (Failure is not null)
            {
                throw Failure;
            }

            return Snapshot();
        }

        public Task<TrayConfigurationSnapshot> SelectAsync(
            string profileId,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Selections.Add(profileId);
            Selected = profileId;
            return Task.FromResult(Snapshot());
        }

        private TrayConfigurationSnapshot Snapshot() =>
            new(
                Selections.Count + 1,
                Selected,
                [new TrayProfile("first", "First", true), new TrayProfile("second", "Second", true)]);
    }

    private sealed class TestDaemonController : IGatewayDaemonController
    {
        public List<string> Calls { get; } = [];

        public GatewayDaemonStatus Status { get; set; } =
            new(false, null, null, null, false, null, []);

        public Exception? ReloadFailure { get; init; }

        public CurrentUserInstallationTarget? Target { get; private set; }

        public Task<GatewayDaemonStatus> GetStatusAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add("status");
            return Task.FromResult(Status);
        }

        public Task<GatewayDaemonOperationResult> StartAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add("start");
            Target = target;
            Status = Running(Status.ActiveProfileId ?? "first", Status.ActiveConfigurationRevision ?? 1);
            return Task.FromResult(new GatewayDaemonOperationResult(true, Status));
        }

        public Task<GatewayDaemonOperationResult> StopAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add("stop");
            Status = new GatewayDaemonStatus(false, null, null, null, false, null, []);
            return Task.FromResult(new GatewayDaemonOperationResult(true, Status));
        }

        public Task<GatewayDaemonOperationResult> RestartAsync(
            CurrentUserInstallationTarget target,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add("restart");
            Target = target;
            Status = Running(Status.ActiveProfileId ?? "first", (Status.ActiveConfigurationRevision ?? 0) + 1);
            return Task.FromResult(new GatewayDaemonOperationResult(true, Status));
        }

        public Task<GatewayDaemonOperationResult> ReloadAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add("reload");
            if (ReloadFailure is not null)
            {
                return Task.FromException<GatewayDaemonOperationResult>(ReloadFailure);
            }

            Status = Running("second", (Status.ActiveConfigurationRevision ?? 0) + 1);
            return Task.FromResult(new GatewayDaemonOperationResult(true, Status));
        }
    }

    private sealed class TestUsageReader : IUsageSummaryReader
    {
        public UsageSummary Summary { get; init; } = TrayCoordinatorTests.Summary();

        public Exception? Failure { get; init; }

        public DateTimeOffset? WindowStart { get; private set; }

        public DateTimeOffset? WindowEnd { get; private set; }

        public Task<UsageSummary> ReadAsync(
            DateTimeOffset windowStartUtc,
            DateTimeOffset windowEndUtc,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            WindowStart = windowStartUtc;
            WindowEnd = windowEndUtc;
            return Failure is null
                ? Task.FromResult(Summary)
                : Task.FromException<UsageSummary>(Failure);
        }
    }

    private sealed class FixedTimeProvider(DateTimeOffset utcNow, TimeZoneInfo localZone) : TimeProvider
    {
        public override TimeZoneInfo LocalTimeZone => localZone;

        public override DateTimeOffset GetUtcNow() => utcNow;
    }
}
