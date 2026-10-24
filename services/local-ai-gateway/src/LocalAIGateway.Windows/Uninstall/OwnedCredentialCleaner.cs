using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Installation;

namespace LocalAIGateway.Windows.Uninstall;

public sealed record OwnedCredentialCleanupRequest(
    bool RemoveRuntimeCredential,
    bool RemoveProviderCredentials);

public sealed record OwnedCredentialCleanupResult(
    bool RuntimeSelected,
    bool RuntimeDeleted,
    bool RuntimeAlreadyAbsent,
    bool ProvidersSelected,
    IReadOnlyList<string> DeletedProviderTargets,
    IReadOnlyList<string> PreservedTargets);

public sealed class OwnedCredentialCleaner
{
    public const string OwnedPrefix = "LocalAIGateway/";

    private readonly ICredentialStore credentialStore;
    private readonly ICredentialTargetCatalog targetCatalog;

    public OwnedCredentialCleaner(
        ICredentialStore credentialStore,
        ICredentialTargetCatalog targetCatalog)
    {
        this.credentialStore = credentialStore ?? throw new ArgumentNullException(nameof(credentialStore));
        this.targetCatalog = targetCatalog ?? throw new ArgumentNullException(nameof(targetCatalog));
    }

    public async Task<OwnedCredentialCleanupResult> CleanAsync(
        OwnedCredentialCleanupRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var targets = await targetCatalog.ListTargetsAsync(OwnedPrefix, cancellationToken);
        var runtimePresent = targets.Contains(CredentialTargets.RuntimeClientToken, StringComparer.Ordinal);
        var providerTargets = targets.Where(IsProviderTarget).ToArray();
        var preservedTargets = targets.Where(target =>
                (!request.RemoveRuntimeCredential ||
                 !target.Equals(CredentialTargets.RuntimeClientToken, StringComparison.Ordinal)) &&
                (!request.RemoveProviderCredentials || !IsProviderTarget(target)))
            .OrderBy(target => target, StringComparer.Ordinal)
            .ToArray();

        cancellationToken.ThrowIfCancellationRequested();
        var deletedProviderTargets = new List<string>();
        var runtimeDeleted = false;
        try
        {
            // Once credential mutation begins, finish the selected exact targets or report failure.
            if (request.RemoveProviderCredentials)
            {
                foreach (var target in providerTargets)
                {
                    await credentialStore.DeleteSecretAsync(target, CancellationToken.None);
                    deletedProviderTargets.Add(target);
                }
            }

            if (request.RemoveRuntimeCredential && runtimePresent)
            {
                await credentialStore.DeleteSecretAsync(
                    CredentialTargets.RuntimeClientToken,
                    CancellationToken.None);
                runtimeDeleted = true;
            }

            var remaining = await targetCatalog.ListTargetsAsync(OwnedPrefix, CancellationToken.None);
            if ((request.RemoveRuntimeCredential &&
                 remaining.Contains(CredentialTargets.RuntimeClientToken, StringComparer.Ordinal)) ||
                (request.RemoveProviderCredentials && remaining.Any(IsProviderTarget)))
            {
                throw new InstallationException(
                    "aigw_uninstall_credential_verification_failed",
                    "One or more selected Local AI Gateway credentials still exist after deletion.");
            }
        }
        catch (InstallationException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new InstallationException(
                "aigw_uninstall_credential_failed",
                "One or more selected Local AI Gateway credentials could not be deleted.",
                exception);
        }

        return new OwnedCredentialCleanupResult(
            request.RemoveRuntimeCredential,
            runtimeDeleted,
            request.RemoveRuntimeCredential && !runtimePresent,
            request.RemoveProviderCredentials,
            deletedProviderTargets,
            preservedTargets);
    }

    internal static bool IsProviderTarget(string target)
    {
        if (string.IsNullOrEmpty(target) || !target.StartsWith(OwnedPrefix, StringComparison.Ordinal))
        {
            return false;
        }

        var segments = target.Split('/');
        return segments.Length == 4 &&
               segments[0].Equals("LocalAIGateway", StringComparison.Ordinal) &&
               segments[1].Length > 0 &&
               segments[2].Length > 0 &&
               segments[3].Equals("api-key", StringComparison.Ordinal);
    }
}
