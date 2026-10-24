using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Usage;

namespace LocalAIGateway.Cli.Tests;

public sealed class M5bUsageCommandTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-CliUsage-{Guid.NewGuid():N}");

    [Fact]
    public async Task Today_uses_local_midnight_and_returns_stable_json()
    {
        var reader = new FakeUsageReader();
        var time = new FixedTimeProvider(
            new DateTimeOffset(2026, 9, 10, 5, 30, 0, TimeSpan.Zero),
            TimeZoneInfo.CreateCustomTimeZone("M5b UTC+8", TimeSpan.FromHours(8), "M5b UTC+8", "M5b UTC+8"));

        var result = await RunAsync(
            CreateServices(reader, time),
            "--json", "usage", "today");

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(string.Empty, result.Error);
        Assert.Equal(
            new DateTimeOffset(2026, 9, 9, 16, 0, 0, TimeSpan.Zero),
            reader.WindowStartUtc);
        Assert.Equal(time.GetUtcNow(), reader.WindowEndUtc);
        using var document = JsonDocument.Parse(result.Output);
        var data = document.RootElement.GetProperty("data");
        Assert.True(data.GetProperty("databasePresent").GetBoolean());
        Assert.Equal(18, data.GetProperty("totals").GetProperty("totalTokens").GetInt64());
        Assert.Equal("public-model", data.GetProperty("groups")[0].GetProperty("modelAlias").GetString());
    }

    [Fact]
    public async Task Usage_error_returns_exit_16_and_stable_code()
    {
        var reader = new FakeUsageReader(new UsageException(
            "aigw_usage_schema_unsupported",
            "future schema"));

        var result = await RunAsync(
            CreateServices(reader, new FixedTimeProvider(
                new DateTimeOffset(2026, 9, 10, 5, 30, 0, TimeSpan.Zero),
                TimeZoneInfo.Utc)),
            "--json", "usage", "today");

        Assert.Equal(16, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        using var document = JsonDocument.Parse(result.Error);
        Assert.Equal(
            "aigw_usage_schema_unsupported",
            document.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private CliServices CreateServices(IUsageSummaryReader reader, TimeProvider timeProvider)
    {
        var configuration = new GatewayConfigurationManager(
            new ConfigurationStore(
                new ConfigurationPaths(Path.Combine(root, "configuration")),
                NoOpConfigurationFileSecurity.Instance),
            new MemoryCredentialStore());
        return new CliServices(
            configuration,
            Usage: new CliUsageServices(reader, timeProvider));
    }

    private static async Task<CliRunResult> RunAsync(CliServices services, params string[] args)
    {
        using var input = new StringReader(string.Empty);
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = await CliApplication.RunAsync(args, input, output, error, services);
        return new CliRunResult(exitCode, output.ToString(), error.ToString());
    }

    private sealed record CliRunResult(int ExitCode, string Output, string Error);

    private sealed class FakeUsageReader(UsageException? error = null) : IUsageSummaryReader
    {
        public DateTimeOffset WindowStartUtc { get; private set; }
        public DateTimeOffset WindowEndUtc { get; private set; }

        public Task<UsageSummary> ReadAsync(
            DateTimeOffset windowStartUtc,
            DateTimeOffset windowEndUtc,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (error is not null)
            {
                throw error;
            }
            WindowStartUtc = windowStartUtc;
            WindowEndUtc = windowEndUtc;
            var totals = new UsageTotals(1, 1, 0, 13, 5, 18);
            return Task.FromResult(new UsageSummary(
                true,
                windowStartUtc.ToUnixTimeMilliseconds(),
                windowEndUtc.ToUnixTimeMilliseconds(),
                totals,
                [new UsageBreakdown("profile", "provider", "public-model", totals)],
                []));
        }
    }

    private sealed class FixedTimeProvider(DateTimeOffset now, TimeZoneInfo zone) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
        public override TimeZoneInfo LocalTimeZone => zone;
    }

    private sealed class MemoryCredentialStore : ICredentialStore
    {
        public ValueTask<string?> GetSecretAsync(
            string target,
            CancellationToken cancellationToken = default) => ValueTask.FromResult<string?>(null);

        public ValueTask SetSecretAsync(
            string target,
            string secret,
            CancellationToken cancellationToken = default) => ValueTask.CompletedTask;

        public ValueTask DeleteSecretAsync(
            string target,
            CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
    }
}
