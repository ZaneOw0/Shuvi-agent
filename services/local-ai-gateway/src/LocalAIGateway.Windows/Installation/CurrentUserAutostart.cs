using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Xml;
using System.Xml.Linq;
using LocalAIGateway.Core.Installation;

namespace LocalAIGateway.Windows.Installation;

public sealed record CurrentUserAutostartComponentStatus(
    string TaskPath,
    bool Registered,
    bool Owned,
    bool Conflict);

public sealed record CurrentUserAutostartStatus(
    CurrentUserAutostartComponentStatus Runtime,
    CurrentUserAutostartComponentStatus Tray)
{
    public string TaskPath => Runtime.TaskPath;

    public bool Registered => Runtime.Registered || Tray.Registered;

    public bool Owned => Runtime.Owned && Tray.Owned;

    public bool Conflict => Runtime.Conflict || Tray.Conflict;

    public bool Incomplete => !Conflict && Registered && !Owned;
}

public sealed record CurrentUserAutostartOperationResult(
    bool Changed,
    CurrentUserAutostartStatus Status);

internal enum CurrentUserAutostartTaskState
{
    Absent,
    Owned,
    Conflict,
}

internal enum CurrentUserAutostartTaskKind
{
    Runtime,
    Tray,
}

internal sealed record CurrentUserAutostartTaskSnapshot(
    CurrentUserAutostartTaskState Runtime,
    CurrentUserAutostartTaskState Tray)
{
    public bool HasConflict =>
        Runtime == CurrentUserAutostartTaskState.Conflict ||
        Tray == CurrentUserAutostartTaskState.Conflict;

    public bool IsOwned =>
        Runtime == CurrentUserAutostartTaskState.Owned &&
        Tray == CurrentUserAutostartTaskState.Owned;

    public bool IsAbsent =>
        Runtime == CurrentUserAutostartTaskState.Absent &&
        Tray == CurrentUserAutostartTaskState.Absent;
}

internal interface ICurrentUserAutostartStore
{
    ValueTask<CurrentUserAutostartTaskSnapshot> InspectAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    ValueTask CreateAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);

    ValueTask DeleteAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default);
}

internal sealed class WindowsTaskSchedulerAutostartStore : ICurrentUserAutostartStore
{
    private const int TaskCreate = 2;
    private const int TaskLogonInteractiveToken = 3;
    private const int FileNotFoundHResult = unchecked((int)0x80070002);
    private readonly Func<CurrentUserTaskIdentity> currentUserIdentity;

    public WindowsTaskSchedulerAutostartStore()
        : this(GetCurrentUserIdentity)
    {
    }

    internal WindowsTaskSchedulerAutostartStore(Func<CurrentUserTaskIdentity> currentUserIdentity)
    {
        ArgumentNullException.ThrowIfNull(currentUserIdentity);
        this.currentUserIdentity = currentUserIdentity;
    }

    public ValueTask<CurrentUserAutostartTaskSnapshot> InspectAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        cancellationToken.ThrowIfCancellationRequested();
        object? service = null;
        object? root = null;
        try
        {
            service = CreateConnectedService();
            root = ((dynamic)service).GetFolder("\\");
            var identity = currentUserIdentity();
            return ValueTask.FromResult(new CurrentUserAutostartTaskSnapshot(
                InspectTask(root, CurrentUserAutostartTaskKind.Runtime, target, identity),
                InspectTask(root, CurrentUserAutostartTaskKind.Tray, target, identity)));
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
                "aigw_autostart_query_failed",
                "The current-user login autostart task could not be inspected.",
                exception);
        }
        finally
        {
            ReleaseComObject(root);
            ReleaseComObject(service);
        }
    }

    public ValueTask CreateAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        cancellationToken.ThrowIfCancellationRequested();
        object? service = null;
        object? root = null;
        var createdTaskNames = new List<string>();
        try
        {
            service = CreateConnectedService();
            root = ((dynamic)service).GetFolder("\\");
            var identity = currentUserIdentity();
            foreach (var kind in TaskKinds)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var state = InspectTask(root, kind, target, identity);
                if (state == CurrentUserAutostartTaskState.Conflict)
                {
                    throw AutostartConflict(kind);
                }

                if (state == CurrentUserAutostartTaskState.Owned)
                {
                    continue;
                }

                object? registeredTask = null;
                try
                {
                    var taskName = CurrentUserAutostartTaskXml.GetTaskName(kind);
                    registeredTask = ((dynamic)root).RegisterTask(
                        taskName,
                        CurrentUserAutostartTaskXml.Create(target, identity.Sid, kind),
                        TaskCreate,
                        identity.Sid,
                        null,
                        TaskLogonInteractiveToken,
                        null);
                    createdTaskNames.Add(taskName);
                }
                finally
                {
                    ReleaseComObject(registeredTask);
                }
            }

            return ValueTask.CompletedTask;
        }
        catch (Exception exception)
        {
            var failures = new List<Exception> { exception };
            if (root is not null)
            {
                foreach (var taskName in createdTaskNames.AsEnumerable().Reverse())
                {
                    try
                    {
                        ((dynamic)root).DeleteTask(taskName, 0);
                    }
                    catch (Exception rollbackFailure)
                    {
                        failures.Add(rollbackFailure);
                    }
                }
            }

            if (failures.Count == 1 && exception is OperationCanceledException)
            {
                throw;
            }

            throw new InstallationException(
                failures.Count == 1 && exception is InstallationException installationException
                    ? installationException.ErrorCode
                    : failures.Count == 1
                        ? "aigw_autostart_registration_failed"
                        : "aigw_autostart_rollback_failed",
                failures.Count == 1 && exception is InstallationException
                    ? exception.Message
                    : failures.Count == 1
                        ? "The current-user login autostart tasks could not be registered without replacing existing tasks."
                        : "Login autostart registration failed and newly created task rollback was incomplete.",
                new AggregateException(failures));
        }
        finally
        {
            ReleaseComObject(root);
            ReleaseComObject(service);
        }
    }

    public ValueTask DeleteAsync(
        CurrentUserInstallationTarget target,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        cancellationToken.ThrowIfCancellationRequested();
        object? service = null;
        object? root = null;
        try
        {
            service = CreateConnectedService();
            root = ((dynamic)service).GetFolder("\\");
            var identity = currentUserIdentity();
            var states = TaskKinds.ToDictionary(
                kind => kind,
                kind => InspectTask(root, kind, target, identity));
            var conflict = states.FirstOrDefault(pair => pair.Value == CurrentUserAutostartTaskState.Conflict);
            if (conflict.Value == CurrentUserAutostartTaskState.Conflict)
            {
                throw AutostartConflict(conflict.Key);
            }

            foreach (var kind in TaskKinds.Reverse())
            {
                if (states[kind] == CurrentUserAutostartTaskState.Owned)
                {
                    ((dynamic)root).DeleteTask(CurrentUserAutostartTaskXml.GetTaskName(kind), 0);
                }
            }

            return ValueTask.CompletedTask;
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
                "aigw_autostart_removal_failed",
                "The owned current-user login autostart tasks could not be removed.",
                exception);
        }
        finally
        {
            ReleaseComObject(root);
            ReleaseComObject(service);
        }
    }

    private static IReadOnlyList<CurrentUserAutostartTaskKind> TaskKinds { get; } =
        [CurrentUserAutostartTaskKind.Runtime, CurrentUserAutostartTaskKind.Tray];

    private static CurrentUserAutostartTaskState InspectTask(
        object root,
        CurrentUserAutostartTaskKind kind,
        CurrentUserInstallationTarget target,
        CurrentUserTaskIdentity identity)
    {
        object? registeredTask = null;
        try
        {
            try
            {
                registeredTask = ((dynamic)root).GetTask(CurrentUserAutostartTaskXml.GetTaskName(kind));
            }
            catch (Exception exception) when (exception.HResult == FileNotFoundHResult)
            {
                return CurrentUserAutostartTaskState.Absent;
            }

            var xml = (string)((dynamic)registeredTask).Xml;
            return CurrentUserAutostartTaskXml.Matches(xml, target, identity.Sid, identity.AccountName, kind)
                ? CurrentUserAutostartTaskState.Owned
                : CurrentUserAutostartTaskState.Conflict;
        }
        finally
        {
            ReleaseComObject(registeredTask);
        }
    }

    private static InstallationException AutostartConflict(CurrentUserAutostartTaskKind kind) => new(
        "aigw_autostart_conflict",
        $"Task Scheduler already contains '{CurrentUserAutostartTaskXml.GetTaskPath(kind)}' with a different definition; it was preserved.");

    private static object CreateConnectedService()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new InstallationException(
                "aigw_autostart_unsupported",
                "Task Scheduler login autostart is supported only on Windows.");
        }

        var serviceType = Type.GetTypeFromProgID("Schedule.Service", throwOnError: false)
            ?? throw new InstallationException(
                "aigw_autostart_unavailable",
                "The Windows Task Scheduler service is unavailable.");
        var service = Activator.CreateInstance(serviceType)
            ?? throw new InstallationException(
                "aigw_autostart_unavailable",
                "The Windows Task Scheduler service could not be created.");
        try
        {
            ((dynamic)service).Connect();
            return service;
        }
        catch
        {
            ReleaseComObject(service);
            throw;
        }
    }

    private static CurrentUserTaskIdentity GetCurrentUserIdentity()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User?.Value
            ?? throw new InstallationException(
                "aigw_autostart_identity_unavailable",
                "The current Windows user SID could not be resolved.");
        return new CurrentUserTaskIdentity(sid, identity.Name);
    }

    private static void ReleaseComObject(object? value)
    {
        if (value is not null && Marshal.IsComObject(value))
        {
            Marshal.FinalReleaseComObject(value);
        }
    }
}

internal sealed record CurrentUserTaskIdentity(string Sid, string AccountName);

internal static class CurrentUserAutostartTaskXml
{
    public const string TaskName = "LocalAIGateway.Runtime";
    public const string TaskPath = "\\LocalAIGateway.Runtime";
    public const string Arguments = "--serve";
    public const string TrayTaskName = "LocalAIGateway.Tray";
    public const string TrayTaskPath = "\\LocalAIGateway.Tray";
    private const string Source = "LocalAIGateway";
    private const string RuntimeDescription = "Local AI Gateway runtime login autostart.";
    private const string TrayDescription = "Local AI Gateway tray login autostart.";
    private static readonly XNamespace TaskNamespace =
        "http://schemas.microsoft.com/windows/2004/02/mit/task";

    public static string Create(CurrentUserInstallationTarget target, string userSid) =>
        Create(target, userSid, CurrentUserAutostartTaskKind.Runtime);

    public static string Create(
        CurrentUserInstallationTarget target,
        string userSid,
        CurrentUserAutostartTaskKind kind)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new ArgumentException("A Windows user SID is required.", nameof(userSid));
        }

        var definition = Definition(target, kind);
        var document = new XDocument(
            new XDeclaration("1.0", "UTF-16", null),
            new XElement(TaskNamespace + "Task",
                new XAttribute("version", "1.4"),
                new XElement(TaskNamespace + "RegistrationInfo",
                    new XElement(TaskNamespace + "Source", Source),
                    new XElement(TaskNamespace + "Description", definition.Description),
                    new XElement(TaskNamespace + "URI", definition.TaskPath)),
                new XElement(TaskNamespace + "Triggers",
                    new XElement(TaskNamespace + "LogonTrigger",
                        new XElement(TaskNamespace + "Enabled", "true"),
                        new XElement(TaskNamespace + "UserId", userSid))),
                new XElement(TaskNamespace + "Principals",
                    new XElement(TaskNamespace + "Principal",
                        new XAttribute("id", "CurrentUser"),
                        new XElement(TaskNamespace + "UserId", userSid),
                        new XElement(TaskNamespace + "LogonType", "InteractiveToken"),
                        new XElement(TaskNamespace + "RunLevel", "LeastPrivilege"))),
                new XElement(TaskNamespace + "Settings",
                    new XElement(TaskNamespace + "MultipleInstancesPolicy", "IgnoreNew"),
                    new XElement(TaskNamespace + "DisallowStartIfOnBatteries", "false"),
                    new XElement(TaskNamespace + "StopIfGoingOnBatteries", "false"),
                    new XElement(TaskNamespace + "AllowHardTerminate", "true"),
                    new XElement(TaskNamespace + "StartWhenAvailable", "false"),
                    new XElement(TaskNamespace + "RunOnlyIfNetworkAvailable", "false"),
                    new XElement(TaskNamespace + "IdleSettings",
                        new XElement(TaskNamespace + "StopOnIdleEnd", "false"),
                        new XElement(TaskNamespace + "RestartOnIdle", "false")),
                    new XElement(TaskNamespace + "AllowStartOnDemand", "true"),
                    new XElement(TaskNamespace + "Enabled", "true"),
                    new XElement(TaskNamespace + "Hidden", "false"),
                    new XElement(TaskNamespace + "RunOnlyIfIdle", "false"),
                    new XElement(TaskNamespace + "WakeToRun", "false"),
                    new XElement(TaskNamespace + "ExecutionTimeLimit", "PT0S"),
                    new XElement(TaskNamespace + "Priority", "7"),
                    new XElement(TaskNamespace + "UseUnifiedSchedulingEngine", "true")),
                new XElement(TaskNamespace + "Actions",
                    new XAttribute("Context", "CurrentUser"),
                    new XElement(TaskNamespace + "Exec",
                        new XElement(TaskNamespace + "Command", definition.Command),
                        new XElement(TaskNamespace + "Arguments", definition.Arguments),
                        new XElement(TaskNamespace + "WorkingDirectory", definition.WorkingDirectory)))));
        return document.ToString(SaveOptions.DisableFormatting);
    }

    public static bool Matches(
        string xml,
        CurrentUserInstallationTarget target,
        string userSid,
        string? accountName = null) =>
        Matches(xml, target, userSid, accountName, CurrentUserAutostartTaskKind.Runtime);

    public static bool Matches(
        string xml,
        CurrentUserInstallationTarget target,
        string userSid,
        string? accountName,
        CurrentUserAutostartTaskKind kind)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (string.IsNullOrWhiteSpace(xml) || string.IsNullOrWhiteSpace(userSid))
        {
            return false;
        }

        try
        {
            var definition = Definition(target, kind);
            using var reader = XmlReader.Create(
                new StringReader(xml),
                new XmlReaderSettings
                {
                    DtdProcessing = DtdProcessing.Prohibit,
                    XmlResolver = null,
                });
            var document = XDocument.Load(reader, LoadOptions.None);
            var task = document.Root;
            if (task is null || task.Name != TaskNamespace + "Task")
            {
                return false;
            }

            var registration = Single(task, "RegistrationInfo");
            var triggers = Single(task, "Triggers");
            var principals = Single(task, "Principals");
            var settings = Single(task, "Settings");
            var actions = Single(task, "Actions");
            if (registration is null || triggers is null || principals is null || settings is null || actions is null)
            {
                return false;
            }

            var trigger = SingleOnlyChild(triggers, "LogonTrigger");
            var principal = SingleOnlyChild(principals, "Principal");
            var action = SingleOnlyChild(actions, "Exec");
            var idle = Single(settings, "IdleSettings");
            if (trigger is null || principal is null || action is null || idle is null)
            {
                return false;
            }

            return Value(registration, "Source") == Source &&
                   Value(registration, "Description") == definition.Description &&
                   Value(registration, "URI") == definition.TaskPath &&
                   ValueOrDefault(trigger, "Enabled", "true") == "true" &&
                   UserMatches(Value(trigger, "UserId"), userSid, accountName) &&
                   !trigger.Elements().Any(element => element.Name.LocalName is "Delay" or "StartBoundary" or "EndBoundary" or "Repetition") &&
                   (string?)principal.Attribute("id") == "CurrentUser" &&
                   Value(principal, "UserId") == userSid &&
                   Value(principal, "LogonType") == "InteractiveToken" &&
                   ValueOrDefault(principal, "RunLevel", "LeastPrivilege") == "LeastPrivilege" &&
                   (string?)actions.Attribute("Context") == "CurrentUser" &&
                   PathsEqual(Value(action, "Command"), definition.Command) &&
                   ValueOrDefault(action, "Arguments", string.Empty) == definition.Arguments &&
                   PathsEqual(Value(action, "WorkingDirectory"), definition.WorkingDirectory) &&
                   Value(settings, "MultipleInstancesPolicy") == "IgnoreNew" &&
                   Value(settings, "DisallowStartIfOnBatteries") == "false" &&
                   Value(settings, "StopIfGoingOnBatteries") == "false" &&
                   ValueOrDefault(settings, "AllowHardTerminate", "true") == "true" &&
                   ValueOrDefault(settings, "StartWhenAvailable", "false") == "false" &&
                   ValueOrDefault(settings, "RunOnlyIfNetworkAvailable", "false") == "false" &&
                   ValueOrDefault(settings, "AllowStartOnDemand", "true") == "true" &&
                   ValueOrDefault(settings, "Enabled", "true") == "true" &&
                   ValueOrDefault(settings, "Hidden", "false") == "false" &&
                   ValueOrDefault(settings, "RunOnlyIfIdle", "false") == "false" &&
                   ValueOrDefault(settings, "WakeToRun", "false") == "false" &&
                   Value(settings, "ExecutionTimeLimit") == "PT0S" &&
                   ValueOrDefault(settings, "Priority", "7") == "7" &&
                   Value(settings, "UseUnifiedSchedulingEngine") == "true" &&
                   Value(idle, "StopOnIdleEnd") == "false" &&
                   Value(idle, "RestartOnIdle") == "false";
        }
        catch (Exception exception) when (exception is XmlException or InvalidOperationException or ArgumentException or IOException or NotSupportedException)
        {
            return false;
        }
    }

    public static string GetTaskName(CurrentUserAutostartTaskKind kind) => kind switch
    {
        CurrentUserAutostartTaskKind.Runtime => TaskName,
        CurrentUserAutostartTaskKind.Tray => TrayTaskName,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    public static string GetTaskPath(CurrentUserAutostartTaskKind kind) => kind switch
    {
        CurrentUserAutostartTaskKind.Runtime => TaskPath,
        CurrentUserAutostartTaskKind.Tray => TrayTaskPath,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static CurrentUserAutostartTaskDefinition Definition(
        CurrentUserInstallationTarget target,
        CurrentUserAutostartTaskKind kind) => kind switch
    {
        CurrentUserAutostartTaskKind.Runtime => new(
            TaskPath,
            RuntimeDescription,
            target.RuntimeExecutablePath,
            Arguments,
            target.InstallRoot),
        CurrentUserAutostartTaskKind.Tray => new(
            TrayTaskPath,
            TrayDescription,
            target.TrayExecutablePath,
            string.Empty,
            target.TrayDirectory),
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private sealed record CurrentUserAutostartTaskDefinition(
        string TaskPath,
        string Description,
        string Command,
        string Arguments,
        string WorkingDirectory);

    private static XElement? Single(XElement parent, string localName)
    {
        var elements = parent.Elements(TaskNamespace + localName).Take(2).ToArray();
        return elements.Length == 1 ? elements[0] : null;
    }

    private static XElement? SingleOnlyChild(XElement parent, string localName)
    {
        var children = parent.Elements().Take(2).ToArray();
        return children.Length == 1 && children[0].Name == TaskNamespace + localName
            ? children[0]
            : null;
    }

    private static string? Value(XElement parent, string localName) =>
        Single(parent, localName)?.Value;

    private static string? ValueOrDefault(XElement parent, string localName, string defaultValue) =>
        Value(parent, localName) ?? defaultValue;

    private static bool UserMatches(string? actual, string sid, string? accountName) =>
        string.Equals(actual, sid, StringComparison.OrdinalIgnoreCase) ||
        (!string.IsNullOrWhiteSpace(accountName) &&
         string.Equals(actual, accountName, StringComparison.OrdinalIgnoreCase));

    private static bool PathsEqual(string? first, string second)
    {
        if (string.IsNullOrWhiteSpace(first))
        {
            return false;
        }

        var normalizedFirst = Path.GetFullPath(first).TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        var normalizedSecond = Path.GetFullPath(second).TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        return string.Equals(normalizedFirst, normalizedSecond, StringComparison.OrdinalIgnoreCase);
    }
}
