using LocalAIGateway.Core.Uninstall;

namespace LocalAIGateway.Cli.Tests;

public sealed class UninstallSelectionResolverTests
{
    [Fact]
    public async Task Non_interactive_mode_requires_every_category_and_exact_confirmation()
    {
        var choices = All("keep");
        choices.Remove("logs");
        var resolver = new UninstallSelectionResolver(new StringReader(string.Empty), new StringWriter());

        var incomplete = await Assert.ThrowsAsync<UninstallException>(() =>
            resolver.ResolveAsync(true, choices, "UNINSTALL"));
        var unconfirmed = await Assert.ThrowsAsync<UninstallException>(() =>
            resolver.ResolveAsync(true, All("keep"), "uninstall"));

        Assert.Equal("aigw_uninstall_selection_incomplete", incomplete.ErrorCode);
        Assert.Equal("aigw_uninstall_confirmation_required", unconfirmed.ErrorCode);
    }

    [Fact]
    public async Task Non_interactive_mode_maps_each_explicit_choice()
    {
        var choices = All("keep");
        choices["program"] = "remove";
        choices["provider-credentials"] = "remove";
        choices["usage"] = "remove";
        var resolver = new UninstallSelectionResolver(new StringReader(string.Empty), new StringWriter());

        var selection = await resolver.ResolveAsync(true, choices, "UNINSTALL");

        Assert.Equal(UninstallChoice.Remove, selection.Program);
        Assert.Equal(UninstallChoice.Remove, selection.ProviderCredentials);
        Assert.Equal(UninstallChoice.Remove, selection.Usage);
        Assert.Equal(UninstallChoice.Keep, selection.RuntimeCredential);
        Assert.Equal(UninstallChoice.Keep, selection.Backups);
    }

    [Fact]
    public async Task Interactive_mode_prompts_every_category_and_retries_invalid_answers()
    {
        var answers = "invalid\ny\nn\n\nyes\nno\ny\nn\ny\nn\n";
        var prompts = new StringWriter();
        var resolver = new UninstallSelectionResolver(new StringReader(answers), prompts);

        var selection = await resolver.ResolveAsync(false, Empty(), null);

        Assert.Equal(UninstallChoice.Remove, selection.Program);
        Assert.Equal(UninstallChoice.Keep, selection.Autostart);
        Assert.Equal(UninstallChoice.Keep, selection.Integrations);
        Assert.Equal(UninstallChoice.Remove, selection.RuntimeCredential);
        Assert.Equal(UninstallChoice.Keep, selection.ProviderCredentials);
        Assert.Equal(UninstallChoice.Remove, selection.Configuration);
        Assert.Equal(UninstallChoice.Keep, selection.Usage);
        Assert.Equal(UninstallChoice.Remove, selection.Logs);
        Assert.Equal(UninstallChoice.Keep, selection.Backups);
        Assert.Contains("Answer y/yes or n/no.", prompts.ToString(), StringComparison.Ordinal);
        foreach (var name in UninstallSelectionResolver.CategoryNames)
        {
            Assert.Contains($"Remove {name}?", prompts.ToString(), StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Interactive_mode_rejects_preselection_and_eof()
    {
        var resolver = new UninstallSelectionResolver(new StringReader(string.Empty), new StringWriter());
        var conflict = await Assert.ThrowsAsync<UninstallException>(() =>
            resolver.ResolveAsync(false, All("keep"), null));
        var missing = await Assert.ThrowsAsync<UninstallException>(() =>
            resolver.ResolveAsync(false, Empty(), null));

        Assert.Equal("aigw_uninstall_mode_conflict", conflict.ErrorCode);
        Assert.Equal("aigw_uninstall_input_missing", missing.ErrorCode);
    }

    [Fact]
    public async Task Cancellation_stops_interactive_resolution()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var resolver = new UninstallSelectionResolver(new StringReader("y\n"), new StringWriter());

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            resolver.ResolveAsync(false, Empty(), null, cancellation.Token));
    }

    private static Dictionary<string, string?> All(string value) =>
        UninstallSelectionResolver.CategoryNames.ToDictionary(name => name, _ => (string?)value);

    private static Dictionary<string, string?> Empty() =>
        UninstallSelectionResolver.CategoryNames.ToDictionary(name => name, _ => (string?)null);
}
