using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Windows;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayOperationalLogTests : IDisposable
{
    private static readonly DateTimeOffset Now =
        new(2026, 9, 18, 8, 30, 0, TimeSpan.Zero);
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-OperationalLog-{Guid.NewGuid():N}");

    [Fact]
    public void Writes_only_the_fixed_jsonl_schema_and_protects_owned_paths()
    {
        var security = new RecordingFileSecurity();
        var log = CreateLog(security: security);

        log.Write(GatewayOperationalEvent.DaemonStarted, 42);

        var logDirectory = Path.Combine(testRoot, "logs");
        var activeFile = Path.Combine(logDirectory, "gateway.log");
        Assert.Equal([logDirectory], security.Directories);
        Assert.Contains(activeFile, security.Files);
        var line = Assert.Single(File.ReadAllLines(activeFile));
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        Assert.Equal(
            ["timestampUtc", "level", "event", "configurationRevision"],
            root.EnumerateObject().Select(property => property.Name).ToArray());
        Assert.Equal(Now.UtcDateTime, root.GetProperty("timestampUtc").GetDateTime());
        Assert.Equal("information", root.GetProperty("level").GetString());
        Assert.Equal("daemon.started", root.GetProperty("event").GetString());
        Assert.Equal(42, root.GetProperty("configurationRevision").GetInt64());
    }

    [Fact]
    public void Startup_failure_records_only_a_bounded_stable_error_code()
    {
        var log = CreateLog();

        log.Write(
            GatewayOperationalEvent.DaemonStartFailed,
            errorCode: "aigw_runtime_fixture_failed");

        var line = Assert.Single(File.ReadAllLines(Path.Combine(testRoot, "logs", "gateway.log")));
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        Assert.Equal(
            ["timestampUtc", "level", "event", "errorCode"],
            root.EnumerateObject().Select(property => property.Name).ToArray());
        Assert.Equal("daemon.start_failed", root.GetProperty("event").GetString());
        Assert.Equal("aigw_runtime_fixture_failed", root.GetProperty("errorCode").GetString());
    }

    [Fact]
    public void Rotates_before_the_active_file_crosses_its_limit_and_keeps_every_line_valid()
    {
        var log = CreateLog(maximumFileBytes: 512, maximumTotalBytes: 4096);

        for (var index = 0; index < 30; index++)
        {
            log.Write(GatewayOperationalEvent.ConfigurationReloadSucceeded, index);
        }

        var files = Directory.GetFiles(Path.Combine(testRoot, "logs"), "gateway*.log");
        Assert.True(files.Length > 1);
        Assert.All(files, file => Assert.InRange(new FileInfo(file).Length, 1, 512));
        var entries = files
            .SelectMany(File.ReadAllLines)
            .Select(line => JsonDocument.Parse(line))
            .ToArray();
        try
        {
            Assert.Equal(30, entries.Length);
            Assert.All(entries, entry =>
                Assert.Equal(
                    "configuration.reload_succeeded",
                    entry.RootElement.GetProperty("event").GetString()));
        }
        finally
        {
            foreach (var entry in entries)
            {
                entry.Dispose();
            }
        }
    }

    [Fact]
    public void Removes_expired_owned_rotations_and_oldest_files_until_under_the_total_limit()
    {
        var directory = Path.Combine(testRoot, "logs");
        Directory.CreateDirectory(directory);
        var expired = CreateSizedFile(directory, "gateway-20260701T0000000000000Z-0000.log", 300);
        var oldest = CreateSizedFile(directory, "gateway-20260918T0800000000000Z-0000.log", 300);
        var newest = CreateSizedFile(directory, "gateway-20260918T0810000000000Z-0000.log", 300);
        var unrelated = CreateSizedFile(directory, "keep-me.txt", 900);
        var lookalike = CreateSizedFile(directory, "gateway-do-not-delete.log", 900);
        File.SetLastWriteTimeUtc(expired, Now.UtcDateTime - TimeSpan.FromDays(31));
        File.SetLastWriteTimeUtc(oldest, Now.UtcDateTime - TimeSpan.FromMinutes(20));
        File.SetLastWriteTimeUtc(newest, Now.UtcDateTime - TimeSpan.FromMinutes(10));
        File.SetLastWriteTimeUtc(unrelated, Now.UtcDateTime - TimeSpan.FromDays(365));
        File.SetLastWriteTimeUtc(lookalike, Now.UtcDateTime - TimeSpan.FromDays(365));
        var log = CreateLog(maximumFileBytes: 512, maximumTotalBytes: 650);

        log.Write(GatewayOperationalEvent.DaemonStarting);

        Assert.False(File.Exists(expired));
        Assert.False(File.Exists(oldest));
        Assert.True(File.Exists(newest));
        Assert.True(File.Exists(unrelated));
        Assert.True(File.Exists(lookalike));
        var managedBytes = Directory.GetFiles(directory, "gateway*.log")
            .Where(file => !Path.GetFileName(file).Equals(
                "gateway-do-not-delete.log",
                StringComparison.OrdinalIgnoreCase))
            .Sum(file => new FileInfo(file).Length);
        Assert.InRange(managedBytes, 1, 650);
    }

    [Fact]
    public async Task Concurrent_writers_produce_complete_json_lines()
    {
        var log = CreateLog(maximumFileBytes: 4096, maximumTotalBytes: 64 * 1024);

        await Task.WhenAll(Enumerable.Range(0, 100).Select(index => Task.Run(() =>
            log.Write(GatewayOperationalEvent.ConfigurationReloadSucceeded, index))));

        var lines = Directory.GetFiles(Path.Combine(testRoot, "logs"), "gateway*.log")
            .SelectMany(File.ReadAllLines)
            .ToArray();
        Assert.Equal(100, lines.Length);
        Assert.All(lines, line =>
        {
            using var document = JsonDocument.Parse(line);
            Assert.Equal(
                "configuration.reload_succeeded",
                document.RootElement.GetProperty("event").GetString());
        });
    }

    [Fact]
    public void Filesystem_or_acl_failures_are_fail_open()
    {
        var log = CreateLog(security: new ThrowingFileSecurity());

        var failure = Record.Exception(() => log.Write(GatewayOperationalEvent.DaemonStarting));

        Assert.Null(failure);
    }

    [Fact]
    public void Windows_security_restricts_the_real_log_directory_and_file_to_the_current_user()
    {
        Assert.True(OperatingSystem.IsWindows());
        var log = CreateLog(security: new WindowsConfigurationFileSecurity());

        log.Write(GatewayOperationalEvent.DaemonStarting);

        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        var currentSid = identity.User ?? throw new InvalidOperationException("Current SID unavailable.");
        var directorySecurity = FileSystemAclExtensions.GetAccessControl(
            new DirectoryInfo(Path.Combine(testRoot, "logs")));
        var fileSecurity = FileSystemAclExtensions.GetAccessControl(
            new FileInfo(Path.Combine(testRoot, "logs", "gateway.log")));
        AssertCurrentUserFullControl(directorySecurity, currentSid);
        AssertCurrentUserFullControl(fileSecurity, currentSid);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private BoundedJsonFileOperationalLog CreateLog(
        long maximumFileBytes = GatewayOperationalLogOptions.DefaultMaximumFileBytes,
        long maximumTotalBytes = GatewayOperationalLogOptions.DefaultMaximumTotalBytes,
        IConfigurationFileSecurity? security = null) => new(
        new GatewayOperationalLogOptions
        {
            DirectoryPath = Path.Combine(testRoot, "logs"),
            MaximumFileBytes = maximumFileBytes,
            MaximumTotalBytes = maximumTotalBytes,
        },
        security ?? NoOpConfigurationFileSecurity.Instance,
        new FixedTimeProvider(Now));

    private static string CreateSizedFile(string directory, string name, int length)
    {
        var path = Path.Combine(directory, name);
        File.WriteAllBytes(path, Enumerable.Repeat((byte)'x', length).ToArray());
        return path;
    }

    private static void AssertCurrentUserFullControl(
        FileSystemSecurity security,
        SecurityIdentifier currentSid)
    {
        Assert.True(security.AreAccessRulesProtected);
        var rules = security.GetAccessRules(
            includeExplicit: true,
            includeInherited: false,
            typeof(SecurityIdentifier));
        var matchingRules = rules
            .Cast<FileSystemAccessRule>()
            .Where(rule => currentSid.Equals(rule.IdentityReference) &&
                rule.AccessControlType == AccessControlType.Allow)
            .ToArray();
        Assert.Single(matchingRules);
        Assert.Equal(FileSystemRights.FullControl, matchingRules[0].FileSystemRights);
    }

    private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    private sealed class RecordingFileSecurity : IConfigurationFileSecurity
    {
        public List<string> Directories { get; } = [];
        public List<string> Files { get; } = [];

        public void ProtectDirectory(string path) => Directories.Add(path);
        public void ProtectFile(string path) => Files.Add(path);
    }

    private sealed class ThrowingFileSecurity : IConfigurationFileSecurity
    {
        public void ProtectDirectory(string path) => throw new UnauthorizedAccessException("fixture");
        public void ProtectFile(string path) => throw new UnauthorizedAccessException("fixture");
    }
}
