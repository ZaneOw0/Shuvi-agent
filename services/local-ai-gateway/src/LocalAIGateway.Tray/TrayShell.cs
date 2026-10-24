using System.ComponentModel;
using System.Drawing;
using System.Globalization;
using System.Windows;
using System.Windows.Threading;
using LocalAIGateway.Core.Control;
using Forms = System.Windows.Forms;
using WpfApplication = System.Windows.Application;

namespace LocalAIGateway.Tray;

public sealed class TrayShell : IDisposable
{
    private readonly WpfApplication application;
    private readonly TrayApplicationLifetime lifetime;
    private readonly TrayCoordinator coordinator;
    private readonly Forms.NotifyIcon notifyIcon;
    private readonly Forms.ToolStripMenuItem statusItem;
    private readonly Forms.ToolStripMenuItem profileItem;
    private readonly Forms.ToolStripMenuItem usageItem;
    private readonly Forms.ToolStripMenuItem circuitItem;
    private readonly Forms.ToolStripMenuItem profilesMenu;
    private readonly Forms.ToolStripMenuItem startItem;
    private readonly Forms.ToolStripMenuItem stopItem;
    private readonly Forms.ToolStripMenuItem restartItem;
    private readonly Forms.ToolStripMenuItem refreshItem;
    private readonly DispatcherTimer refreshTimer;
    private readonly TrayDashboardWindow dashboard;
    private string? lastBalloonErrorCode;
    private bool exiting;
    private int disposed;

    public TrayShell(
        WpfApplication application,
        TrayApplicationLifetime lifetime,
        TrayCoordinator coordinator)
    {
        this.application = application ?? throw new ArgumentNullException(nameof(application));
        this.lifetime = lifetime ?? throw new ArgumentNullException(nameof(lifetime));
        this.coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));

        statusItem = new Forms.ToolStripMenuItem("状态：正在读取…") { Enabled = false };
        profileItem = new Forms.ToolStripMenuItem("活动 Profile：—") { Enabled = false };
        usageItem = new Forms.ToolStripMenuItem("今日 Token：0") { Enabled = false };
        circuitItem = new Forms.ToolStripMenuItem("目标熔断：—") { Enabled = false };
        profilesMenu = new Forms.ToolStripMenuItem("切换 Profile");
        startItem = new Forms.ToolStripMenuItem("启动", null, (_, _) => RunOperation(coordinator.StartAsync));
        stopItem = new Forms.ToolStripMenuItem("停止", null, (_, _) => RunOperation(coordinator.StopAsync));
        restartItem = new Forms.ToolStripMenuItem("重启", null, (_, _) => RunOperation(coordinator.RestartAsync));
        refreshItem = new Forms.ToolStripMenuItem("刷新", null, (_, _) => RunOperation(coordinator.RefreshAsync));

        var menu = new Forms.ContextMenuStrip();
        menu.Items.AddRange(
        [
            statusItem,
            profileItem,
            usageItem,
            circuitItem,
            new Forms.ToolStripSeparator(),
            new Forms.ToolStripMenuItem("打开仪表盘", null, (_, _) => ShowDashboard()),
            profilesMenu,
            new Forms.ToolStripSeparator(),
            startItem,
            stopItem,
            restartItem,
            refreshItem,
            new Forms.ToolStripSeparator(),
            new Forms.ToolStripMenuItem("退出", null, (_, _) => Exit()),
        ]);

        notifyIcon = new Forms.NotifyIcon
        {
            ContextMenuStrip = menu,
            Icon = SystemIcons.Application,
            Text = "Local AI Gateway",
            Visible = true,
        };
        notifyIcon.DoubleClick += (_, _) => ShowDashboard();

        dashboard = new TrayDashboardWindow();
        dashboard.StartRequested += (_, _) => RunOperation(coordinator.StartAsync);
        dashboard.StopRequested += (_, _) => RunOperation(coordinator.StopAsync);
        dashboard.RestartRequested += (_, _) => RunOperation(coordinator.RestartAsync);
        dashboard.RefreshRequested += (_, _) => RunOperation(coordinator.RefreshAsync);
        dashboard.ProfileSwitchRequested += (_, profileId) =>
            RunOperation(token => coordinator.SwitchProfileAsync(profileId, token));
        dashboard.Closing += OnDashboardClosing;

        coordinator.StateChanged += OnStateChanged;
        refreshTimer = new DispatcherTimer(TimeSpan.FromSeconds(15), DispatcherPriority.Background, OnTimer, application.Dispatcher);
    }

    public void Start()
    {
        refreshTimer.Start();
        RunOperation(coordinator.RefreshAsync);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        refreshTimer.Stop();
        coordinator.StateChanged -= OnStateChanged;
        coordinator.Dispose();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        dashboard.Closing -= OnDashboardClosing;
        if (dashboard.IsLoaded)
        {
            dashboard.Close();
        }
    }

    private void OnStateChanged(TrayState state)
    {
        if (!application.Dispatcher.CheckAccess())
        {
            application.Dispatcher.BeginInvoke(() => ApplyState(state));
            return;
        }

        ApplyState(state);
    }

    private void ApplyState(TrayState state)
    {
        var status = state.Daemon.Running
            ? state.Daemon.Switching ? "切换中" : "运行中"
            : "已停止";
        statusItem.Text = $"状态：{status}";
        profileItem.Text = $"活动 Profile：{state.Daemon.ActiveProfileId ?? "—"}";
        usageItem.Text = $"今日 Token：{state.Usage.Totals.TotalTokens.ToString("N0", CultureInfo.CurrentCulture)}";
        circuitItem.Text = $"目标熔断：{FormatCircuitSummary(state.Daemon.TargetCircuits)}";
        notifyIcon.Text = state.Daemon.Running
            ? "Local AI Gateway - Running"
            : "Local AI Gateway - Stopped";

        var busy = state.IsBusy;
        startItem.Enabled = !busy && !state.Daemon.Running;
        stopItem.Enabled = !busy && state.Daemon.Running;
        restartItem.Enabled = !busy && state.Daemon.Running;
        refreshItem.Enabled = !busy;
        profilesMenu.Enabled = !busy && state.Configuration.Profiles.Any(profile => profile.CanActivate);
        RebuildProfilesMenu(state);
        dashboard.Apply(state);

        if (state.Error is not null && state.Error.Code != lastBalloonErrorCode)
        {
            lastBalloonErrorCode = state.Error.Code;
            notifyIcon.ShowBalloonTip(
                5000,
                "Local AI Gateway",
                $"{state.Error.Message} ({state.Error.Code})",
                Forms.ToolTipIcon.Error);
        }
        else if (state.Error is null)
        {
            lastBalloonErrorCode = null;
        }
    }

    private void RebuildProfilesMenu(TrayState state)
    {
        profilesMenu.DropDownItems.Clear();
        foreach (var profile in state.Configuration.Profiles)
        {
            var item = new Forms.ToolStripMenuItem(profile.Name)
            {
                Checked = string.Equals(
                    profile.Id,
                    state.Configuration.SelectedProfileId,
                    StringComparison.OrdinalIgnoreCase),
                Enabled = profile.CanActivate,
                ToolTipText = profile.Id,
            };
            item.Click += (_, _) => RunOperation(
                token => coordinator.SwitchProfileAsync(profile.Id, token));
            profilesMenu.DropDownItems.Add(item);
        }

        if (profilesMenu.DropDownItems.Count == 0)
        {
            profilesMenu.DropDownItems.Add(new Forms.ToolStripMenuItem("没有 Profile") { Enabled = false });
        }
    }

    private async void RunOperation(Func<CancellationToken, Task<TrayState>> operation)
    {
        try
        {
            await operation(lifetime.ShutdownToken);
        }
        catch (OperationCanceledException) when (lifetime.ShutdownToken.IsCancellationRequested)
        {
        }
    }

    private void OnTimer(object? sender, EventArgs eventArgs)
    {
        if (!coordinator.State.IsBusy)
        {
            RunOperation(coordinator.RefreshAsync);
        }
    }

    private void ShowDashboard()
    {
        dashboard.Apply(coordinator.State);
        if (!dashboard.IsVisible)
        {
            dashboard.Show();
        }

        if (dashboard.WindowState == WindowState.Minimized)
        {
            dashboard.WindowState = WindowState.Normal;
        }

        dashboard.Activate();
    }

    private void OnDashboardClosing(object? sender, CancelEventArgs eventArgs)
    {
        if (!exiting)
        {
            eventArgs.Cancel = true;
            dashboard.Hide();
        }
    }

    private void Exit()
    {
        exiting = true;
        lifetime.RequestShutdown();
        application.Shutdown();
    }

    internal static string FormatCircuitSummary(IReadOnlyList<TargetCircuitStatus> circuits)
    {
        if (circuits.Count == 0)
        {
            return "—";
        }

        var open = circuits.Count(circuit => circuit.State == CircuitStates.Open);
        var halfOpen = circuits.Count(circuit => circuit.State == CircuitStates.HalfOpen);
        return open == 0 && halfOpen == 0
            ? $"正常（{circuits.Count} closed）"
            : $"open {open} / half-open {halfOpen} / closed {circuits.Count - open - halfOpen}";
    }
}
