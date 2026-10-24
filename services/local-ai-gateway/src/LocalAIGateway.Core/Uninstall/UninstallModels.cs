namespace LocalAIGateway.Core.Uninstall;

public enum UninstallChoice
{
    Keep,
    Remove,
}

public sealed record UninstallSelection(
    UninstallChoice Program,
    UninstallChoice Autostart,
    UninstallChoice Integrations,
    UninstallChoice RuntimeCredential,
    UninstallChoice ProviderCredentials,
    UninstallChoice Configuration,
    UninstallChoice Usage,
    UninstallChoice Logs,
    UninstallChoice Backups);

public sealed record UninstallIntegrationTarget(string Client, string TargetPath);

public sealed record UninstallRequest(
    UninstallSelection Selection,
    IReadOnlyList<UninstallIntegrationTarget> IntegrationTargets,
    IReadOnlyList<string> BackupPaths,
    bool Confirmed);

public sealed record UninstallCategoryResult(
    bool Selected,
    bool Changed,
    bool AlreadyAbsent,
    IReadOnlyList<string> PreservedPaths);

public sealed record UninstallResult(
    UninstallCategoryResult Program,
    UninstallCategoryResult Autostart,
    UninstallCategoryResult Integrations,
    UninstallCategoryResult RuntimeCredential,
    UninstallCategoryResult ProviderCredentials,
    UninstallCategoryResult Configuration,
    UninstallCategoryResult Usage,
    UninstallCategoryResult Logs,
    UninstallCategoryResult Backups,
    bool CompletionPending,
    string? OperationId,
    string? ReceiptPath);

public interface IUninstallService
{
    Task<UninstallResult> UninstallAsync(
        UninstallRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class UninstallException : Exception
{
    public UninstallException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
