namespace LocalAIGateway.Core.Update;

public static class PackageVersionComparer
{
    public static int Compare(string left, string right)
    {
        var leftVersion = Parse(left);
        var rightVersion = Parse(right);
        for (var index = 0; index < 3; index++)
        {
            var comparison = CompareNumeric(leftVersion.Core[index], rightVersion.Core[index]);
            if (comparison != 0) return comparison;
        }

        if (leftVersion.PreRelease.Length == 0 && rightVersion.PreRelease.Length == 0) return 0;
        if (leftVersion.PreRelease.Length == 0) return 1;
        if (rightVersion.PreRelease.Length == 0) return -1;
        var count = Math.Min(leftVersion.PreRelease.Length, rightVersion.PreRelease.Length);
        for (var index = 0; index < count; index++)
        {
            var leftIdentifier = leftVersion.PreRelease[index];
            var rightIdentifier = rightVersion.PreRelease[index];
            var leftNumeric = leftIdentifier.All(char.IsAsciiDigit);
            var rightNumeric = rightIdentifier.All(char.IsAsciiDigit);
            int comparison;
            if (leftNumeric && rightNumeric)
            {
                comparison = CompareNumeric(leftIdentifier, rightIdentifier);
            }
            else if (leftNumeric != rightNumeric)
            {
                comparison = leftNumeric ? -1 : 1;
            }
            else
            {
                comparison = string.CompareOrdinal(leftIdentifier, rightIdentifier);
            }
            if (comparison != 0) return comparison;
        }

        return leftVersion.PreRelease.Length.CompareTo(rightVersion.PreRelease.Length);
    }

    private static ParsedVersion Parse(string value)
    {
        if (string.IsNullOrEmpty(value)) throw Invalid();
        var dash = value.IndexOf('-');
        var coreText = dash < 0 ? value : value[..dash];
        var preReleaseText = dash < 0 ? null : value[(dash + 1)..];
        var core = coreText.Split('.');
        if (core.Length != 3 || core.Any(identifier => !IsNumericIdentifier(identifier))) throw Invalid();
        if (preReleaseText is null) return new ParsedVersion(core, []);
        var preRelease = preReleaseText.Split('.');
        if (preRelease.Length == 0 || preRelease.Any(identifier =>
                identifier.Length == 0 ||
                identifier.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '-') ||
                identifier.All(char.IsAsciiDigit) && identifier.Length > 1 && identifier[0] == '0'))
        {
            throw Invalid();
        }
        return new ParsedVersion(core, preRelease);
    }

    private static bool IsNumericIdentifier(string value) =>
        value.Length != 0 &&
        value.All(char.IsAsciiDigit) &&
        (value.Length == 1 || value[0] != '0');

    private static int CompareNumeric(string left, string right) =>
        left.Length != right.Length
            ? left.Length.CompareTo(right.Length)
            : string.CompareOrdinal(left, right);

    private static UpdateException Invalid() => new(
        "aigw_update_version_invalid",
        "Package versions used for update must be restricted semantic versions.");

    private sealed record ParsedVersion(string[] Core, string[] PreRelease);
}
