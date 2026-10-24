using System.CommandLine;
using System.Globalization;
using System.Reflection;
using System.Text.Json;
using LocalAIGateway.Core.Backup;
using LocalAIGateway.Core.Configuration;
using LocalAIGateway.Core.Credentials;
using LocalAIGateway.Core.Control;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Usage;
using LocalAIGateway.Core.Update;
using LocalAIGateway.Core.Uninstall;
using LocalAIGateway.Launcher;
using LocalAIGateway.Windows.Runtime;

namespace LocalAIGateway.Cli;

public static class CliApplication
{
    public const int SuccessExitCode = 0;
    public const int InvalidArgumentsExitCode = 2;
    public const int ConfigurationErrorExitCode = 10;
    public const int CredentialErrorExitCode = 11;
    public const int RuntimeConflictExitCode = 12;
    public const int ClientIntegrationConflictExitCode = 14;
    public const int FileOrPermissionErrorExitCode = 15;
    public const int UsageErrorExitCode = 16;
    public const int BackupErrorExitCode = 17;
    public const int UpdateErrorExitCode = 18;
    public const int UnexpectedErrorExitCode = 70;

    internal const int JsonSchemaVersion = 1;
    internal const string ProductName = "Local AI Gateway";

    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    public static Task<int> RunAsync(string[] args, TextWriter stdout, TextWriter stderr) =>
        RunAsync(args, Console.In, stdout, stderr, services: null);

    public static async Task<int> RunAsync(
        string[] args,
        TextReader stdin,
        TextWriter stdout,
        TextWriter stderr,
        CliServices? services = null)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(stdin);
        ArgumentNullException.ThrowIfNull(stdout);
        ArgumentNullException.ThrowIfNull(stderr);

        var rawOptions = RawOptions.Read(args);
        string? commandKey = null;

        try
        {
            var commandLine = CommandLineDefinition.Create();
            var parseResult = commandLine.Root.Parse(args);
            commandKey = commandLine.GetCommandKey(parseResult.CommandResult.Command);

            var help = parseResult.GetValue(commandLine.HelpOption);
            var version = parseResult.GetValue(commandLine.VersionOption);

            if (parseResult.Errors.Count > 0 && !help && !version)
            {
                return await WriteErrorAsync(
                    stderr,
                    rawOptions,
                    commandKey,
                    InvalidArgumentsExitCode,
                    "aigw_invalid_arguments",
                    "Invalid command-line arguments.",
                    rawOptions.Verbose ? new[] { "Command-line parsing failed." } : Array.Empty<string>());
            }

            var options = new RawOptions(
                parseResult.GetValue(commandLine.JsonOption),
                ResolveLanguage(parseResult.GetValue(commandLine.LanguageOption)),
                parseResult.GetValue(commandLine.VerboseOption));

            if (help && version)
            {
                return await WriteErrorAsync(
                    stderr,
                    options,
                    commandKey,
                    InvalidArgumentsExitCode,
                    "aigw_invalid_arguments",
                    "Options '--help' and '--version' cannot be used together.");
            }

            if (version)
            {
                await WriteVersionAsync(stdout, options.Json);
                return SuccessExitCode;
            }

            if (help || ReferenceEquals(parseResult.CommandResult.Command, commandLine.Root))
            {
                await CliHelp.WriteAsync(
                    stdout,
                    options.Json,
                    options.Language,
                    commandLine,
                    parseResult.CommandResult.Command,
                    commandKey);
                return SuccessExitCode;
            }

            if (commandKey is null)
            {
                return await WriteErrorAsync(
                    stderr,
                    options,
                    null,
                    InvalidArgumentsExitCode,
                    "aigw_subcommand_required",
                    "A subcommand is required.");
            }

            services ??= CliServices.CreateDefault();
            var executor = new CliCommandExecutor(services, stdin, stderr);
            var result = await executor.ExecuteAsync(commandKey, parseResult);
            if (!result.SuppressOutput)
            {
                await WriteCommandResultAsync(stdout, options, commandKey, result);
            }
            return result.ExitCode;
        }
        catch (ConfigurationValidationException exception)
        {
            var details = exception.Errors.Select(error => new
            {
                code = error.Code,
                path = error.Path,
                message = error.Message,
            }).ToArray();
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                ConfigurationErrorExitCode,
                exception.ErrorCode,
                exception.Message,
                details);
        }
        catch (ConfigurationException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                ConfigurationErrorExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (CredentialException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                CredentialErrorExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (InstallationException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                FileOrPermissionErrorExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (UninstallException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                FileOrPermissionErrorExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (GatewayDaemonException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                RuntimeConflictExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (ControlProtocolException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                RuntimeConflictExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (ClientLaunchException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                RuntimeConflictExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (ClientIntegrationFileException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                FileOrPermissionErrorExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (ClientIntegrationException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                ClientIntegrationConflictExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (UsageException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                UsageErrorExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (UpdateException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                UpdateErrorExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (BackupException exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                BackupErrorExitCode,
                exception.ErrorCode,
                exception.Message);
        }
        catch (Exception exception)
        {
            return await WriteErrorAsync(
                stderr,
                rawOptions,
                commandKey,
                UnexpectedErrorExitCode,
                "aigw_internal_error",
                "An unexpected internal error occurred.",
                rawOptions.Verbose
                    ? new[] { exception.GetType().FullName ?? exception.GetType().Name }
                    : Array.Empty<string>());
        }
    }

    internal static string Localize(UiLanguage language, string english, string simplifiedChinese) =>
        language == UiLanguage.SimplifiedChinese ? simplifiedChinese : english;

    private static async Task WriteVersionAsync(TextWriter output, bool json)
    {
        var version = GetVersion();
        if (json)
        {
            await WriteJsonAsync(output, new
            {
                schemaVersion = JsonSchemaVersion,
                ok = true,
                command = "version",
                data = new { product = ProductName, version },
            });
            return;
        }

        await output.WriteLineAsync($"{ProductName} {version}");
    }

    private static async Task WriteCommandResultAsync(
        TextWriter output,
        RawOptions options,
        string commandKey,
        CliCommandResult result)
    {
        if (options.Json)
        {
            await WriteJsonAsync(output, new
            {
                schemaVersion = JsonSchemaVersion,
                ok = true,
                command = commandKey,
                data = result.Data,
            });
            return;
        }

        await output.WriteLineAsync(Localize(options.Language, result.EnglishMessage, result.ChineseMessage));
        if (result.ShowDataInHumanOutput && result.Data is not null)
        {
            await output.WriteLineAsync(JsonSerializer.Serialize(
                result.Data,
                new JsonSerializerOptions(JsonOptions) { WriteIndented = true }));
        }
    }

    private static async Task<int> WriteErrorAsync(
        TextWriter error,
        RawOptions options,
        string? command,
        int exitCode,
        string errorCode,
        string message,
        object? details = null)
    {
        details ??= Array.Empty<string>();
        if (options.Json)
        {
            await WriteJsonAsync(error, new
            {
                schemaVersion = JsonSchemaVersion,
                ok = false,
                command,
                error = new { code = errorCode, message, details },
            });
        }
        else
        {
            var humanMessage = exitCode switch
            {
                InvalidArgumentsExitCode => Localize(
                    options.Language,
                    $"Invalid command-line arguments ({errorCode}). Run 'aigw --help' for usage.",
                    $"命令行参数无效（{errorCode}）。请运行“aigw --help”查看用法。"),
                ConfigurationErrorExitCode => Localize(
                    options.Language,
                    $"Configuration operation failed ({errorCode}).",
                    $"配置操作失败（{errorCode}）。"),
                CredentialErrorExitCode => Localize(
                    options.Language,
                    $"Credential operation failed ({errorCode}).",
                    $"凭据操作失败（{errorCode}）。"),
                RuntimeConflictExitCode => Localize(
                    options.Language,
                    $"Gateway runtime operation failed ({errorCode}).",
                    $"网关运行时操作失败（{errorCode}）。"),
                FileOrPermissionErrorExitCode => Localize(
                    options.Language,
                    $"Installation or file operation failed ({errorCode}).",
                    $"安装或文件操作失败（{errorCode}）。"),
                ClientIntegrationConflictExitCode => Localize(
                    options.Language,
                    $"Client integration preview failed ({errorCode}).",
                    $"客户端集成预览失败（{errorCode}）。"),
                UsageErrorExitCode => Localize(
                    options.Language,
                    $"Usage query failed ({errorCode}).",
                    $"用量查询失败（{errorCode}）。"),
                BackupErrorExitCode => Localize(
                    options.Language,
                    $"Backup operation failed ({errorCode}).",
                    $"备份操作失败（{errorCode}）。"),
                _ => Localize(
                    options.Language,
                    "An unexpected internal error occurred.",
                    "发生未预期的内部错误。"),
            };
            await error.WriteLineAsync(humanMessage);
            if (options.Verbose)
            {
                await error.WriteLineAsync($"  {message}");
            }
        }

        return exitCode;
    }

    private static Task WriteJsonAsync(TextWriter writer, object value) =>
        writer.WriteLineAsync(JsonSerializer.Serialize(value, JsonOptions));

    private static string GetVersion()
    {
        var assembly = typeof(CliApplication).Assembly;
        return assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString()
            ?? "unknown";
    }

    private static UiLanguage ResolveLanguage(string? value)
    {
        if (string.Equals(value, "en", StringComparison.OrdinalIgnoreCase))
        {
            return UiLanguage.English;
        }

        if (string.Equals(value, "zh-CN", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(value, "zh", StringComparison.OrdinalIgnoreCase))
        {
            return UiLanguage.SimplifiedChinese;
        }

        return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.OrdinalIgnoreCase)
            ? UiLanguage.SimplifiedChinese
            : UiLanguage.English;
    }

    internal enum UiLanguage
    {
        English,
        SimplifiedChinese,
    }

    private sealed record RawOptions(bool Json, UiLanguage Language, bool Verbose)
    {
        public static RawOptions Read(IReadOnlyList<string> args)
        {
            var gatewayArguments = args.TakeWhile(value => value != "--").ToArray();
            var json = gatewayArguments.Any(value => value.Equals("--json", StringComparison.OrdinalIgnoreCase));
            var verbose = gatewayArguments.Any(value => value.Equals("--verbose", StringComparison.OrdinalIgnoreCase));
            string? language = null;
            for (var index = 0; index < gatewayArguments.Length - 1; index++)
            {
                if (gatewayArguments[index].Equals("--lang", StringComparison.OrdinalIgnoreCase))
                {
                    language = gatewayArguments[index + 1];
                    break;
                }
            }

            return new RawOptions(json, ResolveLanguage(language), verbose);
        }
    }
}
