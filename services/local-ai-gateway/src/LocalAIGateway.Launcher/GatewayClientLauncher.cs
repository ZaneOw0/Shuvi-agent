using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Launcher;

public sealed class GatewayClientLauncher : IClientLaunchService
{
    public const string GatewayBaseUrl = "http://127.0.0.1:4000";

    private readonly IGatewayDaemonController daemon;
    private readonly ICredentialStore credentialStore;
    private readonly IClientProcessRunner processRunner;
    private readonly CurrentUserInstallationTarget target;

    public GatewayClientLauncher(
        IGatewayDaemonController daemon,
        ICredentialStore credentialStore,
        CurrentUserInstallationTarget target)
        : this(daemon, credentialStore, new ClientProcessRunner(), target)
    {
    }

    internal GatewayClientLauncher(
        IGatewayDaemonController daemon,
        ICredentialStore credentialStore,
        IClientProcessRunner processRunner,
        CurrentUserInstallationTarget target)
    {
        ArgumentNullException.ThrowIfNull(daemon);
        ArgumentNullException.ThrowIfNull(credentialStore);
        ArgumentNullException.ThrowIfNull(processRunner);
        ArgumentNullException.ThrowIfNull(target);
        this.daemon = daemon;
        this.credentialStore = credentialStore;
        this.processRunner = processRunner;
        this.target = target;
    }

    public async Task<int> LaunchAsync(
        ClientLaunchRequest request,
        CancellationToken cancellationToken = default)
    {
        ClientLaunchValidation.Validate(request);

        var token = await credentialStore.GetSecretAsync(
            target.RuntimeCredentialTarget,
            cancellationToken);
        if (!RuntimeClientTokenGenerator.IsGeneratedFormat(token))
        {
            throw new ClientLaunchException(
                "aigw_launcher_runtime_credential_invalid",
                "The installed Local AI Gateway client credential is missing or malformed.");
        }

        await daemon.StartAsync(target, cancellationToken);
        return await processRunner.RunAsync(
            request,
            GatewayBaseUrl,
            token!,
            cancellationToken);
    }
}
