using LocalAIGateway.Core.Update;

namespace LocalAIGateway.Core.Tests;

public sealed class PackageVersionComparerTests
{
    [Theory]
    [InlineData("0.1.1-dev", "0.1.0-dev")]
    [InlineData("1.0.0", "1.0.0-rc.1")]
    [InlineData("1.0.0-rc.2", "1.0.0-rc.1")]
    [InlineData("1.0.0-beta", "1.0.0-12")]
    [InlineData("100000000000000000000.0.0", "9.0.0")]
    public void Newer_versions_compare_greater(string candidate, string current) =>
        Assert.True(PackageVersionComparer.Compare(candidate, current) > 0);

    [Theory]
    [InlineData("1.0")]
    [InlineData("01.0.0")]
    [InlineData("1.0.0-")]
    [InlineData("1.0.0-rc..1")]
    [InlineData("1.0.0-01")]
    public void Invalid_versions_fail_closed(string version)
    {
        var exception = Assert.Throws<UpdateException>(() => PackageVersionComparer.Compare(version, "1.0.0"));
        Assert.Equal("aigw_update_version_invalid", exception.ErrorCode);
    }
}
