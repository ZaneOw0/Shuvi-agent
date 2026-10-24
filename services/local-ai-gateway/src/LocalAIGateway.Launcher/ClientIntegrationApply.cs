namespace LocalAIGateway.Launcher;

public sealed record ClientIntegrationApplyRequest(
    ClientIntegrationKind Client,
    string TargetPath,
    string ClientVersion,
    string? ExpectedBeforeSha256,
    bool ExpectAbsent,
    string ExpectedAfterSha256,
    bool Confirmed,
    string? HostVersion = null,
    string? WrapperExecutablePath = null);

public sealed record ClientIntegrationApplyResult(
    ClientIntegrationKind Client,
    string TargetPath,
    ClientIntegrationAction Action,
    bool Applied,
    string? BackupPath,
    string? BeforeSha256,
    string AfterSha256);

public interface IClientIntegrationApplier
{
    Task<ClientIntegrationApplyResult> ApplyAsync(
        ClientIntegrationApplyRequest request,
        CancellationToken cancellationToken = default);
}
