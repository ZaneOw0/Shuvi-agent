namespace LocalAIGateway.Core.Usage;

public sealed record UsageTotals(
    long RequestCount,
    long SuccessCount,
    long FailureCount,
    long InputTokens,
    long OutputTokens,
    long TotalTokens);

public sealed record UsageBreakdown(
    string ProfileId,
    string ProviderId,
    string ModelAlias,
    UsageTotals Totals);

public sealed record UsageRecentError(
    long OccurredUtcMilliseconds,
    string ProfileId,
    string ProviderId,
    string ModelAlias,
    string ErrorCode);

public sealed record UsageSummary(
    bool DatabasePresent,
    long WindowStartUtcMilliseconds,
    long WindowEndUtcMilliseconds,
    UsageTotals Totals,
    IReadOnlyList<UsageBreakdown> Groups,
    IReadOnlyList<UsageRecentError> RecentErrors);

public interface IUsageSummaryReader
{
    Task<UsageSummary> ReadAsync(
        DateTimeOffset windowStartUtc,
        DateTimeOffset windowEndUtc,
        CancellationToken cancellationToken = default);
}

public sealed class UsageException : Exception
{
    public UsageException(string errorCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(errorCode);
        ErrorCode = errorCode;
    }

    public string ErrorCode { get; }
}
