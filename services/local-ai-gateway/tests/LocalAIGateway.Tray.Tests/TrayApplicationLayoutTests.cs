using LocalAIGateway.Tray;

namespace LocalAIGateway.Tray.Tests;

public sealed class TrayApplicationLayoutTests
{
    [Fact]
    public void Packaged_tray_resolves_the_parent_runtime_root_only_for_the_complete_layout()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"LocalAIGateway-TrayLayout-{Guid.NewGuid():N}");
        var tray = Path.Combine(root, "tray");
        try
        {
            Directory.CreateDirectory(tray);
            Directory.CreateDirectory(Path.Combine(root, "runtime", "python"));
            Directory.CreateDirectory(Path.Combine(root, "runtime-tools"));
            File.WriteAllText(Path.Combine(root, "PACKAGE-MANIFEST.json"), "fixture");
            File.WriteAllText(Path.Combine(root, "runtime", "python", "python.exe"), "fixture");
            File.WriteAllText(Path.Combine(root, "runtime-tools", "aigw_usage_query.py"), "fixture");

            var resolved = TrayApplicationLayout.ResolvePackageRoot(tray);

            Assert.Equal(Path.GetFullPath(root), resolved);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public void Standalone_publish_keeps_its_own_application_root()
    {
        var standalone = Path.Combine(Path.GetTempPath(), "LocalAIGateway-Standalone-Tray");

        Assert.Equal(
            Path.GetFullPath(standalone),
            TrayApplicationLayout.ResolvePackageRoot(standalone));
    }
}
