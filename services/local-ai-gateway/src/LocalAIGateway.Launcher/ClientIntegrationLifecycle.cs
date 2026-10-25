namespace LocalAIGateway.Launcher;

public enum ClientIntegrationStatusKind
{
    Absent,
    NotIntegrated,
    Owned,
}

public enum ClientIntegrationRemovalAction
{
    None,
    Update,
    Delete,
}

public sealed record ClientIntegrationStatusRequest(
    ClientIntegrationKind Client,
    string TargetPath);

public sealed record ClientIntegrationStatusResult(
    ClientIntegrationKind Client,
    string TargetPath,
    ClientIntegrationStatusKind Status,
    ClientIntegrationRemovalAction Action,
    string? BeforeSha256,
    string? AfterSha256,
    string? ManagedDiff,
    string? ProposedContent);

public sealed record ClientIntegrationUnintegrateRequest(
    ClientIntegrationKind Client,
    string TargetPath,
    string ExpectedBeforeSha256,
    string? ExpectedAfterSha256,
    bool ExpectDelete,
    bool Confirmed);

public sealed record ClientIntegrationUnintegrateResult(
    ClientIntegrationKind Client,
    string TargetPath,
    ClientIntegrationRemovalAction Action,
    bool Applied,
    string? BackupPath,
    string BeforeSha256,
    string? AfterSha256);

public interface IClientIntegrationLifecycleManager
{
    Task<ClientIntegrationStatusResult> GetStatusAsync(
        ClientIntegrationStatusRequest request,
        CancellationToken cancellationToken = default);

    Task<ClientIntegrationUnintegrateResult> UnintegrateAsync(
        ClientIntegrationUnintegrateRequest request,
        CancellationToken cancellationToken = default);
}
