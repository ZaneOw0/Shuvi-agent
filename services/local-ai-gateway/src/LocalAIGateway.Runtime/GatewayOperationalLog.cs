using System.Buffers;
using System.Globalization;
using System.Security;
using System.Text.Json;
using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Runtime;

internal enum GatewayOperationalEvent
{
    DaemonStarting,
    DaemonStarted,
    DaemonStartFailed,
    DaemonStopping,
    DaemonStopped,
    DaemonStopFailed,
    ConfigurationReloadSucceeded,
    ConfigurationReloadFailed,
}

internal interface IGatewayOperationalLog
{
    void Write(
        GatewayOperationalEvent eventType,
        long? configurationRevision = null,
        string? errorCode = null);
}

internal sealed class NullGatewayOperationalLog : IGatewayOperationalLog
{
    public static NullGatewayOperationalLog Instance { get; } = new();

    private NullGatewayOperationalLog()
    {
    }

    public void Write(
        GatewayOperationalEvent eventType,
        long? configurationRevision = null,
        string? errorCode = null)
    {
    }
}

internal sealed record GatewayOperationalLogOptions
{
    public const long DefaultMaximumFileBytes = 10 * 1024 * 1024;
    public const long DefaultMaximumTotalBytes = 100 * 1024 * 1024;
    public static readonly TimeSpan DefaultRetention = TimeSpan.FromDays(30);

    public required string DirectoryPath { get; init; }

    public long MaximumFileBytes { get; init; } = DefaultMaximumFileBytes;

    public long MaximumTotalBytes { get; init; } = DefaultMaximumTotalBytes;

    public TimeSpan Retention { get; init; } = DefaultRetention;
}

internal sealed class BoundedJsonFileOperationalLog : IGatewayOperationalLog
{
    private const int MinimumMaximumFileBytes = 256;
    private const string ActiveFileName = "gateway.log";
    private readonly object gate = new();
    private readonly string directoryPath;
    private readonly string activeFilePath;
    private readonly long maximumFileBytes;
    private readonly long maximumTotalBytes;
    private readonly TimeSpan retention;
    private readonly IConfigurationFileSecurity fileSecurity;
    private readonly TimeProvider timeProvider;
    private bool initialized;

    public BoundedJsonFileOperationalLog(
        GatewayOperationalLogOptions options,
        IConfigurationFileSecurity fileSecurity,
        TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(fileSecurity);
        if (string.IsNullOrWhiteSpace(options.DirectoryPath) ||
            !Path.IsPathFullyQualified(options.DirectoryPath))
        {
            throw new ArgumentException(
                "The operational log directory must be an absolute path.",
                nameof(options));
        }

        directoryPath = Path.GetFullPath(options.DirectoryPath)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var volumeRoot = Path.GetPathRoot(directoryPath)?.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        if (directoryPath.Length == 0 ||
            string.Equals(directoryPath, volumeRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                "The operational log directory cannot be a volume root.",
                nameof(options));
        }

        if (options.MaximumFileBytes < MinimumMaximumFileBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                $"The maximum log file size must be at least {MinimumMaximumFileBytes} bytes.");
        }

        if (options.MaximumTotalBytes < options.MaximumFileBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The maximum total log size cannot be smaller than one log file.");
        }

        if (options.Retention <= TimeSpan.Zero || options.Retention > TimeSpan.FromDays(3650))
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The operational log retention must be positive and no greater than ten years.");
        }

        activeFilePath = Path.Combine(directoryPath, ActiveFileName);
        maximumFileBytes = options.MaximumFileBytes;
        maximumTotalBytes = options.MaximumTotalBytes;
        retention = options.Retention;
        this.fileSecurity = fileSecurity;
        this.timeProvider = timeProvider ?? TimeProvider.System;
    }

    public void Write(
        GatewayOperationalEvent eventType,
        long? configurationRevision = null,
        string? errorCode = null)
    {
        if (!Enum.IsDefined(eventType))
        {
            throw new ArgumentOutOfRangeException(nameof(eventType));
        }

        if (configurationRevision < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(configurationRevision));
        }
        if (errorCode is not null &&
            (errorCode.Length is 0 or > 128 || errorCode.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '_' or '-'))))
        {
            throw new ArgumentException("The operational error code is invalid.", nameof(errorCode));
        }

        try
        {
            lock (gate)
            {
                var now = timeProvider.GetUtcNow();
                EnsureInitialized();
                CleanupExpired(now);
                EnforceTotalLimit();

                var entry = SerializeEntry(now, eventType, configurationRevision, errorCode);
                RotateIfRequired(entry.Length, now);
                Append(entry);
                EnforceTotalLimit();
            }
        }
        catch (Exception exception) when (!IsFatal(exception))
        {
            // Operational logging is deliberately fail-open. The fixed event schema carries no secrets,
            // and a filesystem or ACL failure must not interrupt the gateway data path.
        }
    }

    private void EnsureInitialized()
    {
        if (initialized)
        {
            EnsureExistingPathHasNoReparsePoint(directoryPath);
            return;
        }

        EnsureExistingPathHasNoReparsePoint(directoryPath);
        Directory.CreateDirectory(directoryPath);
        EnsureNotReparsePoint(directoryPath, isDirectory: true);
        fileSecurity.ProtectDirectory(directoryPath);
        foreach (var file in EnumerateManagedFiles(includeActive: true))
        {
            if (!IsReparsePoint(file))
            {
                fileSecurity.ProtectFile(file.FullName);
            }
        }

        initialized = true;
    }

    private void RotateIfRequired(int entryLength, DateTimeOffset now)
    {
        if (!File.Exists(activeFilePath))
        {
            return;
        }

        EnsureNotReparsePoint(activeFilePath, isDirectory: false);
        var activeLength = new FileInfo(activeFilePath).Length;
        if (activeLength == 0 || activeLength <= maximumFileBytes - entryLength)
        {
            return;
        }

        for (var index = 0; index < 10_000; index++)
        {
            var rotatedName = $"gateway-{now.UtcDateTime:yyyyMMddTHHmmssfffffffZ}-{index:D4}.log";
            var rotatedPath = Path.Combine(directoryPath, rotatedName);
            if (File.Exists(rotatedPath) || Directory.Exists(rotatedPath))
            {
                continue;
            }

            File.Move(activeFilePath, rotatedPath);
            fileSecurity.ProtectFile(rotatedPath);
            return;
        }

        throw new IOException("No collision-free operational log rotation name was available.");
    }

    private void Append(ReadOnlySpan<byte> entry)
    {
        if (File.Exists(activeFilePath))
        {
            EnsureNotReparsePoint(activeFilePath, isDirectory: false);
        }
        else
        {
            using (new FileStream(
                activeFilePath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.Read,
                bufferSize: 1,
                options: FileOptions.WriteThrough))
            {
            }
        }

        fileSecurity.ProtectFile(activeFilePath);
        using var stream = new FileStream(
            activeFilePath,
            FileMode.Append,
            FileAccess.Write,
            FileShare.Read,
            bufferSize: 4096,
            options: FileOptions.WriteThrough);
        stream.Write(entry);
        stream.Flush(flushToDisk: true);
    }

    private void CleanupExpired(DateTimeOffset now)
    {
        var cutoff = now.UtcDateTime - retention;
        foreach (var file in EnumerateManagedFiles(includeActive: false))
        {
            if (!IsReparsePoint(file) && file.LastWriteTimeUtc < cutoff)
            {
                file.Delete();
            }
        }
    }

    private void EnforceTotalLimit()
    {
        var files = EnumerateManagedFiles(includeActive: true)
            .Where(file => !IsReparsePoint(file))
            .ToArray();
        var totalBytes = files.Aggregate(0L, (total, file) =>
            total > long.MaxValue - file.Length ? long.MaxValue : total + file.Length);
        if (totalBytes <= maximumTotalBytes)
        {
            return;
        }

        foreach (var file in files
                     .Where(file => !file.Name.Equals(ActiveFileName, StringComparison.OrdinalIgnoreCase))
                     .OrderBy(file => file.LastWriteTimeUtc)
                     .ThenBy(file => file.Name, StringComparer.OrdinalIgnoreCase))
        {
            var length = file.Length;
            file.Delete();
            totalBytes = Math.Max(0, totalBytes - length);
            if (totalBytes <= maximumTotalBytes)
            {
                return;
            }
        }
    }

    private FileInfo[] EnumerateManagedFiles(bool includeActive)
    {
        if (!Directory.Exists(directoryPath))
        {
            return [];
        }

        var files = new DirectoryInfo(directoryPath)
            .EnumerateFiles("gateway-*.log", SearchOption.TopDirectoryOnly)
            .Where(file => IsOwnedRotationName(file.Name))
            .ToList();
        if (includeActive && File.Exists(activeFilePath))
        {
            files.Add(new FileInfo(activeFilePath));
        }

        return files.ToArray();
    }

    private static bool IsOwnedRotationName(string name)
    {
        const string prefix = "gateway-";
        const string suffix = ".log";
        if (!name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ||
            !name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var body = name[prefix.Length..^suffix.Length];
        var separator = body.LastIndexOf('-');
        if (separator <= 0 ||
            body.Length - separator - 1 != 4 ||
            !body[(separator + 1)..].All(char.IsAsciiDigit))
        {
            return false;
        }

        return DateTime.TryParseExact(
            body[..separator],
            "yyyyMMdd'T'HHmmssfffffff'Z'",
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out _);
    }

    private static byte[] SerializeEntry(
        DateTimeOffset now,
        GatewayOperationalEvent eventType,
        long? configurationRevision,
        string? errorCode)
    {
        var buffer = new ArrayBufferWriter<byte>(192);
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("timestampUtc", now.UtcDateTime);
            writer.WriteString("level", Level(eventType));
            writer.WriteString("event", EventName(eventType));
            if (configurationRevision is long revision)
            {
                writer.WriteNumber("configurationRevision", revision);
            }
            if (errorCode is not null)
            {
                writer.WriteString("errorCode", errorCode);
            }

            writer.WriteEndObject();
        }

        var result = new byte[buffer.WrittenCount + 1];
        buffer.WrittenSpan.CopyTo(result);
        result[^1] = (byte)'\n';
        return result;
    }

    private static string Level(GatewayOperationalEvent eventType) => eventType switch
    {
        GatewayOperationalEvent.DaemonStartFailed or
        GatewayOperationalEvent.DaemonStopFailed or
        GatewayOperationalEvent.ConfigurationReloadFailed => "error",
        _ => "information",
    };

    private static string EventName(GatewayOperationalEvent eventType) => eventType switch
    {
        GatewayOperationalEvent.DaemonStarting => "daemon.starting",
        GatewayOperationalEvent.DaemonStarted => "daemon.started",
        GatewayOperationalEvent.DaemonStartFailed => "daemon.start_failed",
        GatewayOperationalEvent.DaemonStopping => "daemon.stopping",
        GatewayOperationalEvent.DaemonStopped => "daemon.stopped",
        GatewayOperationalEvent.DaemonStopFailed => "daemon.stop_failed",
        GatewayOperationalEvent.ConfigurationReloadSucceeded => "configuration.reload_succeeded",
        GatewayOperationalEvent.ConfigurationReloadFailed => "configuration.reload_failed",
        _ => throw new ArgumentOutOfRangeException(nameof(eventType)),
    };

    private static void EnsureExistingPathHasNoReparsePoint(string path)
    {
        for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
        {
            if (Directory.Exists(current))
            {
                EnsureNotReparsePoint(current, isDirectory: true);
            }

            var parent = Path.GetDirectoryName(current);
            if (string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
        }
    }

    private static void EnsureNotReparsePoint(string path, bool isDirectory)
    {
        var exists = isDirectory ? Directory.Exists(path) : File.Exists(path);
        if (exists && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException("Operational logging refuses to follow a reparse point.");
        }
    }

    private static bool IsReparsePoint(FileInfo file) =>
        (file.Attributes & FileAttributes.ReparsePoint) != 0;

    private static bool IsFatal(Exception exception) => exception is
        OutOfMemoryException or
        StackOverflowException or
        AccessViolationException or
        AppDomainUnloadedException or
        BadImageFormatException or
        CannotUnloadAppDomainException or
        InvalidProgramException or
        ThreadAbortException;
}
