using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using LocalAIGateway.Core.Usage;

namespace LocalAIGateway.Windows.Usage;

public sealed class PrivatePythonUsageSummaryReader : IUsageSummaryReader
{
    private const long MaximumWindowMilliseconds = 366L * 24 * 60 * 60 * 1000;
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(5);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private readonly string stateRoot;
    private readonly string usageRoot;
    private readonly string databasePath;
    private readonly string pythonPath;
    private readonly string scriptPath;
    private readonly IUsageQueryProcessRunner processRunner;

    public PrivatePythonUsageSummaryReader(string applicationRoot, string stateRoot)
        : this(
            Path.Combine(NormalizeRoot(applicationRoot, "application"), "runtime", "python", "python.exe"),
            Path.Combine(NormalizeRoot(applicationRoot, "application"), "runtime-tools", "aigw_usage_query.py"),
            NormalizeRoot(stateRoot, "state"),
            new UsageQueryProcessRunner(DefaultTimeout))
    {
    }

    internal PrivatePythonUsageSummaryReader(
        string pythonPath,
        string scriptPath,
        string stateRoot,
        IUsageQueryProcessRunner processRunner)
    {
        this.pythonPath = NormalizeFilePath(pythonPath, "private Python");
        this.scriptPath = NormalizeFilePath(scriptPath, "usage query script");
        this.stateRoot = NormalizeRoot(stateRoot, "state");
        usageRoot = Path.Combine(this.stateRoot, "usage");
        databasePath = Path.Combine(usageRoot, "usage.db");
        this.processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
    }

    public async Task<UsageSummary> ReadAsync(
        DateTimeOffset windowStartUtc,
        DateTimeOffset windowEndUtc,
        CancellationToken cancellationToken = default)
    {
        var startMilliseconds = windowStartUtc.ToUniversalTime().ToUnixTimeMilliseconds();
        var endMilliseconds = windowEndUtc.ToUniversalTime().ToUnixTimeMilliseconds();
        if (startMilliseconds < 0 ||
            endMilliseconds <= startMilliseconds ||
            endMilliseconds - startMilliseconds > MaximumWindowMilliseconds)
        {
            throw new UsageException(
                "aigw_usage_window_invalid",
                "The usage query window must be positive, UTC-representable, and no longer than 366 days.");
        }

        ValidateNoReparsePoint(stateRoot);
        ValidateNoReparsePoint(usageRoot);
        if (!File.Exists(databasePath))
        {
            return Empty(startMilliseconds, endMilliseconds);
        }
        ValidateNoReparsePoint(databasePath);
        ValidateRequiredFile(pythonPath, "aigw_usage_runtime_missing");
        ValidateRequiredFile(scriptPath, "aigw_usage_query_missing");

        var result = await processRunner.RunAsync(
            pythonPath,
            scriptPath,
            databasePath,
            startMilliseconds,
            endMilliseconds,
            cancellationToken);
        if (result.ExitCode != 0)
        {
            if (result.ExitCode == 20 &&
                result.StandardOutput.Contains(
                    "aigw_usage_schema_unsupported",
                    StringComparison.Ordinal))
            {
                throw new UsageException(
                    "aigw_usage_schema_unsupported",
                    "The usage database schema is not supported by this Local AI Gateway version.");
            }

            throw new UsageException(
                "aigw_usage_query_failed",
                "The private usage query process did not complete successfully.");
        }

        if (result.StandardOutput.Length > 1024 * 1024)
        {
            throw InvalidResult();
        }

        try
        {
            var document = JsonSerializer.Deserialize<UsageSummaryDocument>(
                result.StandardOutput,
                JsonOptions) ?? throw InvalidResult();
            return Validate(document, startMilliseconds, endMilliseconds);
        }
        catch (UsageException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new UsageException(
                "aigw_usage_result_invalid",
                "The private usage query returned malformed data.",
                exception);
        }
    }

    private static UsageSummary Validate(
        UsageSummaryDocument document,
        long expectedStartMilliseconds,
        long expectedEndMilliseconds)
    {
        if (document.SchemaVersion != 1 ||
            !document.DatabasePresent ||
            document.WindowStartUtcMilliseconds != expectedStartMilliseconds ||
            document.WindowEndUtcMilliseconds != expectedEndMilliseconds ||
            document.Totals is null ||
            document.Groups is null ||
            document.RecentErrors is null ||
            document.Groups.Count > 10_000 ||
            document.RecentErrors.Count > 20)
        {
            throw InvalidResult();
        }

        var totals = ValidateTotals(document.Totals);
        var groups = document.Groups.Select(group =>
        {
            if (group.Totals is null)
            {
                throw InvalidResult();
            }
            return new UsageBreakdown(
                ValidateIdentifier(group.ProfileId),
                ValidateIdentifier(group.ProviderId),
                ValidateIdentifier(group.ModelAlias),
                ValidateTotals(group.Totals));
        }).ToArray();
        var errors = document.RecentErrors.Select(error =>
        {
            if (error.OccurredUtcMilliseconds < expectedStartMilliseconds ||
                error.OccurredUtcMilliseconds >= expectedEndMilliseconds)
            {
                throw InvalidResult();
            }
            return new UsageRecentError(
                error.OccurredUtcMilliseconds,
                ValidateIdentifier(error.ProfileId),
                ValidateIdentifier(error.ProviderId),
                ValidateIdentifier(error.ModelAlias),
                ValidateIdentifier(error.ErrorCode, 64));
        }).ToArray();

        if (groups.Sum(group => group.Totals.RequestCount) != totals.RequestCount ||
            groups.Sum(group => group.Totals.SuccessCount) != totals.SuccessCount ||
            groups.Sum(group => group.Totals.FailureCount) != totals.FailureCount ||
            groups.Sum(group => group.Totals.InputTokens) != totals.InputTokens ||
            groups.Sum(group => group.Totals.OutputTokens) != totals.OutputTokens ||
            groups.Sum(group => group.Totals.TotalTokens) != totals.TotalTokens)
        {
            throw InvalidResult();
        }

        return new UsageSummary(
            DatabasePresent: true,
            expectedStartMilliseconds,
            expectedEndMilliseconds,
            totals,
            groups,
            errors);
    }

    private static UsageTotals ValidateTotals(UsageTotalsDocument totals)
    {
        if (totals.RequestCount < 0 ||
            totals.SuccessCount < 0 ||
            totals.FailureCount < 0 ||
            totals.InputTokens < 0 ||
            totals.OutputTokens < 0 ||
            totals.TotalTokens < 0 ||
            totals.SuccessCount + totals.FailureCount != totals.RequestCount)
        {
            throw InvalidResult();
        }
        return new UsageTotals(
            totals.RequestCount,
            totals.SuccessCount,
            totals.FailureCount,
            totals.InputTokens,
            totals.OutputTokens,
            totals.TotalTokens);
    }

    private static string ValidateIdentifier(string? value, int maximumLength = 128)
    {
        if (string.IsNullOrEmpty(value) ||
            value.Length > maximumLength ||
            value.Any(char.IsControl))
        {
            throw InvalidResult();
        }
        return value;
    }

    private static UsageSummary Empty(long startMilliseconds, long endMilliseconds) => new(
        DatabasePresent: false,
        startMilliseconds,
        endMilliseconds,
        new UsageTotals(0, 0, 0, 0, 0, 0),
        Array.Empty<UsageBreakdown>(),
        Array.Empty<UsageRecentError>());

    private static void ValidateRequiredFile(string path, string errorCode)
    {
        if (!File.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UsageException(errorCode, "A required private usage query component is missing or unsafe.");
        }
    }

    private static void ValidateNoReparsePoint(string path)
    {
        if ((Directory.Exists(path) || File.Exists(path)) &&
            (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UsageException(
                "aigw_usage_path_unsafe",
                "The fixed usage data path contains a reparse point.");
        }
    }

    private static string NormalizeRoot(string path, string label)
    {
        var normalized = NormalizeFilePath(path, label).TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        var volumeRoot = Path.GetPathRoot(normalized)?.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        if (string.Equals(normalized, volumeRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException($"The {label} root must not be a volume root.", nameof(path));
        }
        return normalized;
    }

    private static string NormalizeFilePath(string path, string label)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw new ArgumentException($"The {label} path must be fully qualified.", nameof(path));
        }
        return Path.GetFullPath(path);
    }

    private static UsageException InvalidResult() => new(
        "aigw_usage_result_invalid",
        "The private usage query returned data outside the supported contract.");

    private sealed record UsageSummaryDocument
    {
        public int SchemaVersion { get; init; }
        public bool DatabasePresent { get; init; }
        public long WindowStartUtcMilliseconds { get; init; }
        public long WindowEndUtcMilliseconds { get; init; }
        public UsageTotalsDocument? Totals { get; init; }
        public List<UsageBreakdownDocument>? Groups { get; init; }
        public List<UsageRecentErrorDocument>? RecentErrors { get; init; }
    }

    private sealed record UsageTotalsDocument
    {
        public long RequestCount { get; init; }
        public long SuccessCount { get; init; }
        public long FailureCount { get; init; }
        public long InputTokens { get; init; }
        public long OutputTokens { get; init; }
        public long TotalTokens { get; init; }
    }

    private sealed record UsageBreakdownDocument
    {
        public string? ProfileId { get; init; }
        public string? ProviderId { get; init; }
        public string? ModelAlias { get; init; }
        public UsageTotalsDocument? Totals { get; init; }
    }

    private sealed record UsageRecentErrorDocument
    {
        public long OccurredUtcMilliseconds { get; init; }
        public string? ProfileId { get; init; }
        public string? ProviderId { get; init; }
        public string? ModelAlias { get; init; }
        public string? ErrorCode { get; init; }
    }
}

internal sealed record UsageQueryProcessResult(int ExitCode, string StandardOutput);

internal interface IUsageQueryProcessRunner
{
    Task<UsageQueryProcessResult> RunAsync(
        string pythonPath,
        string scriptPath,
        string databasePath,
        long startMilliseconds,
        long endMilliseconds,
        CancellationToken cancellationToken);
}

internal sealed class UsageQueryProcessRunner(TimeSpan timeout) : IUsageQueryProcessRunner
{
    public async Task<UsageQueryProcessResult> RunAsync(
        string pythonPath,
        string scriptPath,
        string databasePath,
        long startMilliseconds,
        long endMilliseconds,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = pythonPath,
            WorkingDirectory = Path.GetDirectoryName(scriptPath)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("-B");
        startInfo.ArgumentList.Add("-I");
        startInfo.ArgumentList.Add(scriptPath);
        startInfo.ArgumentList.Add(databasePath);
        startInfo.ArgumentList.Add(startMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture));
        startInfo.ArgumentList.Add(endMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture));
        startInfo.Environment.Clear();
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot))
        {
            startInfo.Environment["SystemRoot"] = systemRoot;
        }
        startInfo.Environment["PYTHONNOUSERSITE"] = "1";
        startInfo.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        startInfo.Environment["PYTHONUTF8"] = "1";

        try
        {
            using var process = Process.Start(startInfo) ?? throw StartFailed();
            var outputTask = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            var errorTask = process.StandardError.ReadToEndAsync(CancellationToken.None);
            using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutSource.CancelAfter(timeout);
            try
            {
                await process.WaitForExitAsync(timeoutSource.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                Kill(process);
                throw new UsageException(
                    "aigw_usage_query_timeout",
                    "The private usage query exceeded its time limit.");
            }
            catch (OperationCanceledException)
            {
                Kill(process);
                throw;
            }
            var output = await outputTask;
            await errorTask;
            return new UsageQueryProcessResult(process.ExitCode, output.Trim());
        }
        catch (UsageException)
        {
            throw;
        }
        catch (Win32Exception exception)
        {
            throw StartFailed(exception);
        }
        catch (IOException exception)
        {
            throw new UsageException(
                "aigw_usage_query_failed",
                "The private usage query process could not be completed.",
                exception);
        }
    }

    private static void Kill(Process process)
    {
        if (!process.HasExited)
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit();
        }
    }

    private static UsageException StartFailed(Exception? innerException = null) => new(
        "aigw_usage_query_start_failed",
        "Windows could not start the private usage query process.",
        innerException);
}
