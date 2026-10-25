using LocalAIGateway.Core.Installation;
using LocalAIGateway.Windows.Uninstall;

namespace LocalAIGateway.Windows.Tests;

public sealed class OwnedStateDataCleanerTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"LocalAIGateway-UninstallState-{Guid.NewGuid():N}");

    [Fact]
    public void Selected_categories_are_removed_without_touching_unselected_state()
    {
        var state = Path.Combine(root, "state");
        Directory.CreateDirectory(Path.Combine(state, "usage", "nested"));
        Directory.CreateDirectory(Path.Combine(state, "logs"));
        Directory.CreateDirectory(Path.Combine(state, "runtime"));
        File.WriteAllText(Path.Combine(state, "config.json"), "{}");
        File.WriteAllText(Path.Combine(state, $"config.{Guid.NewGuid():N}.tmp"), "temporary");
        File.WriteAllText(Path.Combine(state, "usage", "usage.db"), "fixture");
        File.WriteAllText(Path.Combine(state, "usage", "nested", "segment"), "fixture");
        File.WriteAllText(Path.Combine(state, "logs", "gateway.log"), "fixture");
        File.WriteAllText(Path.Combine(state, "runtime", "owned-by-runtime"), "fixture");

        var result = new OwnedStateDataCleaner().Clean(new(
            state,
            RemoveConfiguration: true,
            RemoveUsage: true,
            RemoveLogs: false));

        Assert.True(result.Configuration.Removed);
        Assert.True(result.Usage.Removed);
        Assert.False(result.Logs.Selected);
        Assert.False(result.StateRootRemoved);
        Assert.False(File.Exists(Path.Combine(state, "config.json")));
        Assert.False(Directory.Exists(Path.Combine(state, "usage")));
        Assert.True(File.Exists(Path.Combine(state, "logs", "gateway.log")));
        Assert.True(File.Exists(Path.Combine(state, "runtime", "owned-by-runtime")));
    }

    [Fact]
    public void All_selected_absent_categories_are_idempotent()
    {
        var state = Path.Combine(root, "missing-state");

        var result = new OwnedStateDataCleaner().Clean(new(state, true, true, true));

        Assert.True(result.Configuration.AlreadyAbsent);
        Assert.True(result.Usage.AlreadyAbsent);
        Assert.True(result.Logs.AlreadyAbsent);
        Assert.False(result.StateRootRemoved);
    }

    [Fact]
    public void Empty_state_root_is_removed_after_selected_data_cleanup()
    {
        var state = Path.Combine(root, "state");
        Directory.CreateDirectory(Path.Combine(state, "logs"));
        File.WriteAllText(Path.Combine(state, "logs", "gateway.log"), "fixture");

        var result = new OwnedStateDataCleaner().Clean(new(state, true, true, true));

        Assert.True(result.Logs.Removed);
        Assert.True(result.StateRootRemoved);
        Assert.False(Directory.Exists(state));
    }

    [Fact]
    public void Unsafe_category_path_is_rejected_before_any_selected_file_is_deleted()
    {
        var state = Path.Combine(root, "state");
        Directory.CreateDirectory(state);
        File.WriteAllText(Path.Combine(state, "config.json"), "{}");
        File.WriteAllText(Path.Combine(state, "usage"), "not-a-directory");

        var failure = Assert.Throws<InstallationException>(() =>
            new OwnedStateDataCleaner().Clean(new(state, true, true, false)));

        Assert.Equal("aigw_uninstall_state_path_unsafe", failure.ErrorCode);
        Assert.True(File.Exists(Path.Combine(state, "config.json")));
        Assert.True(File.Exists(Path.Combine(state, "usage")));
    }

    [Fact]
    public void Unrecognized_config_like_files_are_preserved()
    {
        var state = Path.Combine(root, "state");
        Directory.CreateDirectory(state);
        File.WriteAllText(Path.Combine(state, "config.user-notes"), "preserve");
        File.WriteAllText(Path.Combine(state, "config.json"), "{}");

        var result = new OwnedStateDataCleaner().Clean(new(state, true, false, false));

        Assert.True(result.Configuration.Removed);
        Assert.True(File.Exists(Path.Combine(state, "config.user-notes")));
        Assert.False(result.StateRootRemoved);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
