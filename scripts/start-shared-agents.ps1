param(
    [Parameter(Position = 0)]
    [string]$Agent = "codex",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AgentArgs = @()
)

$env:HEADROOM_PORT = if ($env:HEADROOM_PORT) { $env:HEADROOM_PORT } else { "8787" }
$env:HEADROOM_WRAP_PROXY_TIMEOUT = if ($env:HEADROOM_WRAP_PROXY_TIMEOUT) {
    $env:HEADROOM_WRAP_PROXY_TIMEOUT
} else {
    "120"
}

function Get-ExistingHeadroomProxyPid {
    $port = [int]$env:HEADROOM_PORT

    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($listener) {
            return [string]$listener.OwningProcess
        }
    }

    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $proc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match "headroom\.cli\s+proxy" -and
                $_.CommandLine -match "(--port\s+$port|--port=$port)"
            } |
            Select-Object -First 1
        if ($proc) {
            return [string]$proc.ProcessId
        }
    }

    return $null
}

function Get-HeadroomWrapArgs {
    $wrapArgs = @("--port", $env:HEADROOM_PORT)
    $pid = Get-ExistingHeadroomProxyPid
    if ($pid) {
        Write-Host "Reusing existing Headroom proxy on port $($env:HEADROOM_PORT) (PID $pid)."
        $wrapArgs += "--no-proxy"
    }
    return $wrapArgs
}

function Preserve-AnthropicUpstream {
    if ($env:ANTHROPIC_BASE_URL -and -not $env:ANTHROPIC_TARGET_API_URL) {
        $env:ANTHROPIC_TARGET_API_URL = $env:ANTHROPIC_BASE_URL
    }
}

$wrapArgs = Get-HeadroomWrapArgs

# Resolve Python runner
$pythonBin = "python"
if (-not (Get-Command $pythonBin -ErrorAction SilentlyContinue)) {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $pythonBin = "py"
    } else {
        Write-Error "Python runtime not found in environment."
        exit 1
    }
}

# Verify headroom module is installed
$verifyCmd = if ($pythonBin -eq "py") { "py -3 -c 'import headroom'" } else { "python -c 'import headroom'" }
Invoke-Expression $verifyCmd | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "headroom-ai is not installed in the current Python environment."
    Write-Host "Please install it using: pip install headroom-ai"
    exit 1
}

if ($Agent -eq "codex") {
    Preserve-AnthropicUpstream
    Write-Host "Starting Codex wrapped with Headroom (Memory + Code Graph)..."
    if ($pythonBin -eq "py") {
        & py -3 -m headroom.cli wrap codex --memory --code-graph @wrapArgs @AgentArgs
    } else {
        & python -m headroom.cli wrap codex --memory --code-graph @wrapArgs @AgentArgs
    }
} elseif ($Agent -eq "claude" -or $Agent -eq "claude-code") {
    Preserve-AnthropicUpstream
    Write-Host "Starting Claude Code wrapped with Headroom (Dangerous Skip; preserves custom Anthropic upstream if configured)..."
    if ($pythonBin -eq "py") {
        & py -3 -m headroom.cli wrap claude --memory --code-graph @wrapArgs -- --dangerously-skip-permissions @AgentArgs
    } else {
        & python -m headroom.cli wrap claude --memory --code-graph @wrapArgs -- --dangerously-skip-permissions @AgentArgs
    }
} elseif ($Agent -eq "agy" -or $Agent -eq "antigravity" -or $Agent -eq "agy-cli") {
    Write-Host "Starting Antigravity (agy) wrapped with Headroom (Memory)..."
    if ($pythonBin -eq "py") {
        & py -3 -m headroom.cli wrap agy --memory @wrapArgs -- --dangerously-skip-permissions @AgentArgs
    } else {
        & python -m headroom.cli wrap agy --memory @wrapArgs -- --dangerously-skip-permissions @AgentArgs
    }
} else {
    Write-Error "Unknown agent: $Agent"
    Write-Host "Usage: .\scripts\start-shared-agents.ps1 [codex|claude|agy]"
    exit 1
}
