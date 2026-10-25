using LocalAIGateway.Core.Usage;
using LocalAIGateway.Windows.Usage;

namespace LocalAIGateway.Windows.Tests;

public sealed class PrivatePythonUsageSummaryReaderTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-UsageReader-{Guid.NewGuid():N}");

    [Fact]
    public async Task Missing_database_returns_zero_without_starting_python_or_creating_state()
    {
        var runner = new FakeRunner(0, "unused");
        var reader = CreateReader(runner);
        var start = DateTimeOffset.FromUnixTimeMilliseconds(1_000);
        var end = DateTimeOffset.FromUnixTimeMilliseconds(2_000);

        var result = await reader.ReadAsync(start, end);

        Assert.False(result.DatabasePresent);
        Assert.Equal(0, result.Totals.RequestCount);
        Assert.Empty(result.Groups);
        Assert.Empty(result.RecentErrors);
        Assert.Equal(0, runner.CallCount);
        Assert.False(Directory.Exists(root));
    }

    [Fact]
    public async Task Valid_result_is_strictly_mapped_and_preserves_only_bounded_metadata()
    {
        PrepareFiles();
        var runner = new FakeRunner(
            0,
            """
            {"schemaVersion":1,"databasePresent":true,"windowStartUtcMilliseconds":1000,"windowEndUtcMilliseconds":2000,"totals":{"requestCount":2,"successCount":1,"failureCount":1,"inputTokens":11,"outputTokens":7,"totalTokens":18},"groups":[{"profileId":"profile","providerId":"provider","modelAlias":"public-model","totals":{"requestCount":2,"successCount":1,"failureCount":1,"inputTokens":11,"outputTokens":7,"totalTokens":18}}],"recentErrors":[{"occurredUtcMilliseconds":1500,"profileId":"profile","providerId":"provider","modelAlias":"public-model","errorCode":"429"}]}
            """);
        var reader = CreateReader(runner);

        var result = await reader.ReadAsync(
            DateTimeOffset.FromUnixTimeMilliseconds(1_000),
            DateTimeOffset.FromUnixTimeMilliseconds(2_000));

        Assert.True(result.DatabasePresent);
        Assert.Equal(18, result.Totals.TotalTokens);
        Assert.Equal("public-model", Assert.Single(result.Groups).ModelAlias);
        Assert.Equal("429", Assert.Single(result.RecentErrors).ErrorCode);
        Assert.Equal(1, runner.CallCount);
        Assert.Equal(Path.Combine(root, "state", "usage", "usage.db"), runner.DatabasePath);
    }

    [Fact]
    public async Task Future_schema_is_a_stable_usage_error()
    {
        PrepareFiles();
        var reader = CreateReader(new FakeRunner(
            20,
            "{\"schemaVersion\":1,\"errorCode\":\"aigw_usage_schema_unsupported\"}"));

        var exception = await Assert.ThrowsAsync<UsageException>(() => reader.ReadAsync(
            DateTimeOffset.FromUnixTimeMilliseconds(1_000),
            DateTimeOffset.FromUnixTimeMilliseconds(2_000)));

        Assert.Equal("aigw_usage_schema_unsupported", exception.ErrorCode);
    }

    [Fact]
    public async Task Inconsistent_aggregate_is_rejected()
    {
        PrepareFiles();
        var reader = CreateReader(new FakeRunner(
            0,
            """
            {"schemaVersion":1,"databasePresent":true,"windowStartUtcMilliseconds":1000,"windowEndUtcMilliseconds":2000,"totals":{"requestCount":2,"successCount":2,"failureCount":0,"inputTokens":1,"outputTokens":1,"totalTokens":2},"groups":[],"recentErrors":[]}
            """));

        var exception = await Assert.ThrowsAsync<UsageException>(() => reader.ReadAsync(
            DateTimeOffset.FromUnixTimeMilliseconds(1_000),
            DateTimeOffset.FromUnixTimeMilliseconds(2_000)));

        Assert.Equal("aigw_usage_result_invalid", exception.ErrorCode);
    }

    [Fact]
    public async Task Window_longer_than_366_days_is_rejected_before_path_access()
    {
        var reader = CreateReader(new FakeRunner(0, "unused"));

        var exception = await Assert.ThrowsAsync<UsageException>(() => reader.ReadAsync(
            DateTimeOffset.UnixEpoch,
            DateTimeOffset.UnixEpoch.AddDays(367)));

        Assert.Equal("aigw_usage_window_invalid", exception.ErrorCode);
        Assert.False(Directory.Exists(root));
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private PrivatePythonUsageSummaryReader CreateReader(IUsageQueryProcessRunner runner) => new(
        Path.Combine(root, "app", "runtime", "python", "python.exe"),
        Path.Combine(root, "app", "runtime-tools", "aigw_usage_query.py"),
        Path.Combine(root, "state"),
        runner);

    private void PrepareFiles()
    {
        var python = Path.Combine(root, "app", "runtime", "python", "python.exe");
        var script = Path.Combine(root, "app", "runtime-tools", "aigw_usage_query.py");
        var database = Path.Combine(root, "state", "usage", "usage.db");
        foreach (var path in new[] { python, script, database })
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "fixture");
        }
    }

    private sealed class FakeRunner(int exitCode, string standardOutput) : IUsageQueryProcessRunner
    {
        public int CallCount { get; private set; }
        public string? DatabasePath { get; private set; }

        public Task<UsageQueryProcessResult> RunAsync(
            string pythonPath,
            string scriptPath,
            string databasePath,
            long startMilliseconds,
            long endMilliseconds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CallCount++;
            DatabasePath = databasePath;
            return Task.FromResult(new UsageQueryProcessResult(exitCode, standardOutput));
        }
    }
}

public sealed class PrivatePythonUsageSummaryReaderIntegrationTests
{
    [Fact]
    public async Task Product_reader_uses_private_python_and_reads_the_real_wal_database()
    {
        var python = Environment.GetEnvironmentVariable("AIGW_M5B_PYTHON");
        var script = Environment.GetEnvironmentVariable("AIGW_M5B_QUERY_SCRIPT");
        var testRoot = Environment.GetEnvironmentVariable("AIGW_M5B_TEST_ROOT");
        if (string.IsNullOrWhiteSpace(python) ||
            string.IsNullOrWhiteSpace(script) ||
            string.IsNullOrWhiteSpace(testRoot))
        {
            return;
        }

        var reader = new PrivatePythonUsageSummaryReader(
            python,
            script,
            Path.Combine(testRoot, "state"),
            new UsageQueryProcessRunner(TimeSpan.FromSeconds(5)));

        var result = await reader.ReadAsync(
            DateTimeOffset.FromUnixTimeMilliseconds(2_000),
            DateTimeOffset.FromUnixTimeMilliseconds(4_000));

        Assert.True(result.DatabasePresent);
        Assert.Equal(new UsageTotals(2, 1, 1, 13, 5, 18), result.Totals);
        Assert.Equal("public-model", Assert.Single(result.Groups).ModelAlias);
        Assert.Equal("429", Assert.Single(result.RecentErrors).ErrorCode);
    }

    [Fact]
    public async Task Product_runner_times_out_and_terminates_private_python()
    {
        var python = Environment.GetEnvironmentVariable("AIGW_M5B_PYTHON");
        var script = Environment.GetEnvironmentVariable("AIGW_M5B_SLEEP_SCRIPT");
        var testRoot = Environment.GetEnvironmentVariable("AIGW_M5B_TEST_ROOT");
        if (string.IsNullOrWhiteSpace(python) ||
            string.IsNullOrWhiteSpace(script) ||
            string.IsNullOrWhiteSpace(testRoot))
        {
            return;
        }

        var runner = new UsageQueryProcessRunner(TimeSpan.FromMilliseconds(100));

        var exception = await Assert.ThrowsAsync<UsageException>(() => runner.RunAsync(
            python,
            script,
            Path.Combine(testRoot, "state", "usage", "usage.db"),
            2_000,
            4_000,
            CancellationToken.None));

        Assert.Equal("aigw_usage_query_timeout", exception.ErrorCode);
    }
}
