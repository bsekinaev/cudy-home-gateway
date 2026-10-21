# Candidate inspection only. No remote connection and no production writes.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [Parameter(Mandatory=$true)][string]$BundleSha256
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
if ($BundleSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Expected lowercase SHA256.' }
$Bundle=[IO.Path]::GetFullPath($Bundle)
if ((Get-FileHash -LiteralPath $Bundle -Algorithm SHA256).Hash.ToLowerInvariant() -ne $BundleSha256) { throw 'Bundle SHA256 mismatch.' }
$raw=@(& tar -xOzf $Bundle manifest.json)
if ($LASTEXITCODE -ne 0) { throw 'Cannot read manifest.' }
$manifest=($raw -join "`n") | ConvertFrom-Json
if ($manifest.format -ne 'HG_OWNER_UPDATE_V1' -or $manifest.profile -ne 'VM_ONLY' -or $manifest.production_apply -ne $false) { throw 'Invalid candidate manifest.' }
Write-Output ('SOURCE='+$manifest.source_commit)
Write-Output ('BASELINE='+$manifest.baseline_commit)
Write-Output 'READY_FOR_OWNER_MANUAL_UPDATE=NO'
Write-Output 'VM-only candidate: production execution is blocked. Do not upload to CUDY.'
