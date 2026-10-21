# Owner-controlled stages; no automatic apply, recovery, reboot or cleanup.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [Parameter(Mandatory=$true)][string]$BundleSha256,
    [Parameter(Mandatory=$true)][ValidatePattern('^root@[A-Za-z0-9][A-Za-z0-9.-]{0,126}$')][string]$Target,
    [Parameter(Mandatory=$true)][string]$SessionFile,
    [ValidateRange(1,65535)][int]$Port=22,
    [ValidateSet('Preflight','Apply','Verify','Rollback','Recover')][string]$Stage='Preflight',
    [switch]$ReserveAccessConfirmed
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
if ($BundleSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Expected lowercase SHA256.' }
foreach ($name in @('ssh','scp','tar')) { $null=Get-Command $name -ErrorAction Stop }
$Bundle=[IO.Path]::GetFullPath($Bundle)
if ((Get-FileHash -LiteralPath $Bundle -Algorithm SHA256).Hash.ToLowerInvariant() -ne $BundleSha256) { throw 'Bundle SHA256 mismatch.' }
$raw=@(& tar -xOzf $Bundle manifest.json)
if ($LASTEXITCODE -ne 0) { throw 'Cannot read manifest.' }
$manifestText=($raw -join "`n")+"`n"
$manifest=$manifestText | ConvertFrom-Json
if ($manifest.format -ne 'HG_OWNER_UPDATE_V1' -or $manifest.profile -ne 'OWNER_MANUAL' -or $manifest.production_apply -ne $true -or $manifest.source_commit -notmatch '^[0-9a-f]{40}$' -or $manifest.baseline_commit -ne '62592457237e7f026786c086d1ca6fdd4b6c095d') { throw 'Accepted owner package required. VM-only bundles cannot target CUDY.' }
$hasher=[Security.Cryptography.SHA256]::Create()
try { $pin=([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($manifestText)))).Replace('-','').ToLowerInvariant() } finally { $hasher.Dispose() }
if ($Stage -in @('Apply','Rollback','Recover') -and !$ReserveAccessConfirmed) { throw 'Confirm working independent reserve access with -ReserveAccessConfirmed before this explicit stage.' }
$SessionFile=[IO.Path]::GetFullPath($SessionFile)
$null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SessionFile)
if (Test-Path -LiteralPath $SessionFile) {
    $session=Get-Content -Raw -LiteralPath $SessionFile | ConvertFrom-Json
    if ($session.format -ne 'HG_OWNER_UPDATE_SESSION_V1' -or $session.target -ne $Target -or $session.port -ne $Port -or $session.sha256 -ne $BundleSha256 -or $session.source -ne $manifest.source_commit) { throw 'Session identity mismatch. Preserve the old session.' }
} else {
    $session=[pscustomobject]@{format='HG_OWNER_UPDATE_SESSION_V1';target=$Target;port=$Port;sha256=$BundleSha256;source=$manifest.source_commit;remoteKit=$null;preflightPassed=$false}
}
function Save-Session {
    $temporary=$SessionFile+'.'+[guid]::NewGuid().ToString('N')+'.new'
    $session | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -Force -LiteralPath $temporary -Destination $SessionFile
}
$common=@('-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2')
$sshOptions=@('-T','-p',[string]$Port)+$common
function Remote([string]$Command) {
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command.Replace("`r`n","`n")))
    $wire='printf %s '+$encoded+' | base64 -d | sh'
    $savedPreference=$ErrorActionPreference
    try { $ErrorActionPreference='Continue'; $lines=@(& ssh @sshOptions $Target $wire 2>&1); $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$savedPreference }
    foreach ($line in $lines) { Write-Host $line }
    return [pscustomobject]@{Lines=$lines;Code=$code}
}
function Success($Result) { if ($Result.Code -ne 0) { throw ('Remote stage failed: '+$Result.Code+'. Preserve evidence; no automatic recovery was attempted.') } }
if ($session.remoteKit) {
    if ($session.remoteKit -notmatch '^/tmp/hg-owner-update-kit\.[A-Za-z0-9]{6}/kit$') { throw 'Invalid session kit path.' }
    $exists=Remote ('test -d '+$session.remoteKit)
    if ($exists.Code -eq 1) { $session.remoteKit=$null; Save-Session }
    elseif ($exists.Code -ne 0) { throw 'SSH kit check failed; do not replace session identity.' }
}
if (!$session.remoteKit) {
    $created=Remote 'umask 077; mktemp -d /tmp/hg-owner-update-kit.XXXXXX'
    Success $created
    $roots=@($created.Lines | Where-Object { $_ -match '^/tmp/hg-owner-update-kit\.[A-Za-z0-9]{6}$' })
    if ($roots.Count -ne 1) { throw 'No unique staging directory.' }
    $root=[string]$roots[0]
    $remoteArchive=$root+'/bundle.tar.gz'
    $scpOptions=@('-O','-P',[string]$Port)+$common
    & scp @scpOptions $Bundle ($Target+':'+$remoteArchive)
    if ($LASTEXITCODE -ne 0) { throw 'Kit upload failed. Runtime was not changed.' }
    $command='actual=$(sha256sum '+$remoteArchive+'); test "${actual%% *}" = '+$BundleSha256+' && mkdir -m 700 '+$root+'/kit && tar -xzpf '+$remoteArchive+' -C '+$root+'/kit'
    Success (Remote $command)
    $session.remoteKit=$root+'/kit'; Save-Session
}
if ($Stage -eq 'Apply' -and $session.preflightPassed -ne $true) { throw 'Run Preflight successfully in this session before Apply.' }
if ($Stage -eq 'Preflight') { $session.preflightPassed=$false; Save-Session }
Save-Session
$result=Remote ('sh '+$session.remoteKit+'/update.sh '+$Stage.ToLowerInvariant()+' '+$pin)
$evidence=$SessionFile+'.'+$Stage.ToLowerInvariant()+'.'+[guid]::NewGuid().ToString('N')+'.txt'
$result.Lines | Set-Content -LiteralPath $evidence -Encoding UTF8
Success $result
if ($Stage -eq 'Preflight') { $session.preflightPassed=$true; Save-Session }
Write-Host ('OWNER_UPDATE_STAGE='+$Stage+' RESULT=PASS SOURCE='+$session.source)
Write-Host ('PRIVATE_OWNER_EVIDENCE='+$evidence)
