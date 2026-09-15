# push-policy.ps1 — push the dry-run policy to the llm.korvarix.com server.
# Writes BOM-free copies + computes sha256 sidecar, then scp's both files to
# /etc/korvarix-llm/ on the server. The gate hot-reloads within 60s (no restart).
#
# Usage:  .\push-policy.ps1 -Server root@your-server-host
#         .\push-policy.ps1 -Server root@host -Dest /etc/korvarix-llm
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$Dest = "/etc/korvarix-llm"
)
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Write-BomFreeAscii([string]$Path) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes((Get-Content -LiteralPath $Path -Raw))
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    Write-Host "==> BOM-free normalized: $Path"
}

function Write-Log([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
Write-Host "==> normalizing policy file (BOM-free, LF)"
# normalize to LF-only (sha256 must match what the gate reads)
$raw = (Get-Content -LiteralPath "korvarix-policy.json" -Raw) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText("$PWD\korvarix-policy.json", $raw, (New-Object System.Text.UTF8Encoding($false)))

$hash = (Get-FileHash -LiteralPath "korvarix-policy.json" -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText("$PWD\korvarix-policy.json.sha256", "$hash`n", (New-Object System.Text.UTF8Encoding $false))
Write-Host "==> sha256: $hash"

Write-Host "==> pushing to ${Dest} on $Server (644: gate runs as non-root user)"
scp "korvarix-policy.json" "${Server}:${Dest}/korvarix-policy.json"
if ($LASTEXITCODE -ne 0) { Write-Host "error: scp policy failed" -ForegroundColor Red; exit 1 }
scp "korvarix-policy.json.sha256" "${Server}:${Dest}/korvarix-policy.json.sha256"
if ($LASTEXITCODE -ne 0) { Write-Host "error: scp checksum failed" -ForegroundColor Red; exit 1 }
# 644 both: the gate container runs as the non-root "node" user — 640/600 leaves
# the files root-only and the gate reports "no policy file"
ssh $Server "chmod 644 ${Dest}/korvarix-policy.json ${Dest}/korvarix-policy.json.sha256; mkdir -p /var/log/korvarix; chown -R 1000:1000 /var/log/korvarix 2>/dev/null || chmod 777 /var/log/korvarix"

Write-Host ""
Write-Host "Pushed. Verify on the server (60s window):" -ForegroundColor Green
Write-Host "  docker logs korvarix-llm-gate --tail 5"
Write-Host "Expected line:  policy loaded v1757858400 (models: 1, rpm/ip=10, ...)"
Write-Host "If it still says BUILT-IN defaults after 60s, check the policy PATH mount:"
Write-Host "  docker inspect korvarix-llm-gate --format '{{json .Mounts}}'"