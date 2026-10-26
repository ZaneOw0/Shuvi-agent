using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LocalAIGateway.Launcher;

public sealed class ClientIntegrationPreviewer : IClientIntegrationPreviewer
{
    public const int MaximumSourceCharacters = 1_048_576;

    internal const string ClaudeBegin = "// BEGIN Local AI Gateway managed: claude-vscode v1";
    internal const string ClaudeEnd = "// END Local AI Gateway managed: claude-vscode v1";
    internal const string ClaudeProperty = "claudeCode.claudeProcessWrapper";
    internal const string CodexBegin = "# BEGIN Local AI Gateway managed: codex-cli v1";
    internal const string CodexEnd = "# END Local AI Gateway managed: codex-cli v1";

    public ClientIntegrationPreviewResult Preview(ClientIntegrationPreviewRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request = request with { TargetPath = ValidateCommon(request) };
        return request.Client switch
        {
            ClientIntegrationKind.ClaudeVsCode => PreviewClaudeVsCode(request),
            ClientIntegrationKind.CodexCli => PreviewCodex(request),
            _ => throw Invalid("The requested client integration is unknown."),
        };
    }

    internal static ClientIntegrationStatusResult PlanUnintegration(
        ClientIntegrationKind client,
        string targetPath,
        string existingContent)
    {
        if (existingContent.Length > MaximumSourceCharacters)
        {
            throw SourceInvalid("The integration target exceeds the supported text size limit.");
        }

        ValidateTargetFileName(client, targetPath);
        return client switch
        {
            ClientIntegrationKind.ClaudeVsCode => PlanClaudeUnintegration(targetPath, existingContent),
            ClientIntegrationKind.CodexCli => PlanCodexUnintegration(targetPath, existingContent),
            _ => throw Invalid("The requested client integration is unknown."),
        };
    }

    private static ClientIntegrationPreviewResult PreviewClaudeVsCode(
        ClientIntegrationPreviewRequest request)
    {
        ValidateTargetFileName(request.Client, request.TargetPath);
        ValidateClaudeVersions(request.ClientVersion, request.HostVersion);
        var wrapperPath = ValidateWrapper(request.WrapperExecutablePath);
        request = request with { WrapperExecutablePath = wrapperPath };
        var lineEnding = DetectLineEnding(request.ExistingContent);
        var wrapperJson = JsonSerializer.Serialize(wrapperPath);
        var block = string.Join(
            lineEnding,
            ClaudeBegin,
            $"\"{ClaudeProperty}\": {wrapperJson}",
            ClaudeEnd);
        var proposed = PatchJsonc(request.ExistingContent, block);
        ValidateJsonc(proposed, expectedPropertyCount: 1);
        return Result(request, proposed, block);
    }

    private static ClientIntegrationPreviewResult PreviewCodex(
        ClientIntegrationPreviewRequest request)
    {
        ValidateTargetFileName(request.Client, request.TargetPath);
        ValidateCodexVersion(request.ClientVersion);
        var lineEnding = DetectLineEnding(request.ExistingContent);
        var block = string.Join(
            lineEnding,
            CodexBegin,
            "model = \"aigw/codex/default\"",
            "model_provider = \"aigw\"",
            string.Empty,
            "[model_providers.aigw]",
            "name = \"Local AI Gateway\"",
            "base_url = \"http://127.0.0.1:4000/v1\"",
            "env_key = \"AIGW_CODEX_API_KEY\"",
            "wire_api = \"responses\"",
            CodexEnd);
        var proposed = PatchOwnedTomlProfile(request.ExistingContent, block, lineEnding);
        return Result(request, proposed, block);
    }

    private static ClientIntegrationPreviewResult Result(
        ClientIntegrationPreviewRequest request,
        string proposed,
        string block)
    {
        var existing = request.ExistingContent;
        var action = existing is null
            ? ClientIntegrationAction.Create
            : string.Equals(existing, proposed, StringComparison.Ordinal)
                ? ClientIntegrationAction.Unchanged
                : ClientIntegrationAction.Update;
        var marker = action switch
        {
            ClientIntegrationAction.Create => "+ add owned block",
            ClientIntegrationAction.Update => "~ replace owned block",
            _ => "= owned block unchanged",
        };
        var safeBlock = string.Join(
            "\n",
            block.Replace("\r\n", "\n", StringComparison.Ordinal)
                .Split('\n')
                .Select(line => "+ " + line));
        var diff = string.Join(
            "\n",
            $"--- {request.TargetPath}",
            $"+++ {request.TargetPath}",
            "@@ Local AI Gateway managed integration @@",
            marker,
            safeBlock);
        return new ClientIntegrationPreviewResult(
            request.Client,
            request.TargetPath,
            action,
            existing is null ? null : Sha256(existing),
            Sha256(proposed),
            diff,
            proposed);
    }

    private static ClientIntegrationStatusResult PlanClaudeUnintegration(
        string targetPath,
        string existing)
    {
        ValidateJsonc(existing, expectedPropertyCount: null);
        var beginCount = Count(existing, ClaudeBegin);
        var endCount = Count(existing, ClaudeEnd);
        var propertyCount = CountRootJsonProperty(existing, ClaudeProperty);
        if (beginCount == 0 && endCount == 0 && propertyCount == 0)
        {
            return NotIntegrated(ClientIntegrationKind.ClaudeVsCode, targetPath, existing);
        }
        if (beginCount != 1 || endCount != 1 || propertyCount != 1)
        {
            throw Ownership("Claude VS Code ownership markers or the managed property are missing, duplicated, or mismatched.");
        }

        var begin = existing.IndexOf(ClaudeBegin, StringComparison.Ordinal);
        var end = existing.IndexOf(ClaudeEnd, begin + ClaudeBegin.Length, StringComparison.Ordinal);
        if (end < begin)
        {
            throw Ownership("The Claude ownership markers are out of order.");
        }
        var lineStart = existing.LastIndexOf('\n', Math.Max(0, begin - 1));
        lineStart = lineStart < 0 ? 0 : lineStart + 1;
        var lineEnd = existing.IndexOf('\n', end + ClaudeEnd.Length);
        lineEnd = lineEnd < 0 ? existing.Length : lineEnd + 1;
        var oldBlock = existing[lineStart..lineEnd];
        if (!IsOwnedClaudeBlock(oldBlock))
        {
            throw Ownership("The Claude owned block contains unrecognized or user-managed content.");
        }

        var prefix = existing[..lineStart];
        var scanEnd = prefix.Length;
        while (scanEnd > 0 && prefix[scanEnd - 1] is '\r' or '\n')
        {
            scanEnd--;
        }
        var precedingLineStart = scanEnd == 0
            ? 0
            : prefix.LastIndexOf('\n', Math.Max(0, scanEnd - 1)) + 1;
        if (prefix[precedingLineStart..scanEnd].Trim().Equals(",", StringComparison.Ordinal))
        {
            prefix = prefix[..precedingLineStart];
        }

        var proposed = prefix + existing[lineEnd..];
        ValidateJsonc(proposed, expectedPropertyCount: 0);
        return Owned(
            ClientIntegrationKind.ClaudeVsCode,
            targetPath,
            existing,
            proposed,
            ClientIntegrationRemovalAction.Update);
    }

    private static ClientIntegrationStatusResult PlanCodexUnintegration(
        string targetPath,
        string existing)
    {
        var beginCount = Count(existing, CodexBegin);
        var endCount = Count(existing, CodexEnd);
        if (beginCount == 0 && endCount == 0)
        {
            return NotIntegrated(ClientIntegrationKind.CodexCli, targetPath, existing);
        }
        if (beginCount != 1 || endCount != 1)
        {
            throw Ownership("The Codex ownership markers are missing, duplicated, or mismatched.");
        }

        var begin = existing.IndexOf(CodexBegin, StringComparison.Ordinal);
        var end = existing.IndexOf(CodexEnd, begin + CodexBegin.Length, StringComparison.Ordinal);
        if (end < begin)
        {
            throw Ownership("The Codex ownership markers are out of order.");
        }
        var lineStart = existing.LastIndexOf('\n', Math.Max(0, begin - 1));
        lineStart = lineStart < 0 ? 0 : lineStart + 1;
        var lineEnd = existing.IndexOf('\n', end + CodexEnd.Length);
        lineEnd = lineEnd < 0 ? existing.Length : lineEnd + 1;
        var oldBlock = existing[lineStart..lineEnd];
        if (!IsOwnedCodexBlock(oldBlock))
        {
            throw Ownership("The Codex owned block contains unrecognized or user-managed content.");
        }
        var proposed = existing[..lineStart] + existing[lineEnd..];
        if (proposed.Split(['\r', '\n']).Select(line => line.Trim()).Any(trimmed =>
                trimmed.Length != 0 && !trimmed.StartsWith('#')))
        {
            throw Ownership("The dedicated Codex profile contains user-managed TOML outside the owned block.");
        }

        return string.IsNullOrWhiteSpace(proposed)
            ? Owned(
                ClientIntegrationKind.CodexCli,
                targetPath,
                existing,
                proposed: null,
                ClientIntegrationRemovalAction.Delete)
            : Owned(
                ClientIntegrationKind.CodexCli,
                targetPath,
                existing,
                proposed,
                ClientIntegrationRemovalAction.Update);
    }

    private static ClientIntegrationStatusResult NotIntegrated(
        ClientIntegrationKind client,
        string targetPath,
        string existing) => new(
            client,
            targetPath,
            ClientIntegrationStatusKind.NotIntegrated,
            ClientIntegrationRemovalAction.None,
            Sha256(existing),
            null,
            null,
            null);

    private static ClientIntegrationStatusResult Owned(
        ClientIntegrationKind client,
        string targetPath,
        string existing,
        string? proposed,
        ClientIntegrationRemovalAction action) => new(
            client,
            targetPath,
            ClientIntegrationStatusKind.Owned,
            action,
            Sha256(existing),
            proposed is null ? null : Sha256(proposed),
            string.Join(
                "\n",
                $"--- {targetPath}",
                action == ClientIntegrationRemovalAction.Delete ? "+++ /dev/null" : $"+++ {targetPath}",
                "@@ Local AI Gateway managed integration @@",
                "- remove owned block"),
            proposed);

    internal static void ValidateTargetFileName(ClientIntegrationKind client, string targetPath)
    {
        var expected = client switch
        {
            ClientIntegrationKind.ClaudeVsCode => "settings.json",
            ClientIntegrationKind.CodexCli => "aigw.config.toml",
            _ => throw Invalid("The requested client integration is unknown."),
        };
        if (!Path.GetFileName(targetPath).Equals(expected, StringComparison.OrdinalIgnoreCase))
        {
            throw Invalid(client == ClientIntegrationKind.ClaudeVsCode
                ? "Claude VS Code integration must target a settings.json file."
                : "Codex integration must target the dedicated aigw.config.toml profile file.");
        }
    }

    private static string PatchJsonc(string? existing, string unindentedBlock)
    {
        var lineEnding = DetectLineEnding(existing);
        if (string.IsNullOrWhiteSpace(existing))
        {
            return "{" + lineEnding + Indent(unindentedBlock, "  ", lineEnding) + lineEnding + "}" + lineEnding;
        }

        ValidateJsonc(existing, expectedPropertyCount: null);
        var beginCount = Count(existing, ClaudeBegin);
        var endCount = Count(existing, ClaudeEnd);
        if (beginCount != endCount || beginCount > 1)
        {
            throw Ownership("Claude VS Code ownership markers are missing, duplicated, or mismatched.");
        }

        var propertyCount = CountRootJsonProperty(existing, ClaudeProperty);
        if (beginCount == 0)
        {
            if (propertyCount != 0)
            {
                throw Ownership("The Claude process-wrapper setting already exists outside an owned block.");
            }

            var closingBrace = FindRootClosingBrace(existing);
            var block = Indent(unindentedBlock, "  ", lineEnding);
            var prefixes = CountRootJsonProperties(existing) == 0 ? new[] { string.Empty } : new[] { ",", string.Empty };
            foreach (var prefix in prefixes)
            {
                var insertion = lineEnding + prefix + (prefix.Length == 0 ? string.Empty : lineEnding) + block + lineEnding;
                var candidate = existing.Insert(closingBrace, insertion);
                if (IsValidJsonc(candidate, expectedPropertyCount: 1))
                {
                    return candidate;
                }
            }

            throw SourceInvalid("The JSONC root could not accept an owned process-wrapper property.");
        }

        if (propertyCount != 1)
        {
            throw Ownership("The owned Claude process-wrapper property is missing or duplicated.");
        }

        var begin = existing.IndexOf(ClaudeBegin, StringComparison.Ordinal);
        var end = existing.IndexOf(ClaudeEnd, begin + ClaudeBegin.Length, StringComparison.Ordinal);
        var lineStart = existing.LastIndexOf('\n', Math.Max(0, begin - 1));
        lineStart = lineStart < 0 ? 0 : lineStart + 1;
        var lineEnd = existing.IndexOf('\n', end + ClaudeEnd.Length);
        lineEnd = lineEnd < 0 ? existing.Length : lineEnd + 1;
        var indentation = existing[lineStart..begin];
        if (indentation.Any(character => !char.IsWhiteSpace(character)))
        {
            throw Ownership("The Claude ownership marker is not line-aligned.");
        }

        var oldBlock = existing[lineStart..lineEnd];
        if (!IsOwnedClaudeBlock(oldBlock))
        {
            throw Ownership("The Claude owned block contains unrecognized or user-managed content.");
        }
        var hasComma = oldBlock.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Any(line => line.Contains($"\"{ClaudeProperty}\"", StringComparison.Ordinal) && line.TrimEnd().EndsWith(','));
        var replacement = Indent(unindentedBlock, indentation, lineEnding);
        if (hasComma)
        {
            var propertyStart = replacement.IndexOf($"\"{ClaudeProperty}\":", StringComparison.Ordinal);
            var propertyLineEnd = replacement.IndexOf(lineEnding, propertyStart, StringComparison.Ordinal);
            if (propertyStart < 0 || propertyLineEnd < 0)
            {
                throw SourceInvalid("The generated Claude owned block is invalid.");
            }
            replacement = replacement.Insert(propertyLineEnd, ",");
        }
        if (lineEnd <= existing.Length && lineEnd > 0 && existing[lineEnd - 1] == '\n')
        {
            replacement += lineEnding;
        }

        var patched = existing[..lineStart] + replacement + existing[lineEnd..];
        if (!IsValidJsonc(patched, expectedPropertyCount: 1))
        {
            throw Ownership("Replacing the Claude owned block would make settings.json invalid.");
        }

        return patched;
    }

    private static string PatchOwnedTomlProfile(
        string? existing,
        string block,
        string lineEnding)
    {
        if (string.IsNullOrWhiteSpace(existing))
        {
            return block + lineEnding;
        }

        var beginCount = Count(existing, CodexBegin);
        var endCount = Count(existing, CodexEnd);
        if (beginCount != 1 || endCount != 1)
        {
            throw Ownership("The Codex profile is not an unambiguously owned Local AI Gateway file.");
        }

        var begin = existing.IndexOf(CodexBegin, StringComparison.Ordinal);
        var end = existing.IndexOf(CodexEnd, begin + CodexBegin.Length, StringComparison.Ordinal);
        if (end < begin)
        {
            throw Ownership("The Codex ownership markers are out of order.");
        }

        var lineStart = existing.LastIndexOf('\n', Math.Max(0, begin - 1));
        lineStart = lineStart < 0 ? 0 : lineStart + 1;
        var lineEnd = existing.IndexOf('\n', end + CodexEnd.Length);
        lineEnd = lineEnd < 0 ? existing.Length : lineEnd + 1;
        var oldBlock = existing[lineStart..lineEnd];
        if (!IsOwnedCodexBlock(oldBlock))
        {
            throw Ownership("The Codex owned block contains unrecognized or user-managed content.");
        }
        var outside = existing[..lineStart] + existing[lineEnd..];
        if (outside.Split(['\r', '\n']).Select(line => line.Trim()).Any(trimmed =>
                trimmed.Length != 0 && !trimmed.StartsWith('#')))
        {
            throw Ownership("The dedicated Codex profile contains user-managed TOML outside the owned block.");
        }

        var replacement = block;
        if (lineEnd > 0 && lineEnd <= existing.Length && existing[lineEnd - 1] == '\n')
        {
            replacement += lineEnding;
        }
        return existing[..lineStart] + replacement + existing[lineEnd..];
    }

    private static bool IsOwnedClaudeBlock(string block)
    {
        var lines = SignificantLines(block);
        if (lines.Length != 3 ||
            lines[0] != ClaudeBegin ||
            lines[2] != ClaudeEnd)
        {
            return false;
        }

        var property = lines[1].EndsWith(",", StringComparison.Ordinal)
            ? lines[1][..^1]
            : lines[1];
        try
        {
            using var document = JsonDocument.Parse("{" + property + "}");
            var properties = document.RootElement.EnumerateObject().ToArray();
            return properties.Length == 1 && properties[0].NameEquals(ClaudeProperty);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool IsOwnedCodexBlock(string block)
    {
        var lines = SignificantLines(block);
        if (lines.Length != 9 ||
            lines[0] != CodexBegin ||
            lines[3] != "[model_providers.aigw]" ||
            lines[8] != CodexEnd)
        {
            return false;
        }

        return IsStringAssignment(lines[1], "model") &&
            IsStringAssignment(lines[2], "model_provider") &&
            IsStringAssignment(lines[4], "name") &&
            IsStringAssignment(lines[5], "base_url") &&
            IsStringAssignment(lines[6], "env_key") &&
            IsStringAssignment(lines[7], "wire_api");
    }

    private static bool IsStringAssignment(string line, string key)
    {
        var prefix = key + " = ";
        if (!line.StartsWith(prefix, StringComparison.Ordinal))
        {
            return false;
        }

        try
        {
            using var value = JsonDocument.Parse(line[prefix.Length..]);
            return value.RootElement.ValueKind == JsonValueKind.String;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string[] SignificantLines(string content) => content
        .Replace("\r\n", "\n", StringComparison.Ordinal)
        .Split('\n')
        .Select(line => line.Trim())
        .Where(line => line.Length != 0)
        .ToArray();

    private static string ValidateCommon(ClientIntegrationPreviewRequest request)
    {
        string targetPath;
        try
        {
            if (string.IsNullOrWhiteSpace(request.TargetPath) ||
                !Path.IsPathFullyQualified(request.TargetPath) ||
                request.TargetPath.Any(char.IsControl))
            {
                throw Invalid("The integration target must be a fully qualified path.");
            }
            targetPath = Path.GetFullPath(request.TargetPath);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            throw Invalid("The integration target must be a valid fully qualified path.");
        }
        if (request.ExistingContent?.Length > MaximumSourceCharacters)
        {
            throw SourceInvalid("The integration source exceeds the preview size limit.");
        }
        return targetPath;
    }

    private static string ValidateWrapper(string? wrapperPath)
    {
        if (string.IsNullOrWhiteSpace(wrapperPath) || !Path.IsPathFullyQualified(wrapperPath))
        {
            throw Invalid("The Claude process wrapper must be an existing fully qualified file.");
        }

        try
        {
            wrapperPath = Path.GetFullPath(wrapperPath);
            if (!File.Exists(wrapperPath))
            {
                throw Invalid("The Claude process wrapper must be an existing fully qualified file.");
            }
            if ((File.GetAttributes(wrapperPath) & FileAttributes.ReparsePoint) != 0)
            {
                throw Invalid("The Claude process wrapper must not be a reparse point.");
            }
            return wrapperPath;
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw Invalid("The Claude process wrapper could not be safely inspected.");
        }
    }

    private static void ValidateClaudeVersions(string clientVersionText, string? hostVersionText)
    {
        var clientVersion = ParseVersion(clientVersionText, "Claude Code");
        var hostVersion = ParseVersion(hostVersionText, "VS Code");
        if (clientVersion.Major != 2)
        {
            throw Unsupported("Only the reviewed Claude Code 2.x wrapper contract is supported.");
        }
        if (hostVersion.Major != 1 || hostVersion < new Version(1, 94, 0))
        {
            throw Unsupported("Claude VS Code integration requires the reviewed VS Code 1.94+ host contract.");
        }
    }

    private static void ValidateCodexVersion(string versionText)
    {
        var version = ParseVersion(versionText, "Codex");
        if (version.Major != 0 || version < new Version(0, 134, 0))
        {
            throw Unsupported("Only the reviewed Codex 0.134+ independent profile-file contract is supported.");
        }
    }

    private static Version ParseVersion(string? text, string label)
    {
        if (string.IsNullOrWhiteSpace(text) ||
            text.Split('.').Length != 3 ||
            !Version.TryParse(text, out var version))
        {
            throw Invalid($"{label} version must use numeric major.minor.patch form.");
        }
        return version;
    }

    private static void ValidateJsonc(string content, int? expectedPropertyCount)
    {
        if (!IsValidJsonc(content, expectedPropertyCount))
        {
            throw SourceInvalid("The VS Code settings fixture is not a valid JSONC object.");
        }
    }

    private static bool IsValidJsonc(string content, int? expectedPropertyCount)
    {
        try
        {
            using var document = JsonDocument.Parse(content, new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip,
                MaxDepth = 64,
            });
            return document.RootElement.ValueKind == JsonValueKind.Object &&
                (expectedPropertyCount is null ||
                    document.RootElement.EnumerateObject().Count(property =>
                        property.NameEquals(ClaudeProperty)) == expectedPropertyCount);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static int CountRootJsonProperty(string content, string propertyName)
    {
        using var document = JsonDocument.Parse(content, new JsonDocumentOptions
        {
            AllowTrailingCommas = true,
            CommentHandling = JsonCommentHandling.Skip,
            MaxDepth = 64,
        });
        return document.RootElement.EnumerateObject().Count(property => property.NameEquals(propertyName));
    }

    private static int CountRootJsonProperties(string content)
    {
        using var document = JsonDocument.Parse(content, new JsonDocumentOptions
        {
            AllowTrailingCommas = true,
            CommentHandling = JsonCommentHandling.Skip,
            MaxDepth = 64,
        });
        return document.RootElement.EnumerateObject().Count();
    }

    private static int FindRootClosingBrace(string content)
    {
        var depth = 0;
        var inString = false;
        var escaped = false;
        var lineComment = false;
        var blockComment = false;
        for (var index = 0; index < content.Length; index++)
        {
            var current = content[index];
            var next = index + 1 < content.Length ? content[index + 1] : '\0';
            if (lineComment)
            {
                if (current is '\r' or '\n') lineComment = false;
                continue;
            }
            if (blockComment)
            {
                if (current == '*' && next == '/')
                {
                    blockComment = false;
                    index++;
                }
                continue;
            }
            if (inString)
            {
                if (escaped) escaped = false;
                else if (current == '\\') escaped = true;
                else if (current == '"') inString = false;
                continue;
            }
            if (current == '/' && next == '/')
            {
                lineComment = true;
                index++;
                continue;
            }
            if (current == '/' && next == '*')
            {
                blockComment = true;
                index++;
                continue;
            }
            if (current == '"') inString = true;
            else if (current == '{') depth++;
            else if (current == '}' && --depth == 0) return index;
        }
        throw SourceInvalid("The JSONC root closing brace could not be located.");
    }

    private static int Count(string value, string pattern)
    {
        var count = 0;
        var offset = 0;
        while ((offset = value.IndexOf(pattern, offset, StringComparison.Ordinal)) >= 0)
        {
            count++;
            offset += pattern.Length;
        }
        return count;
    }

    private static string Indent(string block, string indentation, string lineEnding) =>
        string.Join(
            lineEnding,
            block.Replace("\r\n", "\n", StringComparison.Ordinal)
                .Split('\n')
                .Select(line => indentation + line));

    private static string DetectLineEnding(string? content) =>
        content?.Contains("\r\n", StringComparison.Ordinal) == true ? "\r\n" : "\n";

    private static string Sha256(string content) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(content))).ToLowerInvariant();

    private static ClientIntegrationException Invalid(string message) => new(
        "aigw_integration_request_invalid",
        message);

    private static ClientIntegrationException Unsupported(string message) => new(
        "aigw_integration_version_unsupported",
        message);

    private static ClientIntegrationException Ownership(string message) => new(
        "aigw_integration_ownership_conflict",
        message);

    private static ClientIntegrationException SourceInvalid(string message) => new(
        "aigw_integration_source_invalid",
        message);
}
