namespace LocalAIGateway.Core.Configuration;

public static class CredentialTargets
{
    public const string RuntimeClientToken = "LocalAIGateway/runtime/client-token";

    public static string UpstreamApiKey(string profileId, string providerId) =>
        $"LocalAIGateway/{profileId}/{providerId}/api-key";
}
