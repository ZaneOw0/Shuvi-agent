using System.Text.Json;

namespace LocalAIGateway.Core.Configuration;

public sealed class ConfigurationStore
{
    private readonly IConfigurationFileSecurity fileSecurity;
    private readonly Action<string, string, string> replaceFile;
    private readonly TimeSpan lockTimeout;

    public ConfigurationStore(
        ConfigurationPaths paths,
        IConfigurationFileSecurity fileSecurity,
        TimeSpan? lockTimeout = null)
        : this(
            paths,
            fileSecurity,
            static (source, destination, backup) =>
                File.Replace(source, destination, backup, ignoreMetadataErrors: false),
            lockTimeout)
    {
    }

    internal ConfigurationStore(
        ConfigurationPaths paths,
        IConfigurationFileSecurity fileSecurity,
        Action<string, string, string> replaceFile,
        TimeSpan? lockTimeout = null)
    {
        Paths = paths ?? throw new ArgumentNullException(nameof(paths));
        this.fileSecurity = fileSecurity ?? throw new ArgumentNullException(nameof(fileSecurity));
        this.replaceFile = replaceFile ?? throw new ArgumentNullException(nameof(replaceFile));
        this.lockTimeout = lockTimeout ?? TimeSpan.FromSeconds(5);
    }

    public ConfigurationPaths Paths { get; }

    public async Task<GatewayConfiguration> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var bytes = await File.ReadAllBytesAsync(Paths.ConfigurationFile, cancellationToken);
            var configuration = ConfigurationJson.Deserialize(bytes);
            ThrowIfInvalid(configuration);
            return configuration;
        }
        catch (FileNotFoundException)
        {
            return GatewayConfiguration.Empty;
        }
        catch (DirectoryNotFoundException)
        {
            return GatewayConfiguration.Empty;
        }
        catch (ConfigurationException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new ConfigurationException(
                "aigw_config_corrupt",
                "Configuration JSON is malformed or violates the schema.",
                exception);
        }
        catch (IOException exception)
        {
            throw new ConfigurationException(
                "aigw_config_io",
                "Configuration could not be read.",
                exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new ConfigurationException(
                "aigw_config_access_denied",
                "Configuration access was denied.",
                exception);
        }
    }

    public async Task<GatewayConfiguration> SaveAsync(
        GatewayConfiguration candidate,
        long expectedRevision,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        Directory.CreateDirectory(Paths.RootDirectory);
        fileSecurity.ProtectDirectory(Paths.RootDirectory);

        await using var lockStream = await AcquireLockAsync(cancellationToken);
        fileSecurity.ProtectFile(Paths.LockFile);

        var current = await LoadAsync(cancellationToken);
        if (current.Revision != expectedRevision)
        {
            throw new ConfigurationConcurrencyException(expectedRevision, current.Revision);
        }

        var next = candidate with
        {
            SchemaVersion = GatewayConfiguration.CurrentSchemaVersion,
            Revision = checked(expectedRevision + 1),
        };
        ThrowIfInvalid(next);

        var temporaryFile = Path.Combine(
            Paths.RootDirectory,
            $"config.{Guid.NewGuid():N}.tmp");
        try
        {
            var bytes = ConfigurationJson.Serialize(next);
            await using (var output = new FileStream(
                temporaryFile,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await output.WriteAsync(bytes, cancellationToken);
                await output.FlushAsync(cancellationToken);
                output.Flush(flushToDisk: true);
            }
            fileSecurity.ProtectFile(temporaryFile);

            if (File.Exists(Paths.ConfigurationFile))
            {
                try
                {
                    replaceFile(temporaryFile, Paths.ConfigurationFile, Paths.BackupFile);
                }
                catch (UnauthorizedAccessException) when (
                    File.Exists(temporaryFile) &&
                    File.Exists(Paths.ConfigurationFile))
                {
                    await ReplaceWithAtomicMovesAsync(
                        temporaryFile,
                        Paths.ConfigurationFile,
                        Paths.BackupFile,
                        cancellationToken);
                }
                fileSecurity.ProtectFile(Paths.BackupFile);
            }
            else
            {
                File.Move(temporaryFile, Paths.ConfigurationFile);
            }

            fileSecurity.ProtectFile(Paths.ConfigurationFile);
            return next;
        }
        catch (ConfigurationException)
        {
            throw;
        }
        catch (IOException exception)
        {
            throw new ConfigurationException(
                "aigw_config_io",
                "Configuration could not be written atomically.",
                exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new ConfigurationException(
                "aigw_config_access_denied",
                "Configuration access was denied.",
                exception);
        }
        finally
        {
            if (File.Exists(temporaryFile))
            {
                File.Delete(temporaryFile);
            }
        }
    }

    private async Task ReplaceWithAtomicMovesAsync(
        string source,
        string destination,
        string backup,
        CancellationToken cancellationToken)
    {
        var backupTemporaryFile = Path.Combine(
            Paths.RootDirectory,
            $"config.{Guid.NewGuid():N}.bak.tmp");
        try
        {
            await using (var input = new FileStream(
                destination,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            await using (var output = new FileStream(
                backupTemporaryFile,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await input.CopyToAsync(output, cancellationToken);
                await output.FlushAsync(cancellationToken);
                output.Flush(flushToDisk: true);
            }

            fileSecurity.ProtectFile(backupTemporaryFile);
            File.Move(backupTemporaryFile, backup, overwrite: true);
            File.Move(source, destination, overwrite: true);
        }
        finally
        {
            if (File.Exists(backupTemporaryFile))
            {
                File.Delete(backupTemporaryFile);
            }
        }
    }

    private static void ThrowIfInvalid(GatewayConfiguration configuration)
    {
        var result = ConfigurationValidator.Validate(configuration);
        if (!result.IsValid)
        {
            throw new ConfigurationValidationException(result.Errors);
        }
    }

    private async Task<FileStream> AcquireLockAsync(CancellationToken cancellationToken)
    {
        var started = DateTime.UtcNow;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                return new FileStream(
                    Paths.LockFile,
                    FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,
                    FileShare.None,
                    1,
                    FileOptions.Asynchronous | FileOptions.WriteThrough);
            }
            catch (IOException) when (DateTime.UtcNow - started < lockTimeout)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
            }
            catch (IOException exception)
            {
                throw new ConfigurationException(
                    "aigw_config_lock_timeout",
                    "Timed out waiting for the configuration lock.",
                    exception);
            }
        }
    }
}
