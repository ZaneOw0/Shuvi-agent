using LocalAIGateway.Core.Configuration;

namespace LocalAIGateway.Core.Tests;

[Collection("ProcessEnvironment")]
public sealed class ConfigurationPathsTests
{
    [Fact]
    public void ForCurrentUserHonorsAbsoluteLocalAppDataEnvironmentVariable()
    {
        var original = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        var expectedRoot = Path.Combine(Path.GetTempPath(), $"aigw-paths-{Guid.NewGuid():N}");
        try
        {
            Environment.SetEnvironmentVariable("LOCALAPPDATA", expectedRoot);

            var paths = ConfigurationPaths.ForCurrentUser();

            Assert.Equal(Path.Combine(expectedRoot, "LocalAIGateway"), paths.RootDirectory);
            Assert.Equal(Path.Combine(expectedRoot, "LocalAIGateway", "logs"), paths.LogsDirectory);
        }
        finally
        {
            Environment.SetEnvironmentVariable("LOCALAPPDATA", original);
        }
    }

    [Fact]
    public void ForCurrentUserRejectsRelativeLocalAppDataEnvironmentVariable()
    {
        var original = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        try
        {
            Environment.SetEnvironmentVariable("LOCALAPPDATA", "relative-path");

            var exception = Assert.Throws<ConfigurationException>(ConfigurationPaths.ForCurrentUser);

            Assert.Equal("aigw_config_path_invalid", exception.ErrorCode);
        }
        finally
        {
            Environment.SetEnvironmentVariable("LOCALAPPDATA", original);
        }
    }
}

[CollectionDefinition("ProcessEnvironment", DisableParallelization = true)]
public sealed class ProcessEnvironmentCollection;
