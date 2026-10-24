using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Installation;
using Microsoft.Win32;

namespace LocalAIGateway.Windows.Installation;

public sealed record CurrentUserShellIntegrationComponentStatus(
    string Target,
    bool Present,
    bool Owned,
    bool Conflict);

public sealed record CurrentUserShellIntegrationStatus(
    CurrentUserShellIntegrationComponentStatus UserPath,
    CurrentUserShellIntegrationComponentStatus StartMenu)
{
    public bool Owned => UserPath.Owned && StartMenu.Owned;

    public bool Conflict => UserPath.Conflict || StartMenu.Conflict;

    public bool Incomplete => !Conflict && !Owned;
}

public sealed record CurrentUserShellIntegrationOperationResult(
    bool Changed,
    CurrentUserShellIntegrationStatus Status);

internal enum CurrentUserShellIntegrationComponentState
{
    Absent,
    Owned,
    Conflict,
}

internal sealed record CurrentUserShellIntegrationSpec(
    string PathEntry,
    string ShortcutDirectory,
    string ShortcutPath,
    string ShortcutTarget,
    string ShortcutWorkingDirectory,
    string ShortcutArguments,
    string ReceiptDirectory,
    string ReceiptPath)
{
    public const string RegistryTarget = @"HKEY_CURRENT_USER\Environment\Path";

    public static CurrentUserShellIntegrationSpec ForCurrentUser(CurrentUserInstallationTarget target)
    {
        var appData = Environment.GetEnvironmentVariable("APPDATA");
        if (string.IsNullOrWhiteSpace(appData))
        {
            appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        }
        return Create(target, appData);
    }

    internal static CurrentUserShellIntegrationSpec Create(
        CurrentUserInstallationTarget target,
        string appDataRoot)
    {
        ArgumentNullException.ThrowIfNull(target);
        var appData = NormalizeRoot(appDataRoot, "roaming application data");
        var shortcutDirectory = Path.Combine(
            appData,
            "Microsoft",
            "Windows",
            "Start Menu",
            "Programs",
            "Local AI Gateway");
        var receiptDirectory = Path.Combine(target.StateRoot, "installation");
        return new CurrentUserShellIntegrationSpec(
            target.InstallRoot,
            shortcutDirectory,
            Path.Combine(shortcutDirectory, "Local AI Gateway.lnk"),
            target.TrayExecutablePath,
            target.TrayDirectory,
            string.Empty,
            receiptDirectory,
            Path.Combine(receiptDirectory, "shell-integration.json"));
    }

    private static string NormalizeRoot(string path, string label)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw new InstallationException(
                "aigw_shell_integration_path_invalid",
                $"The {label} root must be a fully qualified path.");
        }
        var normalized = Path.GetFullPath(path).TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        var volumeRoot = Path.GetPathRoot(normalized)?.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        if (normalized.Length == 0 || normalized.Equals(volumeRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new InstallationException(
                "aigw_shell_integration_path_invalid",
                $"The {label} root must not be a volume root.");
        }
        return normalized;
    }
}

internal sealed record CurrentUserShellIntegrationSnapshot(
    CurrentUserShellIntegrationSpec Spec,
    bool ReceiptPresent,
    CurrentUserShellIntegrationComponentState UserPath,
    CurrentUserShellIntegrationComponentState StartMenu)
{
    public bool IsAbsent =>
        !ReceiptPresent &&
        UserPath == CurrentUserShellIntegrationComponentState.Absent &&
        StartMenu == CurrentUserShellIntegrationComponentState.Absent;

    public bool IsOwned =>
        ReceiptPresent &&
        UserPath == CurrentUserShellIntegrationComponentState.Owned &&
        StartMenu == CurrentUserShellIntegrationComponentState.Owned;

    public bool HasConflict =>
        UserPath == CurrentUserShellIntegrationComponentState.Conflict ||
        StartMenu == CurrentUserShellIntegrationComponentState.Conflict;
}

internal interface ICurrentUserShellIntegrationStore
{
    ValueTask<CurrentUserShellIntegrationSnapshot> InspectAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    ValueTask CreateAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    ValueTask DeleteAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);
}

internal sealed record UserPathValue(bool Exists, string Value, RegistryValueKind Kind);

internal interface IUserPathStore
{
    UserPathValue Read();

    void Write(string value, RegistryValueKind kind);

    void Delete();

    void NotifyChanged();
}

internal interface IWindowsShortcutStore
{
    bool Exists(string path);

    bool Matches(string path, CurrentUserShellIntegrationSpec spec);

    void Create(CurrentUserShellIntegrationSpec spec);

    void Delete(string path, bool deleteEmptyDirectory);
}

internal sealed class WindowsCurrentUserShellIntegrationStore : ICurrentUserShellIntegrationStore
{
    private const int ReceiptSchemaVersion = 1;
    private readonly IUserPathStore userPath;
    private readonly IWindowsShortcutStore shortcuts;
    private readonly IConfigurationFileSecurity fileSecurity;
    private readonly Func<CurrentUserInstallationTarget, CurrentUserShellIntegrationSpec> specFactory;

    public WindowsCurrentUserShellIntegrationStore()
        : this(
            new WindowsUserPathStore(),
            new WindowsScriptShortcutStore(),
            new WindowsConfigurationFileSecurity(),
            CurrentUserShellIntegrationSpec.ForCurrentUser)
    {
    }

    internal WindowsCurrentUserShellIntegrationStore(
        IUserPathStore userPath,
        IWindowsShortcutStore shortcuts,
        IConfigurationFileSecurity fileSecurity,
        Func<CurrentUserInstallationTarget, CurrentUserShellIntegrationSpec> specFactory)
    {
        this.userPath = userPath ?? throw new ArgumentNullException(nameof(userPath));
        this.shortcuts = shortcuts ?? throw new ArgumentNullException(nameof(shortcuts));
        this.fileSecurity = fileSecurity ?? throw new ArgumentNullException(nameof(fileSecurity));
        this.specFactory = specFactory ?? throw new ArgumentNullException(nameof(specFactory));
    }

    public ValueTask<CurrentUserShellIntegrationSnapshot> InspectAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            var spec = specFactory(target);
            var receipt = ReadReceipt(spec);
            var invalidReceipt = File.Exists(spec.ReceiptPath) && receipt is null;
            var pathState = InspectPath(spec, receipt, invalidReceipt);
            var shortcutState = InspectShortcut(spec, receipt, invalidReceipt);
            return ValueTask.FromResult(new CurrentUserShellIntegrationSnapshot(
                spec,
                receipt is not null,
                pathState,
                shortcutState));
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (InstallationException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new InstallationException(
                "aigw_shell_integration_inspection_failed",
                "The current-user PATH or Start Menu integration could not be inspected.",
                exception);
        }
    }

    public async ValueTask CreateAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        var initial = await InspectAsync(target, cancellationToken);
        if (initial.HasConflict)
        {
            throw Conflict();
        }
        if (initial.IsOwned)
        {
            return;
        }

        var receiptCreated = false;
        var pathCreated = false;
        var shortcutCreated = false;
        var failures = new List<Exception>();
        try
        {
            var pathBefore = userPath.Read();
            if (!initial.ReceiptPresent)
            {
                await WriteReceiptAsync(initial.Spec, pathBefore, cancellationToken);
                receiptCreated = true;
            }

            if (initial.UserPath == CurrentUserShellIntegrationComponentState.Absent)
            {
                AddPathEntry(initial.Spec.PathEntry, pathBefore);
                pathCreated = true;
            }

            cancellationToken.ThrowIfCancellationRequested();
            if (initial.StartMenu == CurrentUserShellIntegrationComponentState.Absent)
            {
                shortcuts.Create(initial.Spec);
                shortcutCreated = true;
            }

            var completed = await InspectAsync(target, cancellationToken);
            if (!completed.IsOwned)
            {
                throw completed.HasConflict
                    ? Conflict()
                    : new InstallationException(
                        "aigw_shell_integration_registration_failed",
                        "The current-user PATH and Start Menu integration was not complete after registration.");
            }
            return;
        }
        catch (Exception exception)
        {
            failures.Add(exception);
        }

        if (shortcutCreated)
        {
            var receipt = ReadReceipt(initial.Spec);
            TryRollback(
                () => shortcuts.Delete(
                    initial.Spec.ShortcutPath,
                    receipt?.ShortcutDirectoryWasAbsent == true),
                failures);
        }
        if (pathCreated)
        {
            TryRollback(() => RemovePathEntry(initial.Spec, ReadReceipt(initial.Spec)), failures);
        }
        if (receiptCreated)
        {
            TryRollback(() => DeleteReceipt(initial.Spec), failures);
        }

        var original = failures[0];
        if (failures.Count == 1)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(original).Throw();
        }
        throw new InstallationException(
            "aigw_shell_integration_rollback_failed",
            "Current-user shell integration failed and rollback was incomplete.",
            new AggregateException(failures));
    }

    public async ValueTask DeleteAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        var initial = await InspectAsync(target, cancellationToken);
        if (initial.HasConflict)
        {
            throw Conflict();
        }
        if (initial.IsAbsent)
        {
            return;
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (initial.StartMenu == CurrentUserShellIntegrationComponentState.Owned)
        {
            var receipt = ReadReceipt(initial.Spec) ?? throw Conflict();
            shortcuts.Delete(initial.Spec.ShortcutPath, receipt.ShortcutDirectoryWasAbsent);
        }
        cancellationToken.ThrowIfCancellationRequested();
        if (initial.UserPath == CurrentUserShellIntegrationComponentState.Owned)
        {
            RemovePathEntry(initial.Spec, ReadReceipt(initial.Spec));
        }
        DeleteReceipt(initial.Spec);

        var completed = await InspectAsync(target, cancellationToken);
        if (!completed.IsAbsent)
        {
            throw completed.HasConflict
                ? Conflict()
                : new InstallationException(
                    "aigw_shell_integration_removal_failed",
                    "Owned current-user PATH or Start Menu integration remains after removal.");
        }
    }

    private CurrentUserShellIntegrationComponentState InspectPath(
        CurrentUserShellIntegrationSpec spec,
        ShellIntegrationReceipt? receipt,
        bool invalidReceipt)
    {
        if (invalidReceipt)
        {
            return CurrentUserShellIntegrationComponentState.Conflict;
        }
        var path = userPath.Read();
        var segments = SplitPath(path.Value);
        var exact = segments.Count(segment => segment.Equals(spec.PathEntry, StringComparison.OrdinalIgnoreCase));
        var equivalent = segments.Count(segment => PathsEquivalent(segment, spec.PathEntry));
        if (receipt is null)
        {
            return equivalent == 0
                ? CurrentUserShellIntegrationComponentState.Absent
                : CurrentUserShellIntegrationComponentState.Conflict;
        }
        if (exact == 1 && equivalent == 1)
        {
            return CurrentUserShellIntegrationComponentState.Owned;
        }
        return equivalent == 0
            ? CurrentUserShellIntegrationComponentState.Absent
            : CurrentUserShellIntegrationComponentState.Conflict;
    }

    private CurrentUserShellIntegrationComponentState InspectShortcut(
        CurrentUserShellIntegrationSpec spec,
        ShellIntegrationReceipt? receipt,
        bool invalidReceipt)
    {
        if (invalidReceipt || HasExistingReparsePoint(spec.ShortcutPath))
        {
            return CurrentUserShellIntegrationComponentState.Conflict;
        }
        if (!shortcuts.Exists(spec.ShortcutPath))
        {
            return CurrentUserShellIntegrationComponentState.Absent;
        }
        if (receipt is null)
        {
            return CurrentUserShellIntegrationComponentState.Conflict;
        }
        return shortcuts.Matches(spec.ShortcutPath, spec)
            ? CurrentUserShellIntegrationComponentState.Owned
            : CurrentUserShellIntegrationComponentState.Conflict;
    }

    private void AddPathEntry(string entry, UserPathValue before)
    {
        var value = string.IsNullOrEmpty(before.Value)
            ? entry
            : before.Value.EndsWith(';') ? before.Value + entry : before.Value + ";" + entry;
        userPath.Write(value, before.Exists ? before.Kind : RegistryValueKind.ExpandString);
        userPath.NotifyChanged();
    }

    private void RemovePathEntry(
        CurrentUserShellIntegrationSpec spec,
        ShellIntegrationReceipt? receipt)
    {
        if (receipt is null)
        {
            throw Conflict();
        }
        var current = userPath.Read();
        var matches = FindExactPathEntryBounds(current.Value, spec.PathEntry);
        if (matches.Length != 1)
        {
            throw Conflict();
        }
        var match = matches[0];
        var removalStart = match.Start;
        var removalLength = match.Length;
        if (receipt.PathSeparatorAdded)
        {
            if (removalStart == 0 || current.Value[removalStart - 1] != ';')
            {
                throw Conflict();
            }
            removalStart--;
            removalLength++;
        }
        else if (removalStart + removalLength < current.Value.Length &&
                 current.Value[removalStart + removalLength] == ';')
        {
            removalLength++;
        }
        var updated = current.Value.Remove(removalStart, removalLength);
        if (updated.Length == 0 && receipt.PathValueWasAbsent)
        {
            userPath.Delete();
        }
        else
        {
            userPath.Write(updated, current.Exists ? current.Kind : receipt.PathValueKind);
        }
        userPath.NotifyChanged();
    }

    private async Task WriteReceiptAsync(
        CurrentUserShellIntegrationSpec spec,
        UserPathValue pathBefore,
        CancellationToken cancellationToken)
    {
        if (HasExistingReparsePoint(spec.ReceiptPath))
        {
            throw Conflict();
        }
        var shortcutDirectoryWasAbsent = !Directory.Exists(spec.ShortcutDirectory);
        var receiptDirectoryWasAbsent = !Directory.Exists(spec.ReceiptDirectory);
        var stateRoot = Path.GetDirectoryName(spec.ReceiptDirectory)!;
        var stateRootWasAbsent = !Directory.Exists(stateRoot);
        Directory.CreateDirectory(spec.ReceiptDirectory);
        fileSecurity.ProtectDirectory(spec.ReceiptDirectory);
        var receipt = new ShellIntegrationReceipt(
            ReceiptSchemaVersion,
            spec.PathEntry,
            spec.ShortcutPath,
            spec.ShortcutTarget,
            spec.ShortcutWorkingDirectory,
            spec.ShortcutArguments,
            !pathBefore.Exists,
            pathBefore.Exists ? pathBefore.Kind : RegistryValueKind.ExpandString,
            pathBefore.Value.Length > 0 && !pathBefore.Value.EndsWith(';'),
            shortcutDirectoryWasAbsent,
            receiptDirectoryWasAbsent,
            stateRootWasAbsent);
        var bytes = SerializeReceipt(receipt);
        var temporary = Path.Combine(spec.ReceiptDirectory, $".shell-integration-{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }
            fileSecurity.ProtectFile(temporary);
            File.Move(temporary, spec.ReceiptPath);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    private static byte[] SerializeReceipt(ShellIntegrationReceipt receipt)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", receipt.SchemaVersion);
            writer.WriteString("pathEntry", receipt.PathEntry);
            writer.WriteString("shortcutPath", receipt.ShortcutPath);
            writer.WriteString("shortcutTarget", receipt.ShortcutTarget);
            writer.WriteString("shortcutWorkingDirectory", receipt.ShortcutWorkingDirectory);
            writer.WriteString("shortcutArguments", receipt.ShortcutArguments);
            writer.WriteBoolean("pathValueWasAbsent", receipt.PathValueWasAbsent);
            writer.WriteString("pathValueKind", receipt.PathValueKind.ToString());
            writer.WriteBoolean("pathSeparatorAdded", receipt.PathSeparatorAdded);
            writer.WriteBoolean("shortcutDirectoryWasAbsent", receipt.ShortcutDirectoryWasAbsent);
            writer.WriteBoolean("receiptDirectoryWasAbsent", receipt.ReceiptDirectoryWasAbsent);
            writer.WriteBoolean("stateRootWasAbsent", receipt.StateRootWasAbsent);
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }

    private ShellIntegrationReceipt? ReadReceipt(CurrentUserShellIntegrationSpec spec)
    {
        if (!File.Exists(spec.ReceiptPath) || HasExistingReparsePoint(spec.ReceiptPath))
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(spec.ReceiptPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8,
            });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in root.EnumerateObject())
            {
                if (!names.Add(property.Name) || !AllowedReceiptProperties.Contains(property.Name))
                {
                    return null;
                }
            }
            if (names.Count != AllowedReceiptProperties.Count ||
                !root.TryGetProperty("schemaVersion", out var schema) || schema.GetInt32() != ReceiptSchemaVersion ||
                !root.TryGetProperty("pathEntry", out var pathEntry) ||
                !root.TryGetProperty("shortcutPath", out var shortcutPath) ||
                !root.TryGetProperty("shortcutTarget", out var shortcutTarget) ||
                !root.TryGetProperty("shortcutWorkingDirectory", out var shortcutWorkingDirectory) ||
                !root.TryGetProperty("shortcutArguments", out var shortcutArguments) ||
                !root.TryGetProperty("pathValueWasAbsent", out var wasAbsent) ||
                !root.TryGetProperty("pathValueKind", out var kindElement) ||
                !root.TryGetProperty("pathSeparatorAdded", out var pathSeparatorAdded) ||
                !root.TryGetProperty("shortcutDirectoryWasAbsent", out var shortcutDirectoryWasAbsent) ||
                !root.TryGetProperty("receiptDirectoryWasAbsent", out var receiptDirectoryWasAbsent) ||
                !root.TryGetProperty("stateRootWasAbsent", out var stateRootWasAbsent) ||
                pathEntry.ValueKind != JsonValueKind.String ||
                shortcutPath.ValueKind != JsonValueKind.String ||
                shortcutTarget.ValueKind != JsonValueKind.String ||
                shortcutWorkingDirectory.ValueKind != JsonValueKind.String ||
                shortcutArguments.ValueKind != JsonValueKind.String ||
                wasAbsent.ValueKind is not (JsonValueKind.True or JsonValueKind.False) ||
                kindElement.ValueKind != JsonValueKind.String ||
                pathSeparatorAdded.ValueKind is not (JsonValueKind.True or JsonValueKind.False) ||
                shortcutDirectoryWasAbsent.ValueKind is not (JsonValueKind.True or JsonValueKind.False) ||
                receiptDirectoryWasAbsent.ValueKind is not (JsonValueKind.True or JsonValueKind.False) ||
                stateRootWasAbsent.ValueKind is not (JsonValueKind.True or JsonValueKind.False) ||
                !Enum.TryParse<RegistryValueKind>(kindElement.GetString(), ignoreCase: false, out var kind) ||
                !string.Equals(kindElement.GetString(), kind.ToString(), StringComparison.Ordinal) ||
                kind is not (RegistryValueKind.String or RegistryValueKind.ExpandString))
            {
                return null;
            }
            var receipt = new ShellIntegrationReceipt(
                ReceiptSchemaVersion,
                pathEntry.GetString()!,
                shortcutPath.GetString()!,
                shortcutTarget.GetString()!,
                shortcutWorkingDirectory.GetString()!,
                shortcutArguments.GetString()!,
                wasAbsent.GetBoolean(),
                kind,
                pathSeparatorAdded.GetBoolean(),
                shortcutDirectoryWasAbsent.GetBoolean(),
                receiptDirectoryWasAbsent.GetBoolean(),
                stateRootWasAbsent.GetBoolean());
            return ReceiptMatchesSpec(receipt, spec) ? receipt : null;
        }
        catch (Exception exception) when (exception is
            JsonException or IOException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    private static bool ReceiptMatchesSpec(
        ShellIntegrationReceipt receipt,
        CurrentUserShellIntegrationSpec spec) =>
        receipt.PathEntry.Equals(spec.PathEntry, StringComparison.OrdinalIgnoreCase) &&
        receipt.ShortcutPath.Equals(spec.ShortcutPath, StringComparison.OrdinalIgnoreCase) &&
        receipt.ShortcutTarget.Equals(spec.ShortcutTarget, StringComparison.OrdinalIgnoreCase) &&
        receipt.ShortcutWorkingDirectory.Equals(spec.ShortcutWorkingDirectory, StringComparison.OrdinalIgnoreCase) &&
        receipt.ShortcutArguments.Equals(spec.ShortcutArguments, StringComparison.Ordinal);

    private void DeleteReceipt(CurrentUserShellIntegrationSpec spec)
    {
        var receipt = ReadReceipt(spec);
        if (File.Exists(spec.ReceiptPath))
        {
            if (HasExistingReparsePoint(spec.ReceiptPath))
            {
                throw Conflict();
            }
            File.Delete(spec.ReceiptPath);
        }
        if (receipt?.ReceiptDirectoryWasAbsent == true)
        {
            DeleteDirectoryIfEmpty(spec.ReceiptDirectory);
        }
        if (receipt?.StateRootWasAbsent == true)
        {
            DeleteDirectoryIfEmpty(Path.GetDirectoryName(spec.ReceiptDirectory)!);
        }
    }

    private static void DeleteDirectoryIfEmpty(string path)
    {
        if (Directory.Exists(path) &&
            !HasExistingReparsePoint(path) &&
            !Directory.EnumerateFileSystemEntries(path).Any())
        {
            Directory.Delete(path);
        }
    }

    private static IReadOnlyList<string> SplitPath(string value) => value.Split(';');

    private static (int Start, int Length)[] FindExactPathEntryBounds(string value, string expected)
    {
        var matches = new List<(int Start, int Length)>();
        var start = 0;
        while (start <= value.Length)
        {
            var separator = value.IndexOf(';', start);
            var end = separator < 0 ? value.Length : separator;
            if (value.AsSpan(start, end - start).Equals(expected.AsSpan(), StringComparison.OrdinalIgnoreCase))
            {
                matches.Add((start, end - start));
            }
            if (separator < 0)
            {
                break;
            }
            start = separator + 1;
        }
        return matches.ToArray();
    }

    private static bool PathsEquivalent(string candidate, string expected)
    {
        try
        {
            var trimmed = candidate.Trim().Trim('"');
            if (trimmed.Length == 0)
            {
                return false;
            }
            var expanded = Environment.ExpandEnvironmentVariables(trimmed);
            var normalized = Path.GetFullPath(expanded).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            return normalized.Equals(expected, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    private static bool HasExistingReparsePoint(string path)
    {
        var current = Path.GetFullPath(path);
        while (!string.IsNullOrEmpty(current))
        {
            if ((File.Exists(current) || Directory.Exists(current)) &&
                (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                return true;
            }
            var parent = Path.GetDirectoryName(current);
            if (string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            current = parent ?? string.Empty;
        }
        return false;
    }

    private static void TryRollback(Action action, ICollection<Exception> failures)
    {
        try
        {
            action();
        }
        catch (Exception rollbackFailure)
        {
            failures.Add(rollbackFailure);
        }
    }

    private static InstallationException Conflict() => new(
        "aigw_shell_integration_conflict",
        "The current-user PATH or Local AI Gateway Start Menu entry is not owned; all existing values were preserved.");

    private static readonly HashSet<string> AllowedReceiptProperties =
    [
        "schemaVersion",
        "pathEntry",
        "shortcutPath",
        "shortcutTarget",
        "shortcutWorkingDirectory",
        "shortcutArguments",
        "pathValueWasAbsent",
        "pathValueKind",
        "pathSeparatorAdded",
        "shortcutDirectoryWasAbsent",
        "receiptDirectoryWasAbsent",
        "stateRootWasAbsent",
    ];

    private sealed record ShellIntegrationReceipt(
        int SchemaVersion,
        string PathEntry,
        string ShortcutPath,
        string ShortcutTarget,
        string ShortcutWorkingDirectory,
        string ShortcutArguments,
        bool PathValueWasAbsent,
        RegistryValueKind PathValueKind,
        bool PathSeparatorAdded,
        bool ShortcutDirectoryWasAbsent,
        bool ReceiptDirectoryWasAbsent,
        bool StateRootWasAbsent);
}

internal sealed class WindowsUserPathStore : IUserPathStore
{
    private const string EnvironmentKey = "Environment";
    private const string PathValueName = "Path";

    public UserPathValue Read()
    {
        using var key = Registry.CurrentUser.OpenSubKey(EnvironmentKey, writable: false);
        if (key?.GetValue(PathValueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not object value)
        {
            return new UserPathValue(false, string.Empty, RegistryValueKind.ExpandString);
        }
        if (value is not string text)
        {
            throw new InstallationException(
                "aigw_shell_integration_path_invalid",
                "The current-user PATH registry value is not a string and was preserved.");
        }
        var kind = key!.GetValueKind(PathValueName);
        if (kind is not (RegistryValueKind.String or RegistryValueKind.ExpandString))
        {
            throw new InstallationException(
                "aigw_shell_integration_path_invalid",
                "The current-user PATH registry value has an unsupported type and was preserved.");
        }
        return new UserPathValue(true, text, kind);
    }

    public void Write(string value, RegistryValueKind kind)
    {
        using var key = Registry.CurrentUser.CreateSubKey(EnvironmentKey, writable: true)
            ?? throw new IOException("The current-user environment registry key could not be opened.");
        key.SetValue(PathValueName, value, kind);
        key.Flush();
    }

    public void Delete()
    {
        using var key = Registry.CurrentUser.OpenSubKey(EnvironmentKey, writable: true);
        key?.DeleteValue(PathValueName, throwOnMissingValue: false);
        key?.Flush();
    }

    public void NotifyChanged()
    {
        _ = SendMessageTimeout(
            new IntPtr(0xffff),
            0x001A,
            UIntPtr.Zero,
            "Environment",
            0x0002,
            5000,
            out _);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        string lParam,
        uint flags,
        uint timeout,
        out UIntPtr result);
}

internal sealed class WindowsScriptShortcutStore : IWindowsShortcutStore
{
    public bool Exists(string path) => File.Exists(path);

    public bool Matches(string path, CurrentUserShellIntegrationSpec spec)
    {
        if (!File.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            return false;
        }
        return WithShortcut(path, shortcut =>
            GetProperty(shortcut, "TargetPath").Equals(spec.ShortcutTarget, StringComparison.OrdinalIgnoreCase) &&
            GetProperty(shortcut, "WorkingDirectory").Equals(spec.ShortcutWorkingDirectory, StringComparison.OrdinalIgnoreCase) &&
            GetProperty(shortcut, "Arguments").Equals(spec.ShortcutArguments, StringComparison.Ordinal));
    }

    public void Create(CurrentUserShellIntegrationSpec spec)
    {
        if (!File.Exists(spec.ShortcutTarget) ||
            (File.GetAttributes(spec.ShortcutTarget) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InstallationException(
                "aigw_shell_integration_target_invalid",
                "The installed Tray executable is missing or is a reparse point.");
        }
        var directoryExisted = Directory.Exists(spec.ShortcutDirectory);
        Directory.CreateDirectory(spec.ShortcutDirectory);
        var temporary = Path.Combine(spec.ShortcutDirectory, $".Local-AI-Gateway-{Guid.NewGuid():N}.lnk");
        try
        {
            WithShortcut(temporary, shortcut =>
            {
                SetProperty(shortcut, "TargetPath", spec.ShortcutTarget);
                SetProperty(shortcut, "WorkingDirectory", spec.ShortcutWorkingDirectory);
                SetProperty(shortcut, "Arguments", spec.ShortcutArguments);
                SetProperty(shortcut, "Description", "Local AI Gateway");
                SetProperty(shortcut, "IconLocation", spec.ShortcutTarget + ",0");
                Invoke(shortcut, "Save");
                return true;
            });
            File.Move(temporary, spec.ShortcutPath);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
            if (!directoryExisted &&
                Directory.Exists(spec.ShortcutDirectory) &&
                !Directory.EnumerateFileSystemEntries(spec.ShortcutDirectory).Any())
            {
                Directory.Delete(spec.ShortcutDirectory);
            }
        }
    }

    public void Delete(string path, bool deleteEmptyDirectory)
    {
        if (File.Exists(path))
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InstallationException(
                    "aigw_shell_integration_conflict",
                    "The Start Menu shortcut is a reparse point and was preserved.");
            }
            File.Delete(path);
        }
        var directory = Path.GetDirectoryName(path);
        if (deleteEmptyDirectory &&
            directory is not null &&
            Directory.Exists(directory) &&
            !Directory.EnumerateFileSystemEntries(directory).Any())
        {
            Directory.Delete(directory);
        }
    }

    private static T WithShortcut<T>(string path, Func<object, T> action)
    {
        var shellType = Type.GetTypeFromProgID("WScript.Shell", throwOnError: true)!;
        object? shell = null;
        object? shortcut = null;
        try
        {
            shell = Activator.CreateInstance(shellType)
                ?? throw new InvalidOperationException("WScript.Shell could not be created.");
            shortcut = shellType.InvokeMember(
                "CreateShortcut",
                BindingFlags.InvokeMethod,
                binder: null,
                shell,
                [path]) ?? throw new InvalidOperationException("The Windows shortcut object could not be created.");
            return action(shortcut);
        }
        finally
        {
            ReleaseComObject(shortcut);
            ReleaseComObject(shell);
        }
    }

    private static string GetProperty(object target, string name) =>
        target.GetType().InvokeMember(
            name,
            BindingFlags.GetProperty,
            binder: null,
            target,
            null) as string ?? string.Empty;

    private static void SetProperty(object target, string name, string value) =>
        target.GetType().InvokeMember(
            name,
            BindingFlags.SetProperty,
            binder: null,
            target,
            [value]);

    private static void Invoke(object target, string name) =>
        target.GetType().InvokeMember(
            name,
            BindingFlags.InvokeMethod,
            binder: null,
            target,
            null);

    private static void ReleaseComObject(object? value)
    {
        if (value is not null && Marshal.IsComObject(value))
        {
            _ = Marshal.FinalReleaseComObject(value);
        }
    }
}
