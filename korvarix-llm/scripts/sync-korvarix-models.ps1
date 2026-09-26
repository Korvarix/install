# sync-korvarix-models.ps1 - auto-pull the model list from the Korvarix LLM
# endpoint and merge it into opencode's real provider config
# (~/.config/opencode/opencode.jsonc).
#
# Why this file: opencode does NOT query <baseURL>/models for custom
# providers - the "models" map in opencode.jsonc IS the discovery, so the
# only way new models show up in the /models picker is to write them there.
# This script does exactly that, idempotently:
#
#   1. GET <base>/v1/models (Bearer key from ~/.local/share/opencode/auth.json
#      or the KORVARIX_API_KEY env var)
#   2. merge every returned model id into provider.<ID>.models, preserving
#      existing entries (names/limits/options are kept, never downgraded)
#   3. validate the resulting JSON, then atomically replace the config
#      (timestamped backup written first, last 10 kept)
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync-korvarix-models.ps1           # apply
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync-korvarix-models.ps1 -WhatIf  # preview
#
# Optional params: -BaseUrl, -ProviderId, -ConfigPath, -Key

param(
    [string]$BaseUrl = "https://llm.korvarix.com/api/v1",
    [string]$ProviderId = "korvarix",
    [string]$ConfigPath = "$env:USERPROFILE\.config\opencode\opencode.jsonc",
    [string]$Key = "",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "[sync] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[sync] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[sync] $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 1. resolve API key: -Key param > KORVARIX_API_KEY env > auth.json
# ---------------------------------------------------------------------------
$authPath = "$env:USERPROFILE\.local\share\opencode\auth.json"
if ($Key -and $Key.Trim()) {
    $key = $Key.Trim()
    Write-Step "key source: -Key parameter"
} elseif ($env:KORVARIX_API_KEY) {
    $key = $env:KORVARIX_API_KEY.Trim()
    Write-Step "key source: KORVARIX_API_KEY env var"
} elseif (Test-Path $authPath) {
    try {
        $auth = Get-Content -Raw $authPath | ConvertFrom-Json
        $stored = $auth.$ProviderId.key
        if ($stored) {
            $key = $stored.Trim()
            Write-Step "key source: auth.json (provider '$ProviderId')"
        }
    } catch {
        Write-Warn2 "auth.json unreadable ($($_.Exception.Message)) - continuing without it"
    }
}
if (-not $key) {
    # discovery stays public after the gate patch: try the call without a key
    Write-Warn2 "no API key found (-Key / KORVARIX_API_KEY / auth.json:$ProviderId) - trying unauthenticated discovery"
    $key = $null
}

# ---------------------------------------------------------------------------
# 2. pull the live model list
# ---------------------------------------------------------------------------
$modelsUrl = "$($BaseUrl.TrimEnd('/'))/models"
Write-Step "fetching $modelsUrl"
$headers = @{}
if ($key) { $headers["Authorization"] = "Bearer $key" }

$ProgressPreference = "SilentlyContinue"
try {
    $resp = Invoke-WebRequest -Uri $modelsUrl -Headers $headers -TimeoutSec 30 -UseBasicParsing
} catch {
    # PowerShell 5.1: HTTP errors (401/403/429/5xx) land here; ErrorDetails.Message
    # carries the gate's JSON error body - surface it instead of a bare message
    $detail = $_.ErrorDetails.Message
    if ($detail) { Write-Host "[sync] endpoint said: $detail" -ForegroundColor Red }
    throw "failed to reach $modelsUrl - $($_.Exception.Message)"
}
$ids = @()
try {
    $payload = $resp.Content | ConvertFrom-Json
    # OpenAI shape: { object:"list", data:[{id:...}, ...] }
    $ids = @($payload.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    # tolerate flat-array responses: ["m1","m2"] or {models:[...]}
    if (-not $ids.Count -and $payload.models) {
        $ids = @($payload.models | ForEach-Object { if ($_.id) { [string]$_.id } else { [string]$_ } })
    }
    if (-not $ids.Count -and $payload -is [array]) {
        $ids = @($payload | ForEach-Object { if ($_.id) { [string]$_.id } else { [string]$_ } })
    }
} catch {
    throw "response was not parseable JSON (is the gate patch deployed?): $($_.Exception.Message)"
}
if (-not $ids.Count) { throw "model list at $modelsUrl is EMPTY - nothing to sync (policy allowlist on the server has no models?)" }
$ids = @($ids | Select-Object -Unique)
Write-Ok "found $($ids.Count) model(s): $($ids -join ', ')"

# ---------------------------------------------------------------------------
# 3. load + normalize the config (strip comments from jsonc)
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-Warn2 "config not found at $ConfigPath - creating it"
    New-Item -ItemType Directory -Force -Path (Split-Path $ConfigPath) | Out-Null
    Set-Content -LiteralPath $ConfigPath -Value '{ "$schema": "https://opencode.ai/config.json" }' -Encoding UTF8
}
$raw = Get-Content -Raw -LiteralPath $ConfigPath
# jsonc -> json: strip /* */ blocks and // line comments (not inside strings)
$stripped = $raw -replace '(?s)/\*.*?\*/', '' -replace '(?m)^\s*//.*$', ''
try {
    $cfg = $stripped | ConvertFrom-Json
} catch {
    throw "config at $ConfigPath is not valid JSON(C): $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 4. merge models into provider.<ProviderId>.models (existing entries win)
# ---------------------------------------------------------------------------
# ensure provider.<ProviderId> exists with the right npm/baseURL
if (-not $cfg.provider) { $cfg | Add-Member -NotePropertyName provider -NotePropertyValue ([pscustomobject]@{}) }
$prov = $cfg.provider.PSObject.Properties[$ProviderId]
if (-not $prov) {
    $newProv = [pscustomobject]@{
        npm     = "@ai-sdk/openai-compatible"
        name    = "Korvarix LLM"
        options = [pscustomobject]@{ baseURL = ($BaseUrl.TrimEnd('/') -replace '/api/v1$', '/api/v1') }
        models  = [pscustomobject]@{}
    }
    $cfg.provider | Add-Member -NotePropertyName $ProviderId -NotePropertyValue $newProv
    $prov = $cfg.provider.PSObject.Properties[$ProviderId]
    Write-Step "provider '$ProviderId' did not exist - created with defaults"
}
$p = $prov.Value
if (-not $p.models) { $p | Add-Member -NotePropertyName models -NotePropertyValue ([pscustomobject]@{}) }

$added = @()
$kept  = 0
foreach ($id in $ids) {
    if ($p.models.PSObject.Properties[$id]) { $kept++ } else {
        $p.models | Add-Member -NotePropertyName $id -NotePropertyValue (
            [pscustomobject]@{ name = $id; tool_call = $true }
        )
        $added += $id
    }
}
if ($added.Count -eq 0) {
    Write-Ok "config already up to date ($kept existing model(s)) - nothing to do"
    exit 0
}

# ---------------------------------------------------------------------------
# 5. serialize, validate, backup, atomic replace
# ---------------------------------------------------------------------------
$out = $cfg | ConvertTo-Json -Depth 32
# self-check: the merge result must round-trip
try {
    $null = $out | ConvertFrom-Json
} catch {
    throw "internal error: generated config failed validation - aborting, file untouched"
}

if ($WhatIf) {
    Write-Step "WHATIF - would add $($added.Count) model(s) to $ConfigPath"
    $added | ForEach-Object { Write-Host "  + $_" }
    Write-Host ""
    Write-Host "// --- preview of provider.$ProviderId ---"
    $preview = $cfg.provider.PSObject.Properties[$ProviderId].Value | ConvertTo-Json -Depth 8
    Write-Host $preview
    exit 0
}

# backup: timestamped, keep the last 10
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "$ConfigPath.bak.$stamp"
Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
Get-ChildItem -LiteralPath (Split-Path $ConfigPath) -Filter "$(Split-Path $ConfigPath -Leaf).bak.*" |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | ForEach-Object { Remove-Item $_.FullName -Force }

# atomic replace: write temp file, then move over the target
$tmp = "$ConfigPath.tmp"
Set-Content -LiteralPath $tmp -Value $out -Encoding UTF8 -NoNewline
Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force

Write-Ok "added $($added.Count) model(s): $($added -join ', ')"
Write-Ok "backup: $backup"
Write-Warn2 "restart opencode for the new models to appear in /models"