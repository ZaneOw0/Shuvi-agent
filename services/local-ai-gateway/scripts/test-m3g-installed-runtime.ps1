[CmdletBinding()]
param(
    [string]$PackagePath = (Join-Path $PSScriptRoot "..\artifacts\m3g-package-output\LocalAIGateway-0.1.0-dev-win-x64-unsigned.zip"),
    [string]$AcceptanceRoot = (Join-Path $PSScriptRoot "..\artifacts\m3g-installed-runtime-acceptance"),
    [string]$ExpectedPackageSha256 = "03a2c977d38ee868ee904018f479b4bd521fc1182d21239208dc15547689004a",
    [string]$DiagnosticResultPath = "",
    [switch]$TestAutostart,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$credentialTarget = "LocalAIGateway/runtime/client-token"
$profileId = "m3g-acceptance"
$providerId = "local"
$modelAlias = "aigw/m3g-acceptance"
$localEndpoint = "http://127.0.0.1:65534/v1"
$expectedReadyStatus = [System.Net.HttpStatusCode]::Unauthorized
$autostartTasks = @(
    [ordered]@{
        name = "LocalAIGateway.Runtime"
        path = "\LocalAIGateway.Runtime"
        action = "aigw-runtime.exe"
        arguments = "--serve"
    },
    [ordered]@{
        name = "LocalAIGateway.Tray"
        path = "\LocalAIGateway.Tray"
        action = "tray\aigw-tray.exe"
        arguments = ""
    }
)
$runtimeAutostartTask = $autostartTasks[0]

function Resolve-NonRootPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [System.IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Label must be a fully qualified path."
    }

    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $volumeRoot = [System.IO.Path]::GetPathRoot($resolved).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrEmpty($resolved) -or
        $resolved.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must not be a volume root."
    }

    return $resolved
}

function Test-IsContainedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Candidate,
        [Parameter(Mandatory)]
        [string]$Parent
    )

    $parentPrefix = $Parent.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    return $Candidate.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-CredentialPresent {
    param([Parameter(Mandatory)][string]$Target)

    $output = @(& cmdkey.exe "/list:$Target" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "cmdkey could not query the exact runtime credential target."
    }

    $text = $output -join [Environment]::NewLine
    $entryPattern = "(?i)(?:Legacy)?Generic:target=" + [regex]::Escape($Target) + "(?:\s|$)"
    return [regex]::IsMatch($text, $entryPattern)
}

function Get-UserPathSnapshot {
    $key = Get-Item -LiteralPath 'Registry::HKEY_CURRENT_USER\Environment' -ErrorAction Stop
    $exists = @($key.GetValueNames() | Where-Object {
        $_.Equals('Path', [StringComparison]::OrdinalIgnoreCase)
    }).Count -ne 0
    if (-not $exists) {
        return [pscustomobject]@{ exists = $false; value = ''; kind = 'ExpandString' }
    }
    $value = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($value -isnot [string]) {
        throw 'The current-user PATH registry value is not a string.'
    }
    return [pscustomobject]@{
        exists = $true
        value = [string]$value
        kind = $key.GetValueKind('Path').ToString()
    }
}

function Get-EquivalentPathEntryCount {
    param(
        [Parameter(Mandatory)][string]$PathValue,
        [Parameter(Mandatory)][string]$ExpectedEntry
    )

    $count = 0
    foreach ($entry in $PathValue.Split(';')) {
        $candidate = $entry.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        try {
            $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
            $normalized = [IO.Path]::GetFullPath($expanded).TrimEnd(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar)
            if ($normalized.Equals($ExpectedEntry, [StringComparison]::OrdinalIgnoreCase)) {
                $count++
            }
        }
        catch {
            # Unrelated malformed entries are preserved and ignored by the exact target check.
        }
    }
    return $count
}

function Get-ShortcutDetails {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        return [pscustomobject]@{
            targetPath = [string]$shortcut.TargetPath
            workingDirectory = [string]$shortcut.WorkingDirectory
            arguments = [string]$shortcut.Arguments
        }
    }
    finally {
        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Invoke-AigwJson {
    param(
        [Parameter(Mandatory)]
        [string]$Executable,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "Required CLI executable is missing: $Executable"
    }

    $output = @(& $Executable --json @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "aigw command failed with exit code ${exitCode}: $($Arguments -join ' ')`n$text"
    }

    try {
        $result = $text | ConvertFrom-Json
    }
    catch {
        throw "aigw returned invalid JSON for '$($Arguments -join ' ')'."
    }
    if (-not $result.ok) {
        throw "aigw returned a failed result for '$($Arguments -join ' ')'."
    }

    return $result
}

function Remove-OwnedDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$ExpectedPath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $resolved = (Get-Item -LiteralPath $Path -Force).FullName.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    if (-not $resolved.Equals($ExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected path: $resolved"
    }
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to remove a reparse-point root: $resolved"
    }

    $reparsePoints = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction Stop |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
    if ($reparsePoints.Count -ne 0) {
        throw "Refusing to recurse through $($reparsePoints.Count) reparse point(s) under: $resolved"
    }

    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Get-InstalledProcesses {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $prefix = $InstallRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    return @(
        Get-Process -ErrorAction Stop | ForEach-Object {
            try {
                $path = $_.Path
                if (-not [string]::IsNullOrWhiteSpace($path) -and
                    $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $_
                }
            }
            catch {
                # Unrelated protected processes are outside this exact-path check.
            }
        }
    )
}

function Get-AutostartTaskXml {
    param(
        [Parameter(Mandatory)]
        [string]$TaskName
    )

    $service = $null
    $root = $null
    $task = $null
    try {
        $service = New-Object -ComObject "Schedule.Service"
        $service.Connect()
        $root = $service.GetFolder("\")
        try {
            $task = $root.GetTask($TaskName)
        }
        catch {
            if ($_.Exception.HResult -in @([int]0x80070002, [int]0x80070003)) {
                return $null
            }
            throw
        }
        return [string]$task.Xml
    }
    finally {
        if ($null -ne $task) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($task)
        }
        if ($null -ne $root) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($root)
        }
        if ($null -ne $service) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)
        }
    }
}

$repositoryRoot = Resolve-NonRootPath -Path (Join-Path $PSScriptRoot "..") -Label "Repository root"
$artifactsRoot = Resolve-NonRootPath -Path (Join-Path $repositoryRoot "artifacts") -Label "Artifacts root"
$packagePathFull = Resolve-NonRootPath -Path $PackagePath -Label "Package path"
$acceptanceRootFull = Resolve-NonRootPath -Path $AcceptanceRoot -Label "Acceptance root"
if (-not (Test-IsContainedPath -Candidate $acceptanceRootFull -Parent $artifactsRoot)) {
    throw "AcceptanceRoot must be contained under the repository artifacts directory."
}
$diagnosticResultPathFull = $null
if (-not [string]::IsNullOrWhiteSpace($DiagnosticResultPath)) {
    $diagnosticResultPathFull = Resolve-NonRootPath -Path $DiagnosticResultPath -Label "Diagnostic result path"
    if (-not (Test-IsContainedPath -Candidate $diagnosticResultPathFull -Parent $artifactsRoot)) {
        throw "DiagnosticResultPath must be contained under the repository artifacts directory."
    }
    if (Test-Path -LiteralPath $diagnosticResultPathFull) {
        throw "The exact diagnostic result path already exists; refusing to overwrite it: $diagnosticResultPathFull"
    }
}
if (-not (Test-Path -LiteralPath $packagePathFull -PathType Leaf)) {
    throw "The M3g package is missing: $packagePathFull"
}
if (Test-Path -LiteralPath $acceptanceRootFull) {
    throw "The exact acceptance root already exists; refusing to overwrite or delete it: $acceptanceRootFull"
}

$actualPackageHash = (Get-FileHash -LiteralPath $packagePathFull -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualPackageHash -ne $ExpectedPackageSha256.ToLowerInvariant()) {
    throw "M3g package SHA-256 mismatch: expected $ExpectedPackageSha256, got $actualPackageHash"
}
$sidecarPath = "$packagePathFull.sha256"
if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
    throw "The M3g package SHA-256 sidecar is missing: $sidecarPath"
}
$sidecar = Get-Content -LiteralPath $sidecarPath -Raw
if ($sidecar -notmatch "^$([regex]::Escape($actualPackageHash))\s{2}$([regex]::Escape([System.IO.Path]::GetFileName($packagePathFull)))$") {
    throw "The M3g package SHA-256 sidecar does not match the ZIP."
}

$localAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($localAppData)) {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
}
$localAppDataFull = Resolve-NonRootPath -Path $localAppData -Label "Current-user Local AppData root"
$roamingAppData = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($roamingAppData)) {
    $roamingAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
}

function Get-AutostartTaskDiagnostics {
    param([Parameter(Mandatory)][string]$TaskName)

    $service = $null
    $root = $null
    $task = $null
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $root = $service.GetFolder('\')
        $task = $root.GetTask($TaskName)
        return [ordered]@{
            state = [int]$task.State
            lastTaskResult = ('0x{0:X8}' -f ([long]$task.LastTaskResult -band 0xffffffffL))
            lastRunTime = ([DateTime]$task.LastRunTime).ToUniversalTime().ToString('O')
            missedRuns = [int]$task.NumberOfMissedRuns
        }
    }
    finally {
        if ($null -ne $task) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($task)
        }
        if ($null -ne $root) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($root)
        }
        if ($null -ne $service) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)
        }
    }
}

function Get-OperationalEventNames {
    param([Parameter(Mandatory)][string]$StateRoot)

    $path = Join-Path $StateRoot 'logs\gateway.log'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    return @(
        Get-Content -LiteralPath $path -Tail 20 | ForEach-Object {
            try {
                $entry = $_ | ConvertFrom-Json -ErrorAction Stop
                $name = [string]$entry.event
                if ($entry.PSObject.Properties.Name -contains 'configurationRevision') {
                    $name += "[revision=$($entry.configurationRevision)]"
                }
                if ($entry.PSObject.Properties.Name -contains 'errorCode') {
                    "${name}:$($entry.errorCode)"
                }
                else {
                    $name
                }
            }
            catch {
                'invalid-log-entry'
            }
        }
    )
}

function Get-ConfigurationDiagnostic {
    param([Parameter(Mandatory)][string]$StateRoot)

    $path = Join-Path $StateRoot 'config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{ exists = $false; readable = $false; revision = $null; activeProfileId = $null; currentUserFullControl = $false }
    }
    try {
        $configuration = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        $acl = Get-Acl -LiteralPath $path
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $currentUserFullControl = @($acl.Access | Where-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $currentSid -and
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        }).Count -ne 0
        return [ordered]@{
            exists = $true
            readable = $true
            revision = [long]$configuration.revision
            activeProfileId = [string]$configuration.activeProfileId
            currentUserFullControl = $currentUserFullControl
        }
    }
    catch {
        return [ordered]@{ exists = $true; readable = $false; revision = $null; activeProfileId = $null; currentUserFullControl = $false }
    }
}
$roamingAppDataFull = Resolve-NonRootPath -Path $roamingAppData -Label "Current-user Roaming AppData root"
$installRoot = Resolve-NonRootPath -Path (Join-Path $localAppDataFull "Programs\LocalAIGateway") -Label "Install root"
$stateRoot = Resolve-NonRootPath -Path (Join-Path $localAppDataFull "LocalAIGateway") -Label "State root"
$shellReceiptPath = Join-Path $stateRoot 'installation\shell-integration.json'
$startMenuDirectory = Resolve-NonRootPath -Path (Join-Path $roamingAppDataFull 'Microsoft\Windows\Start Menu\Programs\Local AI Gateway') -Label 'Start Menu directory'
$startMenuShortcut = Join-Path $startMenuDirectory 'Local AI Gateway.lnk'
$stagingParent = [System.IO.Path]::GetDirectoryName($installRoot)
$originalUserPath = Get-UserPathSnapshot

$preflightFailures = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $installRoot) {
    $preflightFailures.Add("Program root already exists: $installRoot")
}
if (Test-Path -LiteralPath $stateRoot) {
    $preflightFailures.Add("State root already exists: $stateRoot")
}
if (Test-CredentialPresent -Target $credentialTarget) {
    $preflightFailures.Add("Runtime credential already exists: $credentialTarget")
}
if (@(Get-InstalledProcesses -InstallRoot $installRoot).Count -ne 0) {
    $preflightFailures.Add("A process is already running from the target program root.")
}
if (@(Get-ChildItem -LiteralPath $stagingParent -Directory -Filter "LocalAIGateway.installing-*" -Force -ErrorAction SilentlyContinue).Count -ne 0) {
    $preflightFailures.Add("An installer staging directory already exists beside the target program root.")
}
if ((Get-EquivalentPathEntryCount -PathValue $originalUserPath.value -ExpectedEntry $installRoot) -ne 0) {
    $preflightFailures.Add("The current-user PATH already contains the install root without an acceptance ownership receipt: $installRoot")
}
if (Test-Path -LiteralPath $startMenuShortcut) {
    $preflightFailures.Add("The exact Start Menu shortcut already exists: $startMenuShortcut")
}
if ($TestAutostart) {
    foreach ($task in $autostartTasks) {
        if ($null -ne (Get-AutostartTaskXml -TaskName $task.name)) {
            $preflightFailures.Add("The exact Task Scheduler path already exists: $($task.path)")
        }
    }
}
if ($preflightFailures.Count -ne 0) {
    throw ($preflightFailures -join [Environment]::NewLine)
}

$plan = [ordered]@{
    mode = if ($Execute) { "execute" } else { "preflight" }
    packagePath = $packagePathFull
    packageSha256 = $actualPackageHash
    acceptanceRoot = $acceptanceRootFull
    diagnosticResultPath = $diagnosticResultPathFull
    programRoot = $installRoot
    stateRoot = $stateRoot
    credentialTarget = $credentialTarget
    taskScheduler = [bool]$TestAutostart
    taskPaths = if ($TestAutostart) { @($autostartTasks | ForEach-Object { $_.path }) } else { @() }
    taskTrigger = if ($TestAutostart) { "Current-user logon" } else { $null }
    taskLogonType = if ($TestAutostart) { "InteractiveToken" } else { $null }
    taskRunLevel = if ($TestAutostart) { "LeastPrivilege" } else { $null }
    taskActions = if ($TestAutostart) { @($autostartTasks | ForEach-Object { Join-Path $installRoot $_.action }) } else { @() }
    taskArguments = if ($TestAutostart) { @($autostartTasks | ForEach-Object { $_.arguments }) } else { @() }
    taskWorkingDirectories = if ($TestAutostart) { @($installRoot, (Join-Path $installRoot "tray")) } else { @() }
    pathModification = $true
    pathRegistryTarget = 'HKEY_CURRENT_USER\Environment\Path'
    pathEntry = $installRoot
    startMenuModification = $true
    startMenuShortcut = $startMenuShortcut
    startMenuTarget = (Join-Path $installRoot 'tray\aigw-tray.exe')
    startMenuWorkingDirectory = (Join-Path $installRoot 'tray')
    shellOwnershipReceipt = $shellReceiptPath
    upstreamContact = $false
    modelRequest = $false
}

if (-not $Execute) {
    [pscustomobject]$plan | ConvertTo-Json
    Write-Host "M3g installed-runtime preflight passed. Re-run with -Execute only after exact external-write approval."
    return
}

$acceptanceOwned = $false
$stateOwned = $false
$sourceCli = $null
$installedCli = Join-Path $installRoot "aigw.exe"
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$testFailure = $null
$acceptanceResult = $null
$uninstallArguments = @('uninstall')
$autostartActionStartedRuntime = $false
$autostartActionStartedTray = $false

try {
    New-Item -ItemType Directory -Path $acceptanceRootFull | Out-Null
    $acceptanceOwned = $true
    $packageRoot = Join-Path $acceptanceRootFull "package"
    Expand-Archive -LiteralPath $packagePathFull -DestinationPath $packageRoot
    $sourceCli = Join-Path $packageRoot "aigw.exe"

    $initialStatus = Invoke-AigwJson -Executable $sourceCli -Arguments @("status")
    if ($initialStatus.data.running) {
        throw "The gateway unexpectedly reported running after the clean preflight."
    }

    $installHelp = (& $sourceCli install --lang en --help 2>&1 | Out-String)
    $supportsPairedAutostart = $installHelp.Contains("--autostart", [StringComparison]::Ordinal)
    $supportsShellIntegration =
        $installHelp.Contains('user PATH', [StringComparison]::Ordinal) -and
        $installHelp.Contains('Tray Start Menu shortcut', [StringComparison]::Ordinal)
    if ($supportsShellIntegration) {
        $uninstallArguments = @(
            'uninstall', '--non-interactive', '--confirm', 'UNINSTALL',
            '--program', 'remove',
            '--autostart', 'remove',
            '--integrations', 'keep',
            '--runtime-credential', 'remove',
            '--provider-credentials', 'remove',
            '--configuration', 'remove',
            '--usage', 'remove',
            '--logs', 'remove',
            '--backups', 'keep'
        )
    }
    $installArguments = if ($supportsPairedAutostart) {
        @("install", "--autostart", "disable")
    }
    else {
        @("install")
    }
    $install = Invoke-AigwJson -Executable $sourceCli -Arguments $installArguments
    if (-not $install.data.installed -or
        $install.data.alreadyInstalled -or
        -not $install.data.runtimeCredentialCreated) {
        throw "The clean current-user installation did not create the expected package and runtime credential."
    }
    if ($supportsShellIntegration) {
        if (-not $install.data.userPath.owned -or
            $install.data.userPath.target -ne 'HKEY_CURRENT_USER\Environment\Path' -or
            -not $install.data.startMenu.owned -or
            $install.data.startMenu.target -ne $startMenuShortcut) {
            throw 'The installation result did not report the exact owned PATH and Start Menu integration.'
        }
        $installedUserPath = Get-UserPathSnapshot
        if ((Get-EquivalentPathEntryCount -PathValue $installedUserPath.value -ExpectedEntry $installRoot) -ne 1) {
            throw 'The install root was not added exactly once to the current-user PATH.'
        }
        $shortcut = Get-ShortcutDetails -Path $startMenuShortcut
        if ($null -eq $shortcut -or
            -not $shortcut.targetPath.Equals((Join-Path $installRoot 'tray\aigw-tray.exe'), [StringComparison]::OrdinalIgnoreCase) -or
            -not $shortcut.workingDirectory.Equals((Join-Path $installRoot 'tray'), [StringComparison]::OrdinalIgnoreCase) -or
            $shortcut.arguments -ne '') {
            throw 'The Start Menu shortcut does not contain the exact owned Tray action.'
        }
        if (-not (Test-Path -LiteralPath $shellReceiptPath -PathType Leaf)) {
            throw 'The shell-integration ownership receipt was not created.'
        }
    }

    $stateOwned = $true
    $null = Invoke-AigwJson -Executable $installedCli -Arguments @(
        "profile", "create", "--id", $profileId, "--name", "M3g Acceptance")
    $null = Invoke-AigwJson -Executable $installedCli -Arguments @(
        "provider", "add", "--profile", $profileId, "--id", $providerId,
        "--name", "Local Acceptance", "--type", "local-endpoint", "--endpoint", $localEndpoint)
    $null = Invoke-AigwJson -Executable $installedCli -Arguments @(
        "model", "add", "--profile", $profileId, "--alias", $modelAlias,
        "--provider", $providerId, "--upstream", "acceptance-model", "--default")
    $null = Invoke-AigwJson -Executable $installedCli -Arguments @(
        "profile", "use", "--id", $profileId)
    $validation = Invoke-AigwJson -Executable $installedCli -Arguments @("config", "validate")
    if (-not $validation.data.valid) {
        throw "The generated local-only acceptance configuration was not valid."
    }

    $started = $null
    $autostartEnabled = $false
    if ($TestAutostart) {
        $enable = Invoke-AigwJson -Executable $installedCli -Arguments @("autostart", "enable")
        if ($supportsPairedAutostart) {
            if (-not $enable.data.changed -or -not $enable.data.registered -or
                -not $enable.data.owned -or $enable.data.conflict -or $enable.data.incomplete -or
                $enable.data.runtime.taskPath -ne $autostartTasks[0].path -or
                $enable.data.tray.taskPath -ne $autostartTasks[1].path -or
                -not $enable.data.runtime.owned -or -not $enable.data.tray.owned) {
                throw "Autostart enable did not create both exact owned tasks."
            }
        }
        elseif (-not $enable.data.changed -or -not $enable.data.registered -or
            -not $enable.data.owned -or $enable.data.conflict -or
            $enable.data.taskPath -ne $runtimeAutostartTask.path) {
            throw "Legacy autostart enable did not create the exact owned Runtime task."
        }
        $autostartEnabled = $true

        $repeatedEnable = Invoke-AigwJson -Executable $installedCli -Arguments @("autostart", "enable")
        if ($repeatedEnable.data.changed -or -not $repeatedEnable.data.owned) {
            throw "Repeated autostart enable was not idempotent."
        }
        $autostartStatus = Invoke-AigwJson -Executable $installedCli -Arguments @("autostart", "status")
        if ($supportsPairedAutostart) {
            if (-not $autostartStatus.data.registered -or -not $autostartStatus.data.owned -or
                $autostartStatus.data.conflict -or $autostartStatus.data.incomplete -or
                -not $autostartStatus.data.runtime.owned -or -not $autostartStatus.data.tray.owned) {
                throw "The registered autostart tasks did not pass semantic readback."
            }
        }
        elseif (-not $autostartStatus.data.registered -or -not $autostartStatus.data.owned -or
            $autostartStatus.data.conflict) {
            throw "The legacy Runtime autostart task did not pass semantic readback."
        }

        if ($supportsPairedAutostart) {
            & schtasks.exe /Run /TN $autostartTasks[1].path | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Task Scheduler could not manually run the owned Tray autostart task.'
            }
            $trayExecutable = Join-Path $installRoot 'tray\aigw-tray.exe'
            $trayDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
            $trayProcesses = @()
            do {
                [Threading.Thread]::Sleep(250)
                $trayProcesses = @(Get-InstalledProcesses -InstallRoot $installRoot | Where-Object {
                    try {
                        $_.Path.Equals($trayExecutable, [StringComparison]::OrdinalIgnoreCase)
                    }
                    catch {
                        $false
                    }
                })
            } while ($trayProcesses.Count -eq 0 -and [DateTimeOffset]::UtcNow -lt $trayDeadline)
            if ($trayProcesses.Count -ne 1) {
                throw "The Tray task did not produce exactly one owned Tray process; count=$($trayProcesses.Count)."
            }
            $autostartActionStartedTray = $true
            $trayProcesses[0].Kill($true)
            [void]$trayProcesses[0].WaitForExit(5000)
        }

        $configurationBeforeTask = Get-ConfigurationDiagnostic -StateRoot $stateRoot
        if (-not $configurationBeforeTask.readable -or
            $configurationBeforeTask.revision -ne 4 -or
            $configurationBeforeTask.activeProfileId -ne $profileId -or
            -not $configurationBeforeTask.currentUserFullControl) {
            throw "The configuration was not intact immediately before the Runtime task. Diagnostic=$($configurationBeforeTask | ConvertTo-Json -Compress)"
        }
        $runtimeTaskRequestedAt = [DateTimeOffset]::UtcNow
        & schtasks.exe /Run /TN $runtimeAutostartTask.path | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Task Scheduler could not manually run the owned autostart task."
        }
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(70)
        do {
            [Threading.Thread]::Sleep(250)
            $scheduledStatus = Invoke-AigwJson -Executable $installedCli -Arguments @("status")
            $currentTaskDiagnostics = Get-AutostartTaskDiagnostics -TaskName $runtimeAutostartTask.name
            $taskFinishedWithFailure =
                $currentTaskDiagnostics.state -eq 3 -and
                $currentTaskDiagnostics.lastTaskResult -notin @('0x00000000', '0x00041301') -and
                [DateTimeOffset]::Parse($currentTaskDiagnostics.lastRunTime) -ge $runtimeTaskRequestedAt.AddSeconds(-2)
        } while (-not $scheduledStatus.data.running -and -not $taskFinishedWithFailure -and [DateTimeOffset]::UtcNow -lt $deadline)
        if (-not $scheduledStatus.data.running) {
            $taskDiagnostics = Get-AutostartTaskDiagnostics -TaskName $runtimeAutostartTask.name
            $operationalEvents = @(Get-OperationalEventNames -StateRoot $stateRoot)
            $configurationAfterTask = Get-ConfigurationDiagnostic -StateRoot $stateRoot
            throw "The Task Scheduler action did not start the gateway before the deadline. Task=$($taskDiagnostics | ConvertTo-Json -Compress); operationalEvents=$($operationalEvents -join ','); configBefore=$($configurationBeforeTask | ConvertTo-Json -Compress); configAfter=$($configurationAfterTask | ConvertTo-Json -Compress)."
        }
        $started = $scheduledStatus
        $autostartActionStartedRuntime = $true

        $disable = Invoke-AigwJson -Executable $installedCli -Arguments @("autostart", "disable")
        if (-not $disable.data.changed -or $disable.data.registered -or
            $disable.data.owned -or $disable.data.conflict) {
            throw "Autostart disable did not remove the owned task."
        }
        $autostartEnabled = $false
        $repeatedDisable = Invoke-AigwJson -Executable $installedCli -Arguments @("autostart", "disable")
        if ($repeatedDisable.data.changed -or $repeatedDisable.data.registered) {
            throw "Repeated autostart disable was not idempotent."
        }
    }
    else {
        $started = Invoke-AigwJson -Executable $installedCli -Arguments @("start")
    }
    if (-not $started.data.running) {
        throw "The installed runtime did not report a clean daemon start."
    }
    if ($started.data.activeProfileId -ne $profileId) {
        throw "The daemon started with an unexpected active profile."
    }

    $idempotentStart = Invoke-AigwJson -Executable $installedCli -Arguments @("start")
    if (-not $idempotentStart.data.running -or
        $idempotentStart.data.activeProfileId -ne $started.data.activeProfileId -or
        $idempotentStart.data.activeConfigurationRevision -ne $started.data.activeConfigurationRevision) {
        throw "A repeated daemon start was not idempotent."
    }
    $status = Invoke-AigwJson -Executable $installedCli -Arguments @("status")
    if (-not $status.data.running -or $status.data.activeProfileId -ne $profileId) {
        throw "The current-user control pipe did not report the expected running daemon."
    }
    $doctor = Invoke-AigwJson -Executable $installedCli -Arguments @("doctor")
    if (-not $doctor.data.healthy -or
        $doctor.data.modelProbePerformed -or
        $doctor.data.upstreamContacted) {
        throw "Installed doctor did not preserve the read-only, no-upstream contract."
    }

    $httpClient = [System.Net.Http.HttpClient]::new()
    try {
        $httpClient.Timeout = [TimeSpan]::FromSeconds(5)
        $readyResponse = $httpClient.GetAsync("http://127.0.0.1:4000/ready").GetAwaiter().GetResult()
        try {
            if ($readyResponse.StatusCode -ne $expectedReadyStatus) {
                throw "Unauthenticated /ready returned $([int]$readyResponse.StatusCode), expected 401."
            }
        }
        finally {
            $readyResponse.Dispose()
        }
    }
    finally {
        $httpClient.Dispose()
    }

    $stopped = Invoke-AigwJson -Executable $installedCli -Arguments @("stop")
    if ($stopped.data.running) {
        throw "The installed daemon did not stop cleanly."
    }
    $uninstall = Invoke-AigwJson -Executable $sourceCli -Arguments $uninstallArguments
    if ($supportsShellIntegration) {
        if (-not $uninstall.data.program.changed -or -not $uninstall.data.runtimeCredential.changed) {
            throw 'The external package did not remove the installed files, shell integration, and runtime credential.'
        }
    }
    elseif (-not $uninstall.data.removed -or -not $uninstall.data.runtimeCredentialDeleted) {
        throw 'The external package did not remove the installed files and runtime credential.'
    }

    $acceptanceResult = [ordered]@{
        packageSha256 = $actualPackageHash
        installedRuntimeStarted = $true
        repeatedStartIdempotent = $true
        activeProfileId = $status.data.activeProfileId
        activeConfigurationRevision = $status.data.activeConfigurationRevision
        unauthenticatedReadyStatus = [int]$expectedReadyStatus
        modelProbePerformed = $doctor.data.modelProbePerformed
        upstreamContacted = $doctor.data.upstreamContacted
        autostartTested = [bool]$TestAutostart
        autostartActionStartedRuntime = $autostartActionStartedRuntime
        autostartActionStartedTray = $autostartActionStartedTray
        autostartEnabledAfterTest = $autostartEnabled
    }
}
catch {
    $testFailure = $_
    if ($diagnosticResultPathFull) {
        [pscustomobject]@{
            failed = $true
            message = $_.Exception.Message
            autostartActionStartedRuntime = $autostartActionStartedRuntime
            autostartActionStartedTray = $autostartActionStartedTray
            recordedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $diagnosticResultPathFull -Encoding utf8NoBOM
    }
}
finally {
    if ($sourceCli -and (Test-Path -LiteralPath $sourceCli -PathType Leaf)) {
        if ($TestAutostart) {
            try {
                $null = Invoke-AigwJson -Executable $sourceCli -Arguments @("autostart", "disable")
            }
            catch {
                $cleanupFailures.Add("Autostart disable cleanup failed: $($_.Exception.Message)")
            }
        }
        try {
            $null = Invoke-AigwJson -Executable $sourceCli -Arguments @("stop")
        }
        catch {
            $cleanupFailures.Add("Daemon stop cleanup failed: $($_.Exception.Message)")
        }
        try {
            $trayExecutable = Join-Path $installRoot 'tray\aigw-tray.exe'
            foreach ($installedProcess in @(Get-InstalledProcesses -InstallRoot $installRoot)) {
                if ($installedProcess.Path.Equals($trayExecutable, [StringComparison]::OrdinalIgnoreCase)) {
                    $installedProcess.Kill($true)
                    [void]$installedProcess.WaitForExit(5000)
                }
            }
        }
        catch {
            $cleanupFailures.Add("Tray process cleanup failed: $($_.Exception.Message)")
        }
        try {
            $null = Invoke-AigwJson -Executable $sourceCli -Arguments $uninstallArguments
        }
        catch {
            $cleanupFailures.Add("Program/credential uninstall cleanup failed: $($_.Exception.Message)")
        }
    }

    if ($stateOwned -and (Test-Path -LiteralPath $stateRoot)) {
        try {
            Remove-OwnedDirectory -Path $stateRoot -ExpectedPath $stateRoot
        }
        catch {
            $cleanupFailures.Add("State-root cleanup failed: $($_.Exception.Message)")
        }
    }
    if ($acceptanceOwned -and (Test-Path -LiteralPath $acceptanceRootFull)) {
        try {
            Remove-OwnedDirectory -Path $acceptanceRootFull -ExpectedPath $acceptanceRootFull
        }
        catch {
            $cleanupFailures.Add("Acceptance-root cleanup failed: $($_.Exception.Message)")
        }
    }
}

$residue = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $installRoot) {
    $residue.Add("Program root remains: $installRoot")
}
if (Test-Path -LiteralPath $stateRoot) {
    $residue.Add("State root remains: $stateRoot")
}
if (Test-Path -LiteralPath $acceptanceRootFull) {
    $residue.Add("Acceptance root remains: $acceptanceRootFull")
}
if (Test-CredentialPresent -Target $credentialTarget) {
    $residue.Add("Runtime credential remains: $credentialTarget")
}
$finalUserPath = Get-UserPathSnapshot
if ($finalUserPath.exists -ne $originalUserPath.exists -or
    $finalUserPath.kind -ne $originalUserPath.kind -or
    $finalUserPath.value -cne $originalUserPath.value) {
    $residue.Add('The current-user PATH was not restored byte-for-byte to its preflight value and type.')
}
if ((Get-EquivalentPathEntryCount -PathValue $finalUserPath.value -ExpectedEntry $installRoot) -ne 0) {
    $residue.Add("The install-root PATH entry remains: $installRoot")
}
if (Test-Path -LiteralPath $startMenuShortcut) {
    $residue.Add("The Start Menu shortcut remains: $startMenuShortcut")
}
if (Test-Path -LiteralPath $shellReceiptPath) {
    $residue.Add("The shell-integration receipt remains: $shellReceiptPath")
}
if ($TestAutostart) {
    foreach ($task in $autostartTasks) {
        if ($null -ne (Get-AutostartTaskXml -TaskName $task.name)) {
            $residue.Add("Task Scheduler entry remains: $($task.path)")
        }
    }
}
$remainingProcesses = @(Get-InstalledProcesses -InstallRoot $installRoot)
if ($remainingProcesses.Count -ne 0) {
    $residue.Add("$($remainingProcesses.Count) installed process(es) remain.")
}
$remainingStaging = @(Get-ChildItem -LiteralPath $stagingParent -Directory -Filter "LocalAIGateway.installing-*" -Force -ErrorAction SilentlyContinue)
if ($remainingStaging.Count -ne 0) {
    $residue.Add("$($remainingStaging.Count) installer staging directory/directories remain.")
}

if ($testFailure -or $cleanupFailures.Count -ne 0 -or $residue.Count -ne 0) {
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($testFailure) {
        $failures.Add("Acceptance failed: $($testFailure.Exception.Message)")
    }
    foreach ($failure in $cleanupFailures) {
        $failures.Add($failure)
    }
    foreach ($item in $residue) {
        $failures.Add($item)
    }
    throw ($failures -join [Environment]::NewLine)
}

[pscustomobject]$acceptanceResult | ConvertTo-Json
Write-Host "M3g installed-runtime acceptance passed."
Write-Host "Program root, state root, credential, task, staging, process, and acceptance-root residue: 0"
