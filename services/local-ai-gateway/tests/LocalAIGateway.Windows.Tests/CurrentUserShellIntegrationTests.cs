using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Windows.Installation;
using Microsoft.Win32;

namespace LocalAIGateway.Windows.Tests;

public sealed class CurrentUserShellIntegrationTests : IDisposable
{
    private readonly string testRoot = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-ShellIntegration-{Guid.NewGuid():N}");

    [Fact]
    public async Task Create_and_delete_round_trip_preserves_the_unrelated_user_path()
    {
        var fixture = CreateFixture(@"C:\Existing One;%USERPROFILE%\Tools");

        await fixture.Store.CreateAsync(fixture.Target);
        var created = await fixture.Store.InspectAsync(fixture.Target);

        Assert.True(created.IsOwned);
        Assert.Equal(@"C:\Existing One;%USERPROFILE%\Tools;" + fixture.Target.InstallRoot, fixture.Path.Value);
        Assert.True(fixture.Shortcut.Present);
        Assert.True(File.Exists(fixture.Spec.ReceiptPath));

        await fixture.Store.CreateAsync(fixture.Target);
        Assert.Equal(1, fixture.Path.WriteCount);
        Assert.Equal(1, fixture.Shortcut.CreateCount);

        await fixture.Store.DeleteAsync(fixture.Target);
        var deleted = await fixture.Store.InspectAsync(fixture.Target);

        Assert.True(deleted.IsAbsent);
        Assert.Equal(@"C:\Existing One;%USERPROFILE%\Tools", fixture.Path.Value);
        Assert.False(fixture.Shortcut.Present);
        Assert.False(File.Exists(fixture.Spec.ReceiptPath));
    }

    [Fact]
    public async Task Preexisting_equivalent_path_without_receipt_is_a_non_mutating_conflict()
    {
        var fixture = CreateFixture(string.Empty);
        fixture.Path.Value = fixture.Target.InstallRoot + Path.DirectorySeparatorChar;

        var state = await fixture.Store.InspectAsync(fixture.Target);
        var failure = await Assert.ThrowsAsync<InstallationException>(
            async () => await fixture.Store.CreateAsync(fixture.Target));

        Assert.True(state.HasConflict);
        Assert.Equal("aigw_shell_integration_conflict", failure.ErrorCode);
        Assert.Equal(0, fixture.Path.WriteCount);
        Assert.Equal(0, fixture.Shortcut.CreateCount);
        Assert.False(File.Exists(fixture.Spec.ReceiptPath));
    }

    [Fact]
    public async Task Preexisting_shortcut_without_receipt_is_preserved_as_a_conflict()
    {
        var fixture = CreateFixture(string.Empty);
        fixture.Shortcut.Present = true;
        fixture.Shortcut.SemanticallyOwned = true;

        var failure = await Assert.ThrowsAsync<InstallationException>(
            async () => await fixture.Store.DeleteAsync(fixture.Target));

        Assert.Equal("aigw_shell_integration_conflict", failure.ErrorCode);
        Assert.True(fixture.Shortcut.Present);
        Assert.Equal(0, fixture.Shortcut.DeleteCount);
    }

    [Fact]
    public async Task Existing_receipt_repairs_missing_components_idempotently()
    {
        var fixture = CreateFixture(@"C:\Existing");
        await fixture.Store.CreateAsync(fixture.Target);
        fixture.Path.Value = @"C:\Existing";
        fixture.Shortcut.Present = false;

        var incomplete = await fixture.Store.InspectAsync(fixture.Target);
        await fixture.Store.CreateAsync(fixture.Target);
        var repaired = await fixture.Store.InspectAsync(fixture.Target);

        Assert.False(incomplete.IsOwned);
        Assert.False(incomplete.HasConflict);
        Assert.True(repaired.IsOwned);
        Assert.Equal(2, fixture.Path.WriteCount);
        Assert.Equal(2, fixture.Shortcut.CreateCount);
    }

    [Fact]
    public async Task Shortcut_failure_rolls_back_path_receipt_and_empty_state_root()
    {
        var fixture = CreateFixture(@"C:\Existing");
        fixture.Shortcut.CreateFailure = new IOException("Injected shortcut failure.");

        await Assert.ThrowsAsync<IOException>(
            async () => await fixture.Store.CreateAsync(fixture.Target));

        Assert.Equal(@"C:\Existing", fixture.Path.Value);
        Assert.False(fixture.Shortcut.Present);
        Assert.False(File.Exists(fixture.Spec.ReceiptPath));
        Assert.False(Directory.Exists(fixture.Target.StateRoot));
    }

    [Fact]
    public async Task Modified_owned_path_is_a_conflict_and_delete_preserves_everything()
    {
        var fixture = CreateFixture(@"C:\Existing");
        await fixture.Store.CreateAsync(fixture.Target);
        fixture.Path.Value = @"C:\Existing;" + fixture.Target.InstallRoot + Path.DirectorySeparatorChar;

        var failure = await Assert.ThrowsAsync<InstallationException>(
            async () => await fixture.Store.DeleteAsync(fixture.Target));

        Assert.Equal("aigw_shell_integration_conflict", failure.ErrorCode);
        Assert.True(fixture.Shortcut.Present);
        Assert.True(File.Exists(fixture.Spec.ReceiptPath));
        Assert.EndsWith(Path.DirectorySeparatorChar.ToString(), fixture.Path.Value, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Missing_user_path_value_is_deleted_again_after_round_trip()
    {
        var fixture = CreateFixture(string.Empty, pathExists: false);

        await fixture.Store.CreateAsync(fixture.Target);
        await fixture.Store.DeleteAsync(fixture.Target);

        Assert.False(fixture.Path.Exists);
        Assert.Equal(1, fixture.Path.DeleteCount);
    }

    [Fact]
    public async Task Existing_trailing_path_separator_is_preserved_byte_for_byte()
    {
        const string original = @"C:\Existing;;";
        var fixture = CreateFixture(original);

        await fixture.Store.CreateAsync(fixture.Target);
        await fixture.Store.DeleteAsync(fixture.Target);

        Assert.Equal(original, fixture.Path.Value);
        Assert.Equal(RegistryValueKind.ExpandString, fixture.Path.Kind);
    }

    [Fact]
    public async Task Unrelated_path_entry_appended_after_install_is_preserved()
    {
        const string original = @"C:\Existing";
        var fixture = CreateFixture(original);
        await fixture.Store.CreateAsync(fixture.Target);
        fixture.Path.Value += @";C:\Added Later";

        await fixture.Store.DeleteAsync(fixture.Target);

        Assert.Equal(original + @";C:\Added Later", fixture.Path.Value);
    }

    [Fact]
    public async Task Preexisting_empty_product_directories_are_preserved_after_round_trip()
    {
        var fixture = CreateFixture(@"C:\Existing");
        Directory.CreateDirectory(fixture.Target.StateRoot);
        Directory.CreateDirectory(fixture.Spec.ReceiptDirectory);
        Directory.CreateDirectory(fixture.Spec.ShortcutDirectory);

        await fixture.Store.CreateAsync(fixture.Target);
        await fixture.Store.DeleteAsync(fixture.Target);

        Assert.True(Directory.Exists(fixture.Target.StateRoot));
        Assert.True(Directory.Exists(fixture.Spec.ReceiptDirectory));
        Assert.True(Directory.Exists(fixture.Spec.ShortcutDirectory));
    }

    [Fact]
    public void Windows_shortcut_store_creates_reads_and_removes_the_exact_tray_link()
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(testRoot, "Shortcut Local AppData"));
        Directory.CreateDirectory(target.TrayDirectory);
        File.WriteAllText(target.TrayExecutablePath, "fixture");
        var spec = CurrentUserShellIntegrationSpec.Create(
            target,
            Path.Combine(testRoot, "Shortcut Roaming AppData"));
        var store = new WindowsScriptShortcutStore();

        store.Create(spec);

        Assert.True(store.Exists(spec.ShortcutPath));
        Assert.True(store.Matches(spec.ShortcutPath, spec));

        store.Delete(spec.ShortcutPath, deleteEmptyDirectory: true);

        Assert.False(store.Exists(spec.ShortcutPath));
        Assert.False(Directory.Exists(spec.ShortcutDirectory));
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot))
        {
            Directory.Delete(testRoot, recursive: true);
        }
    }

    private Fixture CreateFixture(string path, bool pathExists = true)
    {
        var target = CurrentUserInstallationPlan.CreateTarget(Path.Combine(testRoot, "Local AppData"));
        var spec = CurrentUserShellIntegrationSpec.Create(target, Path.Combine(testRoot, "Roaming AppData"));
        var pathStore = new MemoryUserPathStore(pathExists, path);
        var shortcutStore = new MemoryShortcutStore();
        var store = new WindowsCurrentUserShellIntegrationStore(
            pathStore,
            shortcutStore,
            NoOpConfigurationFileSecurity.Instance,
            _ => spec);
        return new Fixture(target, spec, pathStore, shortcutStore, store);
    }

    private sealed record Fixture(
        CurrentUserInstallationTarget Target,
        CurrentUserShellIntegrationSpec Spec,
        MemoryUserPathStore Path,
        MemoryShortcutStore Shortcut,
        WindowsCurrentUserShellIntegrationStore Store);

    private sealed class MemoryUserPathStore(bool exists, string value) : IUserPathStore
    {
        public bool Exists { get; private set; } = exists;

        public string Value { get; set; } = value;

        public RegistryValueKind Kind { get; private set; } = RegistryValueKind.ExpandString;

        public int WriteCount { get; private set; }

        public int DeleteCount { get; private set; }

        public UserPathValue Read() => new(Exists, Value, Kind);

        public void Write(string value, RegistryValueKind kind)
        {
            Exists = true;
            Value = value;
            Kind = kind;
            WriteCount++;
        }

        public void Delete()
        {
            Exists = false;
            Value = string.Empty;
            DeleteCount++;
        }

        public void NotifyChanged()
        {
        }
    }

    private sealed class MemoryShortcutStore : IWindowsShortcutStore
    {
        public bool Present { get; set; }

        public bool SemanticallyOwned { get; set; } = true;

        public Exception? CreateFailure { get; set; }

        public int CreateCount { get; private set; }

        public int DeleteCount { get; private set; }

        public bool Exists(string path) => Present;

        public bool Matches(string path, CurrentUserShellIntegrationSpec spec) =>
            Present && SemanticallyOwned;

        public void Create(CurrentUserShellIntegrationSpec spec)
        {
            CreateCount++;
            if (CreateFailure is not null)
            {
                throw CreateFailure;
            }
            Present = true;
            SemanticallyOwned = true;
        }

        public void Delete(string path, bool deleteEmptyDirectory)
        {
            DeleteCount++;
            Present = false;
        }
    }
}
