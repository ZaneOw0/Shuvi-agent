using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Tray;

public interface ITrayProfileStore
{
    Task<TrayConfigurationSnapshot> LoadAsync(CancellationToken cancellationToken = default);

    Task<TrayConfigurationSnapshot> SelectAsync(
        string profileId,
        CancellationToken cancellationToken = default);
}

public sealed class GatewayTrayProfileStore(GatewayConfigurationManager manager) : ITrayProfileStore
{
    public async Task<TrayConfigurationSnapshot> LoadAsync(
        CancellationToken cancellationToken = default) =>
        ToSnapshot(await manager.LoadAsync(cancellationToken));

    public async Task<TrayConfigurationSnapshot> SelectAsync(
        string profileId,
        CancellationToken cancellationToken = default) =>
        ToSnapshot(await manager.UseProfileAsync(profileId, cancellationToken));

    private static TrayConfigurationSnapshot ToSnapshot(GatewayConfiguration configuration) =>
        new(
            configuration.Revision,
            configuration.ActiveProfileId,
            configuration.Profiles
                .Select(profile => new TrayProfile(
                    profile.Id,
                    profile.Name,
                    ConfigurationValidator.IsActivatable(profile)))
                .OrderBy(profile => profile.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(profile => profile.Id, StringComparer.OrdinalIgnoreCase)
                .ToArray());
}
