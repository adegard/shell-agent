# ── Windows setup for shell-agent ─────────────────────────────────────────
# Run this once in PowerShell (as admin for first install).
#
# Usage:
#   .\setup-windows.ps1              # default model qwen2.5-coder:3b
#   .\setup-windows.ps1 llama3       # custom model
#   .\setup-windows.ps1 -CloudOnly   # skip Ollama, just install agent
# ──────────────────────────────────────────────────────────────────────────
param(
    [string]$Model = "qwen2.5-coder:3b",
    [switch]$CloudOnly
)

$ErrorActionPreference = "Stop"

# ── Helpers ────────────────────────────────────────────────────────────────
function Info($msg)  { Write-Host "`e[36m`u{25B8}`e[0m $msg" }
function Ok($msg)    { Write-Host "`e[32m`u{2714}`e[0m $msg" }
function Warn($msg)  { Write-Host "`e[33m`u{26A0}`e[0m $msg" }
function Err($msg)   { Write-Host "`e[31m`u{2716}`e[0m $msg" -ForegroundColor Red }

# ── 1. Check prerequisites ────────────────────────────────────────────────
Info "Checking prerequisites..."

# Git Bash must be available (git bash comes with Git for Windows)
$gitBash = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitBash) {
    Err "Git not found. Install Git for Windows first:"
    Err "  https://git-scm.com/download/win"
    Err "  (includes Git Bash which is required)"
    exit 1
}
Ok "Git found: $($gitBash.Source)"

# jq - download if missing
$jqCmd = Get-Command jq -ErrorAction SilentlyContinue
if (-not $jqCmd) {
    Info "Downloading jq..."
    $jqDir = "$env:USERPROFILE\.local\bin"
    New-Item -ItemType Directory -Force -Path $jqDir | Out-Null
    $jqUrl = "https://github.com/stedolan/jq/releases/latest/download/jq-win64.exe"
    $jqPath = "$jqDir\jq.exe"
    try {
        Invoke-WebRequest -Uri $jqUrl -OutFile $jqPath -UseBasicParsing
        Ok "jq installed to $jqPath"
    } catch {
        # Try jqlang/jq
        $jqUrl = "https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"
        try {
            Invoke-WebRequest -Uri $jqUrl -OutFile $jqPath -UseBasicParsing
            Ok "jq installed to $jqPath"
        } catch {
            Err "Could not download jq. Install manually:"
            Err "  winget install jqlang.jq"
            Err "  or download from https://github.com/jqlang/jq/releases"
            exit 1
        }
    }
} else {
    Ok "jq found: $($jqCmd.Source)"
}

# curl - should be built into Windows 10+
$curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curlCmd) {
    # Try Invoke-WebRequest fallback
    Ok "curl.exe not found, will use Invoke-WebRequest where needed"
} else {
    Ok "curl found: $($curlCmd.Source)"
}

# ── 2. Install Ollama ─────────────────────────────────────────────────────
$ollamaBin = $null
$ollamaPath = "$env:USERPROFILE\.local\bin\ollama.exe"
$ollamaInPath = Get-Command ollama -ErrorAction SilentlyContinue

if ($CloudOnly) {
    Warn "Cloud-only mode: skipping Ollama installation"
} elseif ($ollamaInPath) {
    $ollamaBin = $ollamaInPath.Source
    Ok "Ollama already installed: $ollamaBin"
} elseif (Test-Path $ollamaPath) {
    $ollamaBin = $ollamaPath
    Ok "Ollama already installed: $ollamaBin"
} else {
    Info "Installing Ollama..."
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.local\bin" | Out-Null

    # Download Ollama Windows installer
    $ollamaUrl = "https://ollama.com/download/OllamaSetup.exe"
    $ollamaDl = "$env:TEMP\OllamaSetup.exe"

    Info "Downloading Ollama (~2GB, please wait)..."
    try {
        # Use BitsTransfer for download with progress
        Start-BitsTransfer -Source $ollamaUrl -Destination $ollamaDl -Description "Ollama"
        Info "Running Ollama installer (silent)..."
        Start-Process -FilePath $ollamaDl -ArgumentList "/VERYSILENT","/NORESTART" -Wait
        # Check default install location
        $defaultOllama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
        if (Test-Path $defaultOllama) {
            $ollamaBin = $defaultOllama
            Ok "Ollama installed to $defaultOllama"
        } else {
            # Try PATH
            $ollamaInPath = Get-Command ollama -ErrorAction SilentlyContinue
            if ($ollamaInPath) {
                $ollamaBin = $ollamaInPath.Source
                Ok "Ollama installed"
            }
        }
    } catch {
        # Fallback: direct download of the executable
        Info "Installer failed, downloading binary directly..."
        $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
        $ollamaDirectUrl = "https://ollama.com/download/ollama-windows-$arch.exe"
        try {
            Invoke-WebRequest -Uri $ollamaDirectUrl -OutFile "$env:USERPROFILE\.local\bin\ollama.exe" -UseBasicParsing
            $ollamaBin = "$env:USERPROFILE\.local\bin\ollama.exe"
            Ok "Ollama binary installed to $ollamaBin"
        } catch {
            Err "Could not install Ollama automatically."
            Err "Download manually from: https://ollama.com/download"
            Err "Or run: winget install Ollama.Ollama"
            if (-not $CloudOnly) { exit 1 }
        }
    }
}

# ── 3. Install shell-agent ────────────────────────────────────────────────
$installDir = "$env:USERPROFILE\shell-agent"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$installDirResolved = (Resolve-Path $installDir -ErrorAction SilentlyContinue).Path
$scriptDirResolved = (Resolve-Path $scriptDir -ErrorAction SilentlyContinue).Path

if ($installDirResolved -eq $scriptDirResolved) {
    Ok "shell-agent already in place at $installDir"
} else {
    Info "Installing shell-agent to $installDir..."
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -Path "$scriptDir\lib" -Destination $installDir -Recurse -Force
    Copy-Item -Path "$scriptDir\tools" -Destination $installDir -Recurse -Force
    Copy-Item -Path "$scriptDir\agent.sh" -Destination $installDir -Force
    Ok "shell-agent installed to $installDir"
}

# ── 4. Create PowerShell profile alias ────────────────────────────────────
$profilePath = $PROFILE.CurrentUserAllHosts
$profileDir = Split-Path -Parent $profilePath
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}

# Create or update profile
$marker = "# shell-agent"
if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Force -Path $profilePath | Out-Null
}

$profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if (-not $profileContent -or -not $profileContent.Contains($marker)) {
    $agentShPath = "$installDir\agent.sh" -replace '\\', '/'

    $aliasBlock = @"

$marker
# shell-agent for Windows
`$env:PATH = "`$env:USERPROFILE\.local\bin;`$env:PATH"
function agent {
    param([string]`$Prompt)
    if (`$Prompt) {
        & bash "$agentShPath" `$Prompt
    } else {
        & bash "$agentShPath"
    }
}
function ollama-start { & ollama serve & }
function ollama-stop { Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force }
function ollama-models { (Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/tags' -UseBasicParsing).Content | & jq '.models[].name' }
"@

    Add-Content -Path $profilePath -Value $aliasBlock
    Ok "Added aliases to $profilePath"
} else {
    Ok "Profile already configured"
}

# ── 5. Start Ollama and pull model ────────────────────────────────────────
if (-not $CloudOnly -and $ollamaBin) {
    # Start Ollama server in background
    $ollamaProc = Get-Process ollama -ErrorAction SilentlyContinue
    if (-not $ollamaProc) {
        Info "Starting Ollama server..."
        Start-Process -FilePath $ollamaBin -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }

    # Check if running
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" -UseBasicParsing -TimeoutSec 3
        Ok "Ollama server running"
    } catch {
        Warn "Ollama server may not be running. Start manually with: ollama serve"
    }

    Info "Pulling model: $Model (may take a while on first run)..."
    & $ollamaBin pull $Model
    Ok "Model ready: $Model"
}

# ── Done ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "`e[32m$("=" * 50)`e[0m"
Write-Host "`e[32m  shell-agent installed on Windows!`e[0m"
Write-Host "`e[32m$("=" * 50)`e[0m"
Write-Host ""
Write-Host "  Model:     $Model"
Write-Host "  Install:   $installDir"
Write-Host ""
Write-Host "  Reload profile:"
Write-Host "    . `$PROFILE"
Write-Host ""
Write-Host "  Run agent:"
Write-Host "    agent                         # interactive"
Write-Host "    agent 'write hello world'     # single prompt"
Write-Host ""
Write-Host "  Functions:"
Write-Host "    agent, ollama-start, ollama-stop, ollama-models"
Write-Host ""
if ($CloudOnly) {
    Write-Host "  Cloud mode: set env vars for cloud API:"
    Write-Host "    `$env:CLOUD_API_KEY  = 'sk-...'"
    Write-Host "    `$env:CLOUD_BASE_URL = 'https://api.openai.com/v1'"
    Write-Host "    `$env:CLOUD_MODEL    = 'gpt-4o'"
    Write-Host "    Then run: agent -> /cloud"
    Write-Host ""
}
