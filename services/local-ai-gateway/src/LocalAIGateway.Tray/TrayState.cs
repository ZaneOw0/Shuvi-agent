using LocalAIGateway.Core.Usage;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Tray;

public enum TrayActivity
{
    Idle,
    Refreshing,
    Starting,
    Stopping,
    Restarting,
    SwitchingProfile,
}

public sealed record TrayProfile(string Id, string Name, bool CanActivate)
{
    public override string ToString() => Name;
}

public sealed record TrayConfigurationSnapshot(
    long Revision,
    string? SelectedProfileId,
    IReadOnlyList<TrayProfile> Profiles)
{
    public static TrayConfigurationSnapshot Empty { get; } = new(0, null, []);
}

public sealed record TrayError(string Code, string Message);

public sealed record TrayState(
    TrayActivity Activity,
    GatewayDaemonStatus Daemon,
    TrayConfigurationSnapshot Configuration,
    UsageSummary Usage,
    TrayError? Error,
    DateTimeOffset? RefreshedAtUtc)
{
    public bool IsBusy => Activity != TrayActivity.Idle;

    public static TrayState Initial { get; } = new(
        TrayActivity.Idle,
        new GatewayDaemonStatus(false, null, null, null, false, null, []),
        TrayConfigurationSnapshot.Empty,
        new UsageSummary(
            false,
            0,
            0,
            new UsageTotals(0, 0, 0, 0, 0, 0),
            [],
            []),
        null,
        null);
}
