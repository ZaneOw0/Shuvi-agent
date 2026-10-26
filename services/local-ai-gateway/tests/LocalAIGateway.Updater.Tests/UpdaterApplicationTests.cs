using System.Text.Json;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Updater;

namespace LocalAIGateway.Updater.Tests;

public sealed class UpdaterApplicationTests
{
    [Fact]
    public async Task Inspect_emits_stable_trust_and_hash_data()
    {
        var service = new FakeService();
        var output = new StringWriter();
        var error = new StringWriter();

        var exit = await UpdaterApplication.RunAsync(
            InspectArguments(), output, error, _ => service);

        Assert.Equal(0, exit);
        using var json = JsonDocument.Parse(output.ToString());
        Assert.Equal("inspect", json.RootElement.GetProperty("operation").GetString());
        Assert.Equal("unsigned-development", json.RootElement.GetProperty("trustKind").GetString());
        Assert.True(service.AllowUnsigned);
        Assert.Empty(error.ToString());
    }

    [Fact]
    public async Task Apply_passes_exact_confirmation_and_schedules_external_worker()
    {
        var service = new FakeService();
        PackageUpdateRequest? request = null;
        var operationId = Guid.NewGuid().ToString("N");
        var receiptPath = $"C:\\state\\update-receipts\\{operationId}.json";
        var output = new StringWriter();

        var exit = await UpdaterApplication.RunAsync(
            ApplyArguments("UPDATE"), output, new StringWriter(), _ => service,
            (target, scheduledRequest, inspection, parentPid) =>
            {
                request = scheduledRequest;
                Assert.Equal("C:\\installed", target.InstallRoot);
                Assert.Equal("0.2.0-dev", inspection.Version);
                Assert.Equal(1234, parentPid);
                return Task.FromResult(new ScheduledUpdate(operationId, receiptPath));
            });

        Assert.Equal(0, exit);
        Assert.True(request!.Confirmed);
        Assert.False(request.DeferRollbackCleanup);
        using var json = JsonDocument.Parse(output.ToString());
        Assert.True(json.RootElement.GetProperty("completionPending").GetBoolean());
        Assert.Equal(operationId, json.RootElement.GetProperty("operationId").GetString());
        Assert.Equal(receiptPath, json.RootElement.GetProperty("receiptPath").GetString());
    }

    [Fact]
    public async Task Invalid_confirmation_returns_stable_update_error_without_cleanup()
    {
        var service = new FakeService();
        var error = new StringWriter();
        var scheduled = false;

        var exit = await UpdaterApplication.RunAsync(
            ApplyArguments("update"), new StringWriter(), error, _ => service,
            (_, _, _, _) =>
            {
                scheduled = true;
                return Task.FromResult(new ScheduledUpdate("unused", "C:\\unused"));
            });

        Assert.Equal(18, exit);
        Assert.False(scheduled);
        using var json = JsonDocument.Parse(error.ToString());
        Assert.Equal("aigw_update_confirmation_required", json.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task Duplicate_and_unknown_options_are_rejected()
    {
        var duplicate = InspectArguments().Concat(new[] { "--package", "C:\\other" }).ToArray();
        var unknown = InspectArguments().Concat(new[] { "--unknown", "value" }).ToArray();

        Assert.Equal(2, await UpdaterApplication.RunAsync(duplicate, new StringWriter(), new StringWriter(), _ => new FakeService()));
        Assert.Equal(2, await UpdaterApplication.RunAsync(unknown, new StringWriter(), new StringWriter(), _ => new FakeService()));
    }

    [Fact]
    public async Task Relative_or_nonfixed_runtime_targets_are_rejected()
    {
        var relative = InspectArguments();
        relative[4] = "installed";
        var nonfixedRuntime = InspectArguments();
        nonfixedRuntime[8] = "C:\\other\\aigw-runtime.exe";

        Assert.Equal(2, await UpdaterApplication.RunAsync(relative, new StringWriter(), new StringWriter(), _ => new FakeService()));
        Assert.Equal(2, await UpdaterApplication.RunAsync(nonfixedRuntime, new StringWriter(), new StringWriter(), _ => new FakeService()));
    }

    [Fact]
    public async Task Cleanup_rejects_unknown_options_before_waiting()
    {
        var args = new[]
        {
            "cleanup", "--install-root", "C:\\installed", "--cleanup-path", $"C:\\installed.rollback-{Guid.NewGuid():N}",
            "--unknown", "value",
        };

        Assert.Equal(2, await UpdaterApplication.RunAsync(args, new StringWriter(), new StringWriter()));
    }

    [Fact]
    public async Task Uninstall_requires_every_choice_and_schedules_the_external_worker()
    {
        UninstallRequest? captured = null;
        var operationId = Guid.NewGuid().ToString("N");
        var receipt = "C:\\temp\\uninstall-receipt.json";
        var output = new StringWriter();

        var exit = await UpdaterApplication.RunAsync(
            UninstallArguments(),
            output,
            new StringWriter(),
            uninstallScheduler: (target, request, parentPid) =>
            {
                Assert.Equal("C:\\LocalAppData\\Programs\\LocalAIGateway", target.InstallRoot);
                Assert.Equal(1234, parentPid);
                captured = request;
                return Task.FromResult(new ScheduledUninstall(operationId, receipt));
            });

        Assert.Equal(0, exit);
        Assert.NotNull(captured);
        Assert.Equal(UninstallChoice.Remove, captured.Selection.Program);
        Assert.Equal(UninstallChoice.Keep, captured.Selection.Configuration);
        Assert.Equal(2, captured.BackupPaths.Count);
        Assert.Equal("claude-vscode", Assert.Single(captured.IntegrationTargets).Client);
        using var json = JsonDocument.Parse(output.ToString());
        Assert.Equal("uninstall", json.RootElement.GetProperty("operation").GetString());
        Assert.True(json.RootElement.GetProperty("completionPending").GetBoolean());
        Assert.Equal(operationId, json.RootElement.GetProperty("operationId").GetString());
    }

    [Fact]
    public async Task Uninstall_invalid_confirmation_or_missing_selection_fails_before_schedule()
    {
        var scheduled = false;
        var wrongConfirmation = UninstallArguments();
        wrongConfirmation[Array.IndexOf(wrongConfirmation, "--confirm") + 1] = "uninstall";
        var missingSelection = UninstallArguments().ToList();
        var logsIndex = missingSelection.IndexOf("--logs");
        missingSelection.RemoveRange(logsIndex, 2);

        var wrongExit = await UpdaterApplication.RunAsync(
            wrongConfirmation,
            new StringWriter(),
            new StringWriter(),
            uninstallScheduler: (_, _, _) =>
            {
                scheduled = true;
                throw new InvalidOperationException();
            });
        var missingExit = await UpdaterApplication.RunAsync(
            missingSelection.ToArray(),
            new StringWriter(),
            new StringWriter(),
            uninstallScheduler: (_, _, _) =>
            {
                scheduled = true;
                throw new InvalidOperationException();
            });

        Assert.Equal(UpdaterApplication.UninstallErrorExitCode, wrongExit);
        Assert.Equal(UpdaterApplication.InvalidArgumentsExitCode, missingExit);
        Assert.False(scheduled);
    }

    [Fact]
    public async Task Uninstall_rejects_nonfixed_current_user_target_layout_before_schedule()
    {
        var arguments = UninstallArguments();
        arguments[Array.IndexOf(arguments, "--state-root") + 1] = "C:\\other-state";
        var scheduled = false;

        var exit = await UpdaterApplication.RunAsync(
            arguments,
            new StringWriter(),
            new StringWriter(),
            uninstallScheduler: (_, _, _) =>
            {
                scheduled = true;
                throw new InvalidOperationException();
            });

        Assert.Equal(UpdaterApplication.UninstallErrorExitCode, exit);
        Assert.False(scheduled);
    }

    private static string[] InspectArguments() =>
    [
        "inspect", "--package", "C:\\candidate", "--install-root", "C:\\installed",
        "--state-root", "C:\\state", "--runtime-executable", "C:\\installed\\aigw-runtime.exe",
        "--allow-unsigned-development",
    ];

    private static string[] ApplyArguments(string confirmation) =>
    [
        "apply", "--package", "C:\\candidate", "--install-root", "C:\\installed",
        "--state-root", "C:\\state", "--runtime-executable", "C:\\installed\\aigw-runtime.exe",
        "--expected-manifest-sha256", new string('a', 64), "--confirm", confirmation,
        "--parent-pid", "1234", "--allow-unsigned-development",
    ];

    private static string[] UninstallArguments() =>
    [
        "uninstall", "--install-root", "C:\\LocalAppData\\Programs\\LocalAIGateway",
        "--state-root", "C:\\LocalAppData\\LocalAIGateway",
        "--runtime-executable", "C:\\LocalAppData\\Programs\\LocalAIGateway\\aigw-runtime.exe",
        "--parent-pid", "1234", "--confirm", "UNINSTALL",
        "--program", "remove", "--autostart", "remove", "--integrations", "remove",
        "--runtime-credential", "remove", "--provider-credentials", "remove",
        "--configuration", "keep", "--usage", "remove", "--logs", "keep", "--backups", "remove",
        "--claude-vscode-target", "C:\\fixture\\settings.json",
        "--backup-path", "C:\\fixture\\one.json",
        "--backup-path", "C:\\fixture\\two.json",
    ];

    private sealed class FakeService : IPackageUpdateService
    {
        public bool AllowUnsigned { get; private set; }
        public PackageUpdateRequest? Request { get; private set; }

        public Task<PackageUpdateInspection> InspectAsync(string packageRoot, bool allowUnsignedDevelopment, CancellationToken cancellationToken = default)
        {
            AllowUnsigned = allowUnsignedDevelopment;
            return Task.FromResult(new PackageUpdateInspection(
                packageRoot, "0.2.0-dev", new string('a', 64), PackageTrustKind.UnsignedDevelopment, null, 42,
                "0.1.0-dev"));
        }

        public Task<PackageUpdateResult> ApplyAsync(PackageUpdateRequest request, CancellationToken cancellationToken = default)
        {
            Request = request;
            return Task.FromResult(new PackageUpdateResult(
                "0.1.0-dev", "0.2.0-dev", new string('a', 64), PackageTrustKind.UnsignedDevelopment,
                null, true, true, false, null));
        }
    }
}
