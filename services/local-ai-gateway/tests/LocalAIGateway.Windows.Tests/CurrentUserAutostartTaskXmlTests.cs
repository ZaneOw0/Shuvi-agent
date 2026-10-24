using LocalAIGateway.Core.Installation;
using LocalAIGateway.Windows.Installation;
using System.Xml.Linq;

namespace LocalAIGateway.Windows.Tests;

public sealed class CurrentUserAutostartTaskXmlTests
{
    private const string TestSid = "S-1-5-21-1000-2000-3000-4000";

    [Fact]
    public void Generated_task_is_an_exact_owned_current_user_logon_definition()
    {
        var target = CreateTarget();

        var xml = CurrentUserAutostartTaskXml.Create(target, TestSid);

        Assert.True(CurrentUserAutostartTaskXml.Matches(xml, target, TestSid));
        Assert.Contains(target.RuntimeExecutablePath, xml, StringComparison.Ordinal);
        Assert.Contains("--serve", xml, StringComparison.Ordinal);
        Assert.Contains("InteractiveToken", xml, StringComparison.Ordinal);
        Assert.Contains("LeastPrivilege", xml, StringComparison.Ordinal);
        Assert.DoesNotContain("password", xml, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Generated_tray_task_is_an_exact_owned_current_user_logon_definition()
    {
        var target = CreateTarget();

        var xml = CurrentUserAutostartTaskXml.Create(
            target,
            TestSid,
            CurrentUserAutostartTaskKind.Tray);

        Assert.True(CurrentUserAutostartTaskXml.Matches(
            xml,
            target,
            TestSid,
            accountName: null,
            kind: CurrentUserAutostartTaskKind.Tray));
        Assert.Contains(CurrentUserAutostartTaskXml.TrayTaskPath, xml, StringComparison.Ordinal);
        Assert.Contains(target.TrayExecutablePath, xml, StringComparison.Ordinal);
        Assert.Contains(target.TrayDirectory, xml, StringComparison.Ordinal);
        Assert.DoesNotContain("--serve", xml, StringComparison.Ordinal);
        Assert.DoesNotContain("password", xml, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Runtime_and_tray_task_definitions_are_not_interchangeable()
    {
        var target = CreateTarget();
        var runtimeXml = CurrentUserAutostartTaskXml.Create(target, TestSid);
        var trayXml = CurrentUserAutostartTaskXml.Create(
            target,
            TestSid,
            CurrentUserAutostartTaskKind.Tray);

        Assert.False(CurrentUserAutostartTaskXml.Matches(
            runtimeXml,
            target,
            TestSid,
            accountName: null,
            kind: CurrentUserAutostartTaskKind.Tray));
        Assert.False(CurrentUserAutostartTaskXml.Matches(trayXml, target, TestSid));
    }

    [Fact]
    public void Scheduler_may_omit_the_empty_tray_arguments_element()
    {
        var target = CreateTarget();
        var document = XDocument.Parse(CurrentUserAutostartTaskXml.Create(
            target,
            TestSid,
            CurrentUserAutostartTaskKind.Tray));
        XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        document.Descendants(ns + "Exec").Single().Element(ns + "Arguments")!.Remove();

        Assert.True(CurrentUserAutostartTaskXml.Matches(
            document.ToString(SaveOptions.DisableFormatting),
            target,
            TestSid,
            accountName: null,
            kind: CurrentUserAutostartTaskKind.Tray));
    }

    [Theory]
    [InlineData("--serve", "--serve --unexpected")]
    [InlineData("InteractiveToken", "Password")]
    [InlineData("LeastPrivilege", "HighestAvailable")]
    [InlineData("IgnoreNew", "Parallel")]
    [InlineData("LocalAIGateway.Runtime", "Other.Runtime")]
    public void Security_or_identity_changes_are_conflicts(string expected, string replacement)
    {
        var target = CreateTarget();
        var xml = CurrentUserAutostartTaskXml.Create(target, TestSid)
            .Replace(expected, replacement, StringComparison.Ordinal);

        Assert.False(CurrentUserAutostartTaskXml.Matches(xml, target, TestSid));
    }

    [Fact]
    public void Different_user_or_action_path_is_a_conflict()
    {
        var target = CreateTarget();
        var xml = CurrentUserAutostartTaskXml.Create(target, TestSid);
        var otherTarget = CurrentUserInstallationPlan.CreateTarget(
            Path.Combine(Path.GetTempPath(), "LocalAIGateway-Autostart-Other"));

        Assert.False(CurrentUserAutostartTaskXml.Matches(xml, target, "S-1-5-21-9-9-9-9"));
        Assert.False(CurrentUserAutostartTaskXml.Matches(xml, otherTarget, TestSid));
    }

    [Fact]
    public void Malformed_or_dtd_xml_is_never_treated_as_owned()
    {
        var target = CreateTarget();

        Assert.False(CurrentUserAutostartTaskXml.Matches("<Task>", target, TestSid));
        Assert.False(CurrentUserAutostartTaskXml.Matches(
            "<!DOCTYPE Task [<!ENTITY xxe SYSTEM 'file:///C:/Windows/win.ini'>]><Task>&xxe;</Task>",
            target,
            TestSid));
    }

    [Fact]
    public void Task_scheduler_normalized_defaults_and_account_name_remain_owned()
    {
        var target = CreateTarget();
        var document = XDocument.Parse(CurrentUserAutostartTaskXml.Create(target, TestSid));
        XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        var trigger = document.Descendants(ns + "LogonTrigger").Single();
        trigger.Element(ns + "UserId")!.Value = "ALTEREGO\\Admin";
        trigger.Element(ns + "Enabled")!.Remove();
        document.Descendants(ns + "Principal").Single().Element(ns + "RunLevel")!.Remove();
        var settings = document.Descendants(ns + "Settings").Single();
        foreach (var name in new[]
        {
            "AllowHardTerminate",
            "StartWhenAvailable",
            "RunOnlyIfNetworkAvailable",
            "AllowStartOnDemand",
            "Enabled",
            "Hidden",
            "RunOnlyIfIdle",
            "WakeToRun",
            "Priority",
        })
        {
            settings.Element(ns + name)!.Remove();
        }

        var normalizedXml = document.ToString(SaveOptions.DisableFormatting);

        Assert.True(CurrentUserAutostartTaskXml.Matches(
            normalizedXml,
            target,
            TestSid,
            "ALTEREGO\\Admin"));
        Assert.False(CurrentUserAutostartTaskXml.Matches(
            normalizedXml,
            target,
            TestSid,
            "OTHER\\User"));
    }

    private static CurrentUserInstallationTarget CreateTarget() =>
        CurrentUserInstallationPlan.CreateTarget(
            Path.Combine(Path.GetTempPath(), "LocalAIGateway Autostart XML"));
}
