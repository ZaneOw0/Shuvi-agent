using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LocalAIGateway.Core.Control;
using MediaBrush = System.Windows.Media.Brush;
using MediaColor = System.Windows.Media.Color;
using MediaColorConverter = System.Windows.Media.ColorConverter;
using WpfButton = System.Windows.Controls.Button;
using WpfComboBox = System.Windows.Controls.ComboBox;

namespace LocalAIGateway.Tray;

internal partial class TrayDashboardWindow : Window
{
    private static readonly SolidColorBrush RunningBackground = Brush("#E8F5F0");
    private static readonly SolidColorBrush RunningBorder = Brush("#E8F5F0");
    private static readonly SolidColorBrush RunningForeground = Brush("#0A7A5E");
    private static readonly SolidColorBrush RunningDot = Brush("#10A37F");
    private static readonly SolidColorBrush StoppedBackground = Brush("#F5F5F5");
    private static readonly SolidColorBrush StoppedBorder = Brush("#F5F5F5");
    private static readonly SolidColorBrush StoppedForeground = Brush("#6E6E6E");
    private static readonly SolidColorBrush StoppedDot = Brush("#9B9B9B");
    private static readonly SolidColorBrush WarningBackground = Brush("#FFF7E6");
    private static readonly SolidColorBrush WarningBorder = Brush("#FFF7E6");
    private static readonly SolidColorBrush WarningForeground = Brush("#9A6700");
    private static readonly SolidColorBrush WarningDot = Brush("#F5A623");
    private static readonly SolidColorBrush DangerBackground = Brush("#FFF4F4");
    private static readonly SolidColorBrush DangerBorder = Brush("#FFF4F4");
    private static readonly SolidColorBrush DangerForeground = Brush("#B3262B");
    private static readonly SolidColorBrush MutedForeground = Brush("#6E6E6E");
    private static readonly SolidColorBrush Hairline = Brush("#E5E5E5");

    private TrayState currentState = TrayState.Initial;

    public TrayDashboardWindow()
    {
        InitializeComponent();
        Apply(TrayState.Initial);
    }

    public event EventHandler? StartRequested;

    public event EventHandler? StopRequested;

    public event EventHandler? RestartRequested;

    public event EventHandler? RefreshRequested;

    public event EventHandler<string>? ProfileSwitchRequested;

    internal ScrollViewer ContentScrollViewerForTesting => DashboardContentScrollViewer;

    internal FrameworkElement ActionBarForTesting => DashboardActionBar;

    internal WpfButton StartButtonForTesting => StartButton;

    internal WpfButton RefreshButtonForTesting => RefreshButton;

    internal WpfComboBox ProfileSelectorForTesting => ProfileSelector;

    internal int CircuitRowCountForTesting => CircuitRows.Children.Count;

    public void Apply(TrayState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        currentState = state;

        ApplyDaemonState(state);
        ApplyUsage(state);
        ApplyProfiles(state);
        ApplyCircuits(state);
        ApplyError(state.Error);
        ApplyActions(state);
    }

    private void ApplyDaemonState(TrayState state)
    {
        var status = state.Daemon.Running
            ? state.Daemon.Switching ? "切换中" : "运行中"
            : "已停止";
        DaemonValue.Text = status;
        DaemonDetailValue.Text = state.Daemon.Running
            ? state.Daemon.Switching
                ? "正在准备新的 Profile，现有请求不会中断。"
                : state.Daemon.ActiveProfileId is null
                    ? "网关已经启动，正在同步 Profile。"
                    : $"正在通过 {state.Daemon.ActiveProfileId} 提供服务。"
            : "网关现在没有运行。启动后，本地应用就可以连接。";
        StatusBadgeText.Text = status;
        RefreshedAtValue.Text = state.RefreshedAtUtc?.ToLocalTime().ToString("HH:mm:ss", CultureInfo.CurrentCulture) ?? "—";
        ActivityValue.Text = state.IsBusy ? FormatActivity(state.Activity) : "状态已同步";

        if (state.Daemon.Switching)
        {
            SetStatusPalette(WarningBackground, WarningBorder, WarningForeground, WarningDot);
        }
        else if (state.Daemon.Running)
        {
            SetStatusPalette(RunningBackground, RunningBorder, RunningForeground, RunningDot);
        }
        else
        {
            SetStatusPalette(StoppedBackground, StoppedBorder, StoppedForeground, StoppedDot);
        }
    }

    private void ApplyUsage(TrayState state)
    {
        var totals = state.Usage.Totals;
        TokenValue.Text = totals.TotalTokens.ToString("N0", CultureInfo.CurrentCulture);
        RequestValue.Text = totals.RequestCount.ToString("N0", CultureInfo.CurrentCulture);
        RequestDetailValue.Text = $"成功 {totals.SuccessCount:N0} · 失败 {totals.FailureCount:N0}";
        SuccessRateValue.Text = totals.RequestCount == 0
            ? "—"
            : ((double)totals.SuccessCount / totals.RequestCount).ToString("P0", CultureInfo.CurrentCulture);
    }

    private void ApplyProfiles(TrayState state)
    {
        ActiveProfileValue.Text = state.Daemon.ActiveProfileId ?? "—";
        ConfiguredProfileValue.Text = state.Configuration.SelectedProfileId ?? "—";

        var profiles = state.Configuration.Profiles.Where(profile => profile.CanActivate).ToArray();
        ProfileSelector.ItemsSource = profiles;
        ProfileSelector.SelectedItem = profiles.FirstOrDefault(profile => string.Equals(
            profile.Id,
            state.Configuration.SelectedProfileId,
            StringComparison.OrdinalIgnoreCase));
    }

    private void ApplyCircuits(TrayState state)
    {
        CircuitRows.Children.Clear();
        CircuitSummaryValue.Text = TrayShell.FormatCircuitSummary(state.Daemon.TargetCircuits);
        if (state.Daemon.TargetCircuits.Count == 0)
        {
            CircuitRows.Children.Add(new TextBlock
            {
                Text = "启动网关后，这里会显示每个模型目标的连接状态。",
                Foreground = MutedForeground,
                Margin = new Thickness(0, 5, 0, 2),
            });
            return;
        }

        for (var index = 0; index < state.Daemon.TargetCircuits.Count; index++)
        {
            var circuit = state.Daemon.TargetCircuits[index];
            CircuitRows.Children.Add(CreateCircuitRow(circuit, index != 0));
        }
    }

    private void ApplyError(TrayError? error)
    {
        ErrorCard.Visibility = error is null ? Visibility.Collapsed : Visibility.Visible;
        ErrorValue.Text = error is null ? string.Empty : $"{error.Message} ({error.Code})";
    }

    private void ApplyActions(TrayState state)
    {
        StartButton.IsEnabled = !state.IsBusy && !state.Daemon.Running;
        StopButton.IsEnabled = !state.IsBusy && state.Daemon.Running;
        RestartButton.IsEnabled = !state.IsBusy && state.Daemon.Running;
        RefreshButton.IsEnabled = !state.IsBusy;
        SwitchButton.IsEnabled = !state.IsBusy && ProfileSelector.SelectedItem is not null;
    }

    private Border CreateCircuitRow(TargetCircuitStatus circuit, bool hasTopBorder)
    {
        var stateForeground = circuit.State switch
        {
            CircuitStates.Open => DangerForeground,
            CircuitStates.HalfOpen => WarningForeground,
            _ => RunningForeground,
        };
        var stateBackground = circuit.State switch
        {
            CircuitStates.Open => DangerBackground,
            CircuitStates.HalfOpen => WarningBackground,
            _ => RunningBackground,
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var identity = new StackPanel();
        identity.Children.Add(new TextBlock
        {
            Text = $"{circuit.ProviderId} / {circuit.ModelAlias}",
            FontWeight = FontWeights.Medium,
        });
        identity.Children.Add(new TextBlock
        {
            Text = circuit.OpenUntilUtc is null
                ? $"连续失败 {circuit.ConsecutiveFailures}"
                : $"连续失败 {circuit.ConsecutiveFailures} · 至 {circuit.OpenUntilUtc.Value.ToLocalTime():HH:mm:ss}",
            Foreground = MutedForeground,
            FontSize = 11,
            Margin = new Thickness(0, 4, 0, 0),
        });
        grid.Children.Add(identity);

        var statePill = new Border
        {
            Background = stateBackground,
            CornerRadius = new CornerRadius(99),
            Padding = new Thickness(10, 5, 10, 5),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = circuit.State,
                Foreground = stateForeground,
                FontSize = 11,
                FontWeight = FontWeights.Medium,
            },
        };
        Grid.SetColumn(statePill, 1);
        grid.Children.Add(statePill);

        return new Border
        {
            BorderBrush = Hairline,
            BorderThickness = hasTopBorder ? new Thickness(0, 1, 0, 0) : new Thickness(0),
            Padding = hasTopBorder ? new Thickness(0, 12, 0, 0) : new Thickness(0, 2, 0, 0),
            Margin = hasTopBorder ? new Thickness(0, 12, 0, 0) : new Thickness(0),
            Child = grid,
        };
    }

    private void SetStatusPalette(MediaBrush background, MediaBrush border, MediaBrush foreground, MediaBrush dot)
    {
        StatusBadge.Background = background;
        StatusBadge.BorderBrush = border;
        StatusBadgeText.Foreground = foreground;
        StatusDot.Fill = dot;
    }

    private static string FormatActivity(TrayActivity activity) => activity switch
    {
        TrayActivity.Refreshing => "正在刷新",
        TrayActivity.Starting => "正在启动",
        TrayActivity.Stopping => "正在停止",
        TrayActivity.Restarting => "正在重启",
        TrayActivity.SwitchingProfile => "正在切换 Profile",
        _ => "空闲",
    };

    private static SolidColorBrush Brush(string value)
    {
        var brush = new SolidColorBrush((MediaColor)MediaColorConverter.ConvertFromString(value));
        brush.Freeze();
        return brush;
    }

    private void OnProfileSelectionChanged(object sender, SelectionChangedEventArgs eventArgs) =>
        SwitchButton.IsEnabled = !currentState.IsBusy && ProfileSelector.SelectedItem is not null;

    private void OnSwitchProfileClick(object sender, RoutedEventArgs eventArgs)
    {
        if (ProfileSelector.SelectedItem is TrayProfile profile)
        {
            ProfileSwitchRequested?.Invoke(this, profile.Id);
        }
    }

    private void OnStartClick(object sender, RoutedEventArgs eventArgs) =>
        StartRequested?.Invoke(this, EventArgs.Empty);

    private void OnStopClick(object sender, RoutedEventArgs eventArgs) =>
        StopRequested?.Invoke(this, EventArgs.Empty);

    private void OnRestartClick(object sender, RoutedEventArgs eventArgs) =>
        RestartRequested?.Invoke(this, EventArgs.Empty);

    private void OnRefreshClick(object sender, RoutedEventArgs eventArgs) =>
        RefreshRequested?.Invoke(this, EventArgs.Empty);
}
