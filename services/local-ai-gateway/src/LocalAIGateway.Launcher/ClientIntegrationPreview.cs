namespace LocalAIGateway.Launcher;

public sealed record ClientIntegrationPreviewRequest(
    ClientIntegrationKind Client,
    string TargetPath,
    string? ExistingContent,
    string ClientVersion,
    string? HostVersion = null,
    string? WrapperExecutablePath = null);

public sealed record ClientIntegrationPreviewResult(
    ClientIntegrationKind Client,
    string TargetPath,
    ClientIntegrationAction Action,
    string? BeforeSha256,
    string AfterSha256,
    string ManagedDiff,
    string ProposedContent);

public interface IClientIntegrationPreviewer
{
    ClientIntegrationPreviewResult Preview(ClientIntegrationPreviewRequest request);
}
