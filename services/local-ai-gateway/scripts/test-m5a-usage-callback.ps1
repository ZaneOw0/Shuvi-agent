[CmdletBinding()]
param(
    [string]$PythonPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    $PythonPath = Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly\runtime\python\python.exe'
}
$python = [System.IO.Path]::GetFullPath($PythonPath)
$callback = Join-Path $repositoryRoot 'src\LocalAIGateway.LiteLlm\Assets\aigw_usage_callback.py'
$driver = Join-Path $repositoryRoot 'tests\fixtures\m5a_usage_callback_driver.py'
$fakeServer = Join-Path $repositoryRoot 'tests\fixtures\m5a_fake_openai.py'
$proxyVerifier = Join-Path $repositoryRoot 'tests\fixtures\m5a_verify_proxy_usage.py'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("LocalAIGateway-M5a-" + [Guid]::NewGuid().ToString('N'))

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Private Python runtime was not found: $python"
}

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
$proxyProcess = $null
$fakeProcess = $null
try {
    $metadata = Join-Path $temporaryRoot 'aigw-usage-metadata.json'
    $database = Join-Path $temporaryRoot 'usage.db'
    $temporaryCallback = Join-Path $temporaryRoot 'aigw_usage_callback.py'
    $proxyConfiguration = Join-Path $temporaryRoot 'litellm.json'
    [System.IO.File]::Copy($callback, $temporaryCallback)
    [System.IO.File]::WriteAllText(
        $metadata,
        '{"version":1,"profileId":"profile","models":{"public-model":"provider"}}',
        [System.Text.UTF8Encoding]::new($false))

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $python
    $startInfo.WorkingDirectory = $temporaryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $processEnvironment = $startInfo.EnvironmentVariables
    $processEnvironment.Clear()
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    if (-not [string]::IsNullOrEmpty($systemRoot)) {
        $processEnvironment['SystemRoot'] = $systemRoot
    }
    $processEnvironment['PYTHONNOUSERSITE'] = '1'
    $processEnvironment['PYTHONDONTWRITEBYTECODE'] = '1'
    $processEnvironment['PYTHONUTF8'] = '1'
    $processEnvironment['DO_NOT_TRACK'] = 'true'
    $processEnvironment['LITELLM_LOCAL_MODEL_COST_MAP'] = 'True'
    $processEnvironment['HOME'] = $temporaryRoot
    $processEnvironment['USERPROFILE'] = $temporaryRoot
    $processEnvironment['APPDATA'] = $temporaryRoot
    $processEnvironment['LOCALAPPDATA'] = $temporaryRoot
    $processEnvironment['TEMP'] = $temporaryRoot
    $processEnvironment['TMP'] = $temporaryRoot
    $processEnvironment['XDG_CACHE_HOME'] = (Join-Path $temporaryRoot 'cache')
    $processEnvironment['AIGW_USAGE_METADATA'] = $metadata
    $processEnvironment['AIGW_USAGE_DATABASE'] = $database
    foreach ($argumentPath in @($driver, $callback, $database)) {
        if ($argumentPath.Contains('"')) {
            throw "Python argument path contains an unsupported quote: $argumentPath"
        }
    }
    $startInfo.Arguments = '-B -I "{0}" "{1}" "{2}"' -f $driver, $callback, $database

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'Private Python process did not start.'
    }
    $output = $process.StandardOutput.ReadToEnd()
    $errorOutput = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "M5a callback acceptance failed with exit code $($process.ExitCode).`n$errorOutput"
    }
    Write-Output $output.Trim()

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $proxyPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $listener.Start()
    $fakePort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    while ($fakePort -eq $proxyPort) {
        $listener.Start()
        $fakePort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
    }
    $configuration = [ordered]@{
        model_list = @(
            [ordered]@{
                model_name = 'public-model'
                litellm_params = [ordered]@{
                    model = 'openai/fake-model'
                    api_base = "http://127.0.0.1:$fakePort/v1"
                    api_key = 'none'
                    num_retries = 0
                }
            }
        )
        litellm_settings = [ordered]@{
            num_retries = 0
            telemetry = $false
            callbacks = @('aigw_usage_callback.usage_logger')
            turn_off_message_logging = $true
            redact_user_api_key_info = $true
        }
        general_settings = [ordered]@{
            master_key = 'os.environ/AIGW_LITELLM_MASTER_KEY'
        }
    }
    [System.IO.File]::WriteAllText(
        $proxyConfiguration,
        ($configuration | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false))

    $proxyStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $proxyStartInfo.FileName = $python
    $proxyStartInfo.WorkingDirectory = $temporaryRoot
    $proxyStartInfo.UseShellExecute = $false
    $proxyStartInfo.CreateNoWindow = $true
    $proxyEnvironment = $proxyStartInfo.EnvironmentVariables
    $proxyEnvironment.Clear()
    foreach ($entry in $processEnvironment.GetEnumerator()) {
        $proxyEnvironment[[string]$entry.Key] = [string]$entry.Value
    }
    $proxyEnvironment['AIGW_LITELLM_MASTER_KEY'] = 'm5a-private-token'

    $fakeStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $fakeStartInfo.FileName = $python
    $fakeStartInfo.WorkingDirectory = $temporaryRoot
    $fakeStartInfo.UseShellExecute = $false
    $fakeStartInfo.CreateNoWindow = $true
    $fakeEnvironment = $fakeStartInfo.EnvironmentVariables
    $fakeEnvironment.Clear()
    foreach ($entry in $processEnvironment.GetEnumerator()) {
        $fakeEnvironment[[string]$entry.Key] = [string]$entry.Value
    }
    $fakeStartInfo.Arguments = '-B -I "{0}" {1}' -f $fakeServer, $fakePort
    $fakeProcess = [System.Diagnostics.Process]::Start($fakeStartInfo)
    if ($null -eq $fakeProcess) {
        throw 'Fake OpenAI process did not start.'
    }

    $proxyStartInfo.Arguments = '-B -I -c "from litellm import run_server; run_server()" --config "{0}" --host 127.0.0.1 --port {1}' -f $proxyConfiguration, $proxyPort
    $proxyProcess = [System.Diagnostics.Process]::Start($proxyStartInfo)
    if ($null -eq $proxyProcess) {
        throw 'Real LiteLLM callback-load process did not start.'
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        $ready = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($proxyProcess.HasExited) {
                throw "Real LiteLLM callback-load process exited with code $($proxyProcess.ExitCode)."
            }
            try {
                $response = $client.GetAsync("http://127.0.0.1:$proxyPort/health/liveliness").GetAwaiter().GetResult()
                try {
                    if ($response.IsSuccessStatusCode) {
                        $ready = $true
                        break
                    }
                }
                finally {
                    $response.Dispose()
                }
            }
            catch [System.Net.Http.HttpRequestException] {
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $ready) {
            throw 'Real LiteLLM did not become ready with the owned callback loaded.'
        }
        Write-Output 'M5a real LiteLLM callback-load acceptance passed'

        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Post,
            "http://127.0.0.1:$proxyPort/v1/chat/completions")
        try {
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
                'Bearer',
                'm5a-private-token')
            $request.Content = [System.Net.Http.StringContent]::new(
                '{"model":"public-model","messages":[{"role":"user","content":"proxy-prompt-canary-m5a"}]}',
                [System.Text.Encoding]::UTF8,
                'application/json')
            $completion = $client.SendAsync($request).GetAwaiter().GetResult()
            try {
                if (-not $completion.IsSuccessStatusCode) {
                    $body = $completion.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    throw "Real LiteLLM request failed with $([int]$completion.StatusCode): $body"
                }
            }
            finally {
                $completion.Dispose()
            }
        }
        finally {
            $request.Dispose()
        }

        $verified = $false
        $verifyDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $verifyStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $verifyStartInfo.FileName = $python
            $verifyStartInfo.WorkingDirectory = $temporaryRoot
            $verifyStartInfo.UseShellExecute = $false
            $verifyStartInfo.CreateNoWindow = $true
            $verifyStartInfo.RedirectStandardOutput = $true
            $verifyStartInfo.RedirectStandardError = $true
            $verifyEnvironment = $verifyStartInfo.EnvironmentVariables
            $verifyEnvironment.Clear()
            if (-not [string]::IsNullOrEmpty($systemRoot)) {
                $verifyEnvironment['SystemRoot'] = $systemRoot
            }
            $verifyStartInfo.Arguments = '-B -I "{0}" "{1}"' -f $proxyVerifier, $database
            $verifyProcess = [System.Diagnostics.Process]::Start($verifyStartInfo)
            $verifyOutput = $verifyProcess.StandardOutput.ReadToEnd()
            $verifyProcess.StandardError.ReadToEnd() | Out-Null
            $verifyProcess.WaitForExit()
            $verified = $verifyProcess.ExitCode -eq 0
            $verifyProcess.Dispose()
            if (-not $verified) {
                Start-Sleep -Milliseconds 100
            }
        } while (-not $verified -and [DateTime]::UtcNow -lt $verifyDeadline)
        if (-not $verified) {
            throw 'Real LiteLLM callback did not persist the expected usage event.'
        }
        Write-Output $verifyOutput.Trim()
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}
finally {
    if ($null -ne $proxyProcess) {
        if (-not $proxyProcess.HasExited) {
            $proxyProcess.Kill()
            $proxyProcess.WaitForExit()
        }
        $proxyProcess.Dispose()
    }
    if ($null -ne $fakeProcess) {
        if (-not $fakeProcess.HasExited) {
            $fakeProcess.Kill()
            $fakeProcess.WaitForExit()
        }
        $fakeProcess.Dispose()
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
