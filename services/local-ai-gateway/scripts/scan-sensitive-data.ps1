[CmdletBinding()]
param(
    [string[]] $Paths = @(),
    [string[]] $CanaryValues = @(),
    [string[]] $AllowedPatternFindingSha256 = @(),
    [switch] $ExcludeGenerated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ($Paths.Count -eq 0) {
    $Paths = @($repositoryRoot)
}

$allowedPatternHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($allowedHash in $AllowedPatternFindingSha256) {
    if ($allowedHash -notmatch '^[0-9a-fA-F]{64}$' -or -not $allowedPatternHashes.Add($allowedHash)) {
        throw "Allowed pattern-finding SHA-256 values must be unique 64-character hexadecimal strings."
    }
}

$patterns = @(
    @{
        Label = 'OpenAI project or service-account API key'
        Pattern = [string]::Concat('sk-', '(?:proj-|svcacct-)[A-Za-z0-9_-]{20,}')
    },
    @{
        Label = 'OpenAI legacy API key'
        Pattern = [string]::Concat('sk-', '[A-Za-z0-9]{32,}')
    },
    @{
        Label = 'Anthropic-style API key'
        Pattern = [string]::Concat('sk-ant-', '[A-Za-z0-9_-]{20,}')
    },
    @{
        Label = 'Google-style API key'
        Pattern = [string]::Concat('AIza', '[A-Za-z0-9_-]{30,}')
    },
    @{
        Label = 'Private key block'
        Pattern = [string]::Concat('-----BEGIN ', '(?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
    }
)

$resolvedFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($inputPath in $Paths) {
    $resolvedPath = Resolve-Path -LiteralPath $inputPath -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolvedPath.Path -Force

    if ($item -is [System.IO.DirectoryInfo]) {
        foreach ($file in Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force) {
            if ($file.FullName -match '[\\/](?:\.git|\.vs)[\\/]') {
                continue
            }

            if ($ExcludeGenerated -and $file.FullName -match '[\\/](?:bin|obj|artifacts|TestResults)[\\/]') {
                continue
            }

            $resolvedFiles.Add($file)
        }
    }
    elseif ($item -is [System.IO.FileInfo]) {
        $resolvedFiles.Add($item)
    }
}

$findings = [System.Collections.Generic.List[string]]::new()
foreach ($file in $resolvedFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -eq 0) {
        continue
    }

    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    $fileHash = $null

    foreach ($pattern in $patterns) {
        if ([System.Text.RegularExpressions.Regex]::IsMatch(
            $content,
            $pattern.Pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            if ($null -eq $fileHash) {
                $fileHash = [System.Convert]::ToHexString(
                    [System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            }
            if ($allowedPatternHashes.Contains($fileHash)) {
                continue
            }
            $findings.Add("$($pattern.Label): $($file.FullName)")
        }
    }

    for ($canaryIndex = 0; $canaryIndex -lt $CanaryValues.Count; $canaryIndex++) {
        $canary = $CanaryValues[$canaryIndex]
        if (-not [string]::IsNullOrEmpty($canary) -and
            $content.Contains($canary, [System.StringComparison]::Ordinal)) {
            $findings.Add("Canary $canaryIndex`: $($file.FullName)")
        }
    }
}

if ($findings.Count -gt 0) {
    $summary = $findings -join [Environment]::NewLine
    throw "Sensitive-data scan failed. Matches are reported without secret values:$([Environment]::NewLine)$summary"
}

Write-Output "Sensitive-data scan passed for $($resolvedFiles.Count) file(s)."
