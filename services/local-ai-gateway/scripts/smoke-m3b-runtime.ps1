[CmdletBinding()]
param(
    [string] $RuntimeAssemblyRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$assemblyRoot = if ([string]::IsNullOrWhiteSpace($RuntimeAssemblyRoot)) {
    Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly'
}
else {
    [System.IO.Path]::GetFullPath($RuntimeAssemblyRoot)
}
$pythonPath = Join-Path $assemblyRoot 'runtime\python\python.exe'
$stateRoot = Join-Path $assemblyRoot 'runtime-state'
$configurationPath = Join-Path $stateRoot 'smoke-config.json'
$environmentPath = Join-Path $assemblyRoot 'runtime-environment.json'
$moduleDumpSignalPath = Join-Path $stateRoot 'dump-modules.signal'
$moduleDumpPath = Join-Path $stateRoot 'imported-distributions.json'
$internalToken = 'm3b-smoke-internal-token'
$upstreamToken = 'm3b-smoke-upstream-token'

function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0)
    $listener.Start()
    try {
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function New-IsolatedPythonStartInfo {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [hashtable] $AdditionalEnvironment = @{}
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pythonPath
    $startInfo.WorkingDirectory = $assemblyRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment.Clear()
    $startInfo.Environment['SystemRoot'] = [System.Environment]::GetFolderPath('Windows')

    $environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json -AsHashtable
    foreach ($entry in $environment.GetEnumerator()) {
        $value = [string]$entry.Value
        if ($entry.Key -in @(
            'TEMP', 'TMP', 'HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA',
            'XDG_CACHE_HOME', 'HF_HOME', 'HUGGINGFACE_HUB_CACHE',
            'TRANSFORMERS_CACHE', 'TORCH_HOME', 'PIP_CACHE_DIR', 'UV_CACHE_DIR')) {
            $value = Join-Path $assemblyRoot $value
        }
        $startInfo.Environment[[string]$entry.Key] = $value
    }
    foreach ($entry in $AdditionalEnvironment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    return $startInfo
}

function Start-CapturedProcess {
    param([Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo] $StartInfo)

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    if (-not $process.Start()) {
        throw "Failed to start process '$($StartInfo.FileName)'."
    }
    return [pscustomobject]@{
        Process = $process
        StandardOutput = $process.StandardOutput.ReadToEndAsync()
        StandardError = $process.StandardError.ReadToEndAsync()
    }
}

function Stop-CapturedProcess {
    param($CapturedProcess)

    if ($null -eq $CapturedProcess) {
        return
    }
    $process = $CapturedProcess.Process
    if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $process.Dispose()
}

function Get-ExitedProcessMessage {
    param(
        [Parameter(Mandatory)]$CapturedProcess,
        [Parameter(Mandatory)][string]$Name
    )

    $process = $CapturedProcess.Process
    if (-not $process.HasExited) {
        return $null
    }
    return "$Name exited with code $($process.ExitCode).`nstdout:`n$($CapturedProcess.StandardOutput.Result)`nstderr:`n$($CapturedProcess.StandardError.Result)"
}

function Wait-ForHttpSuccess {
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient] $Client,
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)]$CapturedProcess,
        [Parameter(Mandatory)][string] $ProcessName,
        [int] $TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $exitMessage = Get-ExitedProcessMessage -CapturedProcess $CapturedProcess -Name $ProcessName
        if ($null -ne $exitMessage) {
            throw $exitMessage
        }
        try {
            $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
            try {
                if ($response.IsSuccessStatusCode) {
                    return
                }
            }
            finally {
                $response.Dispose()
            }
        }
        catch [System.Net.Http.HttpRequestException] {
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "$ProcessName did not become ready within $TimeoutSeconds seconds."
}

function Clear-RuntimeState {
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        return
    }
    $statePrefix = [System.IO.Path]::GetFullPath($stateRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    foreach ($item in @(Get-ChildItem -LiteralPath $stateRoot -Force)) {
        $fullPath = [System.IO.Path]::GetFullPath($item.FullName)
        if (-not $fullPath.StartsWith($statePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a runtime-state item outside the assembly: $fullPath"
        }
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
    foreach ($stateDirectory in @('temp', 'cache', 'home', 'appdata', 'localappdata')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $stateRoot $stateDirectory)) | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    throw "The private Python runtime does not exist: $pythonPath"
}

Clear-RuntimeState
$fakePort = Get-FreeLoopbackPort
$proxyPort = Get-FreeLoopbackPort
while ($proxyPort -eq $fakePort) {
    $proxyPort = Get-FreeLoopbackPort
}

$configuration = [ordered]@{
    model_list = @(
        [ordered]@{
            model_name = 'aigw/openai-compatible'
            litellm_params = [ordered]@{
                model = 'openai/fake-openai'
                api_base = "http://127.0.0.1:$fakePort/v1"
                api_key = 'os.environ/AIGW_UPSTREAM_000_API_KEY'
                num_retries = 0
            }
        },
        [ordered]@{
            model_name = 'aigw/local-endpoint'
            litellm_params = [ordered]@{
                model = 'openai/fake-local'
                api_base = "http://127.0.0.1:$fakePort/v1"
                api_key = 'none'
                num_retries = 0
            }
        },
        [ordered]@{
            model_name = 'aigw/anthropic'
            litellm_params = [ordered]@{
                model = 'anthropic/fake-anthropic'
                api_base = "http://127.0.0.1:$fakePort"
                api_key = 'os.environ/AIGW_UPSTREAM_000_API_KEY'
                num_retries = 0
            }
        },
        [ordered]@{
            model_name = 'aigw/azure-openai'
            litellm_params = [ordered]@{
                model = 'azure/fake-azure'
                api_base = "http://127.0.0.1:$fakePort"
                api_version = 'v1'
                api_key = 'os.environ/AIGW_UPSTREAM_000_API_KEY'
                num_retries = 0
            }
        }
    )
    litellm_settings = [ordered]@{
        num_retries = 0
        telemetry = $false
        success_callback = @()
        failure_callback = @()
    }
    general_settings = [ordered]@{
        master_key = 'os.environ/AIGW_LITELLM_MASTER_KEY'
    }
}
$configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configurationPath -Encoding utf8NoBOM

$fakeServerCode = @'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, status, body):
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_sse(self, chunks):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(("data: " + json.dumps(chunk, separators=(",", ":")) + "\n\n").encode("utf-8"))
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"ok": True})
        else:
            self._send_json(404, {"error": "not_found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        if self.path == "/v1/responses":
            if self.headers.get("Authorization") != "Bearer m3b-smoke-upstream-token":
                self._send_json(401, {"error": "unexpected_responses_authorization"})
                return
            model = request.get("model")
            self._send_json(200, {
                "id": "resp-m3b-smoke",
                "object": "response",
                "created_at": 0,
                "status": "completed",
                "error": None,
                "incomplete_details": None,
                "instructions": None,
                "max_output_tokens": None,
                "model": model,
                "output": [{
                    "id": "msg-m3b-response",
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "annotations": [], "text": "m3b-responses-ok"}]
                }],
                "parallel_tool_calls": True,
                "previous_response_id": None,
                "reasoning": {"effort": None, "summary": None},
                "store": False,
                "temperature": 1.0,
                "text": {"format": {"type": "text"}},
                "tool_choice": "auto",
                "tools": [],
                "top_p": 1.0,
                "truncation": "disabled",
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2, "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}
            })
            return
        if self.path == "/v1/messages":
            if self.headers.get("x-api-key") != "m3b-smoke-upstream-token":
                self._send_json(401, {"error": "unexpected_anthropic_authorization"})
                return
            model = request.get("model")
            self._send_json(200, {
                "id": "msg-m3b-smoke",
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [{"type": "text", "text": "m3b-fake-ok:" + str(model)}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {"input_tokens": 1, "output_tokens": 1}
            })
            return
        if self.path == "/openai/v1/chat/completions":
            if (self.headers.get("api-key") != "m3b-smoke-upstream-token" and
                    self.headers.get("Authorization") != "Bearer m3b-smoke-upstream-token"):
                self._send_json(401, {
                    "error": "unexpected_azure_authorization",
                    "authorization": self.headers.get("Authorization"),
                    "api_key": self.headers.get("api-key")
                })
                return
            model = "fake-azure"
        elif self.path == "/v1/chat/completions":
            authorization = self.headers.get("Authorization")
            if authorization not in ("Bearer m3b-smoke-upstream-token", "Bearer none"):
                self._send_json(401, {"error": "unexpected_openai_authorization"})
                return
            model = request.get("model")
        else:
            self._send_json(404, {"error": "unexpected_path", "path": self.path})
            return
        if request.get("stream"):
            self._send_sse([
                {"id": "chatcmpl-m3b-stream", "object": "chat.completion.chunk", "created": 0, "model": model, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "m3b-stream-ok"}, "finish_reason": None}]},
                {"id": "chatcmpl-m3b-stream", "object": "chat.completion.chunk", "created": 0, "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            ])
            return
        if request.get("tools"):
            self._send_json(200, {
                "id": "chatcmpl-m3b-tool",
                "object": "chat.completion",
                "created": 0,
                "model": model,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": None, "tool_calls": [{"id": "call_m3b", "type": "function", "function": {"name": "echo", "arguments": "{\"value\":\"ping\"}"}}]}, "finish_reason": "tool_calls"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
            })
            return
        self._send_json(200, {
            "id": "chatcmpl-m3b-smoke",
            "object": "chat.completion",
            "created": 0,
            "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "m3b-fake-ok:" + str(model)}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
        })

server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.serve_forever()
'@

$proxyServerCode = @'
import importlib.metadata
import json
import os
import sys
import threading
import time

def dump_imported_distributions():
    signal_path = os.environ["AIGW_SMOKE_MODULE_DUMP_SIGNAL"]
    output_path = os.environ["AIGW_SMOKE_MODULE_DUMP_PATH"]
    while not os.path.exists(signal_path):
        time.sleep(0.05)
    package_map = importlib.metadata.packages_distributions()
    distributions = sorted({
        distribution.lower()
        for module_name in sys.modules
        for distribution in package_map.get(module_name.split(".")[0], [])
    })
    with open(output_path, "w", encoding="utf-8") as output:
        json.dump(distributions, output, separators=(",", ":"))

threading.Thread(target=dump_imported_distributions, daemon=True).start()
from litellm import run_server
run_server()
'@

$fakeProcess = $null
$proxyProcess = $null
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(5)

try {
    $fakeProcess = Start-CapturedProcess -StartInfo (New-IsolatedPythonStartInfo -Arguments @(
        '-B', '-I', '-c', $fakeServerCode, $fakePort.ToString()
    ))
    Wait-ForHttpSuccess `
        -Client $client `
        -Uri "http://127.0.0.1:$fakePort/health" `
        -CapturedProcess $fakeProcess `
        -ProcessName 'Fake upstream'

    $proxyProcess = Start-CapturedProcess -StartInfo (New-IsolatedPythonStartInfo `
        -Arguments @(
            '-B',
            '-I',
            '-c',
            $proxyServerCode,
            '--config',
            $configurationPath,
            '--host',
            '127.0.0.1',
            '--port',
            $proxyPort.ToString()
        ) `
        -AdditionalEnvironment @{
            AIGW_LITELLM_MASTER_KEY = $internalToken
            AIGW_UPSTREAM_000_API_KEY = $upstreamToken
            AIGW_SMOKE_MODULE_DUMP_SIGNAL = $moduleDumpSignalPath
            AIGW_SMOKE_MODULE_DUMP_PATH = $moduleDumpPath
        })
    Wait-ForHttpSuccess `
        -Client $client `
        -Uri "http://127.0.0.1:$proxyPort/health/liveliness" `
        -CapturedProcess $proxyProcess `
        -ProcessName 'LiteLLM proxy'

    $validatedModels = [System.Collections.Generic.List[string]]::new()
    foreach ($modelAlias in @(
        'aigw/openai-compatible',
        'aigw/local-endpoint',
        'aigw/anthropic',
        'aigw/azure-openai')) {
        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Post,
            "http://127.0.0.1:$proxyPort/v1/chat/completions")
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $internalToken)
        $request.Content = [System.Net.Http.StringContent]::new(
            "{`"model`":`"$modelAlias`",`"messages`":[{`"role`":`"user`",`"content`":`"ping`"}],`"stream`":false}",
            [System.Text.Encoding]::UTF8,
            'application/json')
        $response = $client.Send($request)
        try {
            $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "LiteLLM proxy model '$modelAlias' returned HTTP $([int]$response.StatusCode): $responseBody"
            }
            $responseJson = $responseBody | ConvertFrom-Json
            if (-not ([string]$responseJson.choices[0].message.content).StartsWith('m3b-fake-ok:', [System.StringComparison]::Ordinal)) {
                throw "LiteLLM proxy model '$modelAlias' returned an unexpected response: $responseBody"
            }
            $validatedModels.Add($modelAlias)
        }
        finally {
            $response.Dispose()
            $request.Dispose()
        }
    }

    $toolRequest = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        "http://127.0.0.1:$proxyPort/v1/chat/completions")
    $toolRequest.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $internalToken)
    $toolRequest.Content = [System.Net.Http.StringContent]::new(
        '{"model":"aigw/openai-compatible","messages":[{"role":"user","content":"call echo"}],"tools":[{"type":"function","function":{"name":"echo","description":"Echo a value","parameters":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}}],"stream":false}',
        [System.Text.Encoding]::UTF8,
        'application/json')
    $toolResponse = $client.Send($toolRequest)
    try {
        $toolBody = $toolResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $toolResponse.IsSuccessStatusCode) {
            throw "LiteLLM tool-call smoke test returned HTTP $([int]$toolResponse.StatusCode): $toolBody"
        }
        $toolJson = $toolBody | ConvertFrom-Json
        if ($toolJson.choices[0].message.tool_calls[0].function.name -ne 'echo') {
            throw "LiteLLM tool-call smoke test returned an unexpected response: $toolBody"
        }
    }
    finally {
        $toolResponse.Dispose()
        $toolRequest.Dispose()
    }

    $responsesRequest = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        "http://127.0.0.1:$proxyPort/v1/responses")
    $responsesRequest.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $internalToken)
    $responsesRequest.Content = [System.Net.Http.StringContent]::new(
        '{"model":"aigw/openai-compatible","input":"ping","stream":false}',
        [System.Text.Encoding]::UTF8,
        'application/json')
    $responsesResponse = $client.Send($responsesRequest)
    try {
        $responsesBody = $responsesResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $responsesResponse.IsSuccessStatusCode) {
            throw "LiteLLM Responses smoke test returned HTTP $([int]$responsesResponse.StatusCode): $responsesBody"
        }
        $responsesJson = $responsesBody | ConvertFrom-Json
        if ($responsesJson.output[0].content[0].text -ne 'm3b-responses-ok') {
            throw "LiteLLM Responses smoke test returned an unexpected response: $responsesBody"
        }
    }
    finally {
        $responsesResponse.Dispose()
        $responsesRequest.Dispose()
    }

    $messagesRequest = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        "http://127.0.0.1:$proxyPort/v1/messages")
    $messagesRequest.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $internalToken)
    $messagesRequest.Content = [System.Net.Http.StringContent]::new(
        '{"model":"aigw/anthropic","max_tokens":32,"messages":[{"role":"user","content":"ping"}],"stream":false}',
        [System.Text.Encoding]::UTF8,
        'application/json')
    $messagesResponse = $client.Send($messagesRequest)
    try {
        $messagesBody = $messagesResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $messagesResponse.IsSuccessStatusCode) {
            throw "LiteLLM Anthropic Messages smoke test returned HTTP $([int]$messagesResponse.StatusCode): $messagesBody"
        }
        $messagesJson = $messagesBody | ConvertFrom-Json
        if ($messagesJson.content[0].text -ne 'm3b-fake-ok:fake-anthropic') {
            throw "LiteLLM Anthropic Messages smoke test returned an unexpected response: $messagesBody"
        }
    }
    finally {
        $messagesResponse.Dispose()
        $messagesRequest.Dispose()
    }

    $streamRequest = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        "http://127.0.0.1:$proxyPort/v1/chat/completions")
    $streamRequest.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $internalToken)
    $streamRequest.Content = [System.Net.Http.StringContent]::new(
        '{"model":"aigw/openai-compatible","messages":[{"role":"user","content":"stream"}],"stream":true}',
        [System.Text.Encoding]::UTF8,
        'application/json')
    $streamResponse = $client.Send($streamRequest, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    try {
        $streamBody = $streamResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $streamResponse.IsSuccessStatusCode -or
            -not $streamBody.Contains('m3b-stream-ok', [System.StringComparison]::Ordinal) -or
            -not $streamBody.Contains('data: [DONE]', [System.StringComparison]::Ordinal)) {
            throw "LiteLLM SSE smoke test returned an unexpected response: $streamBody"
        }
    }
    finally {
        $streamResponse.Dispose()
        $streamRequest.Dispose()
    }

    [System.IO.File]::WriteAllText($moduleDumpSignalPath, 'dump')
    $moduleDumpDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $moduleDumpPath -PathType Leaf) -and
        [DateTime]::UtcNow -lt $moduleDumpDeadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $moduleDumpPath -PathType Leaf)) {
        throw 'LiteLLM proxy did not emit the imported-distribution inventory.'
    }
    $importedDistributions = Get-Content -Raw -LiteralPath $moduleDumpPath | ConvertFrom-Json

    Write-Output "LiteLLM offline smoke test passed on loopback ports $proxyPort -> $fakePort."
    Write-Output "Validated provider mappings: $($validatedModels -join ',')"
    Write-Output 'Validated protocols: chat-completions, responses, anthropic-messages, SSE, tool-calls'
    Write-Output "Imported distributions after request: $($importedDistributions.Count)"
    Write-Output ($importedDistributions -join ',')
}
finally {
    Stop-CapturedProcess -CapturedProcess $proxyProcess
    Stop-CapturedProcess -CapturedProcess $fakeProcess
    $client.Dispose()
    $handler.Dispose()

    $stateFilesBeforeCleanup = @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -Force)
    Write-Output "Contained runtime-state files before cleanup: $($stateFilesBeforeCleanup.Count)"
    Clear-RuntimeState

    $remainingPyc = @(Get-ChildItem -LiteralPath $assemblyRoot -Recurse -File -Filter '*.pyc' -Force)
    $remainingCacheDirectories = @(
        Get-ChildItem -LiteralPath $assemblyRoot -Recurse -Directory -Force |
            Where-Object { $_.Name -eq '__pycache__' }
    )
    if ($remainingPyc.Count -ne 0 -or $remainingCacheDirectories.Count -ne 0) {
        throw "The smoke test left Python bytecode cache in the assembly."
    }
}
