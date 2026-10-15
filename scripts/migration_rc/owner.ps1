# Delivery A only; compatible with Windows PowerShell 5.1 and PowerShell 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Target,
    [Parameter(Mandatory=$true)][string]$BundleUrl,
    [Parameter(Mandatory=$true)][string]$BundleSha256,
    [Parameter(Mandatory=$true)][string]$SessionFile,
    [ValidateSet('Preflight','Prepare','Apply','Verify','Rollback','All')][string]$Stage='Preflight'
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
if ($Target -notmatch '^root@[A-Za-z0-9][A-Za-z0-9.-]{0,126}$') { throw 'Invalid SSH target; use root@host or root@IPv4.' }
if ($BundleSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Expected a pinned lowercase SHA256.' }
if ($BundleUrl -notmatch '^https://raw\.githubusercontent\.com/bsekinaev/cudy-home-gateway/[0-9a-f]{40}/artifacts/[A-Za-z0-9_./-]+\.tar\.gz$' -or $BundleUrl.Contains('..')) { throw 'Use an immutable commit-pinned RC A URL.' }
foreach ($name in @('ssh','scp','tar')) { $null=Get-Command $name -ErrorAction Stop }
$SessionFile=[IO.Path]::GetFullPath($SessionFile)
$parent=Split-Path -Parent $SessionFile
$null=New-Item -ItemType Directory -Force -Path $parent
$cache=Join-Path $parent ('rc-a-'+$BundleSha256+'.tar.gz')
if (!(Test-Path -LiteralPath $cache)) {
    $part=$cache+'.'+[guid]::NewGuid().ToString('N')+'.part'
    Invoke-WebRequest -UseBasicParsing -Uri $BundleUrl -OutFile $part
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $part).Hash.ToLowerInvariant() -ne $BundleSha256) { throw "Download SHA256 mismatch; preserved $part" }
    Move-Item -LiteralPath $part -Destination $cache
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $cache).Hash.ToLowerInvariant() -ne $BundleSha256) { throw 'Cached archive SHA256 mismatch; STOP.' }
$raw=@(& tar -xOzf $cache manifest.json)
if ($LASTEXITCODE -ne 0) { throw 'Cannot read archive manifest.' }
$manifest=($raw -join "`n") | ConvertFrom-Json
if ($manifest.format -ne 'HGDEPLOY2_RC_A_V1' -or $manifest.delivery -ne 'A_ISOLATED_ONLY' -or $manifest.production_apply -ne $false -or $manifest.source_commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid Delivery A manifest.' }
$source=$manifest.source_commit
if (Test-Path -LiteralPath $SessionFile) {
    $session=Get-Content -Raw -LiteralPath $SessionFile | ConvertFrom-Json
    if ($session.format -ne 'HG_RC_A_SESSION_V1' -or $session.scope -ne 'ISOLATED_TMP' -or $session.target -ne $Target -or $session.source -ne $source -or $session.bundleSha256 -ne $BundleSha256) { throw 'Session identity mismatch; STOP.' }
} else {
    $session=[pscustomobject]@{format='HG_RC_A_SESSION_V1';scope='ISOLATED_TMP';target=$Target;source=$source;bundleSha256=$BundleSha256;uploadRoot=$null;remoteKit=$null;lab=$null;preflightPassed=$false}
}
if (!$session.PSObject.Properties['preflightPassed']) { $session | Add-Member -NotePropertyName preflightPassed -NotePropertyValue $false }
function Save-Session {
    $temp=$SessionFile+'.'+[guid]::NewGuid().ToString('N')+'.new'
    $session | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $temp
    Move-Item -Force -LiteralPath $temp -Destination $SessionFile
}
$sshOptions=@('-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2')
function Invoke-Remote([string]$Command) {
    $lines=@(& ssh @sshOptions $Target $Command)
    $code=$LASTEXITCODE
    foreach ($line in $lines) { Write-Host $line }
    return [pscustomobject]@{Lines=$lines;ExitCode=$code}
}
function Require-Success($Result) { if ($Result.ExitCode -ne 0) { throw ('SSH stage failed with exit '+$Result.ExitCode) } }
function Require-Kit {
    if ($session.remoteKit -notmatch '^/tmp/hgdeploy2-rc-a-kit\.[A-Za-z0-9]{6}/kit$') { throw 'Run Preflight first; no verified remote kit.' }
}
function Require-Lab {
    Require-Kit
    if ($session.lab -notmatch '^/tmp/hgdeploy2-rc-a\.[A-Za-z0-9]{6}$') { throw 'No identified isolated lab; inspect preparation output. Never guess a path.' }
}
function Run-Stage([string]$Name) {
    Write-Host ('RC_A_STAGE='+$Name+' SOURCE='+$source+' PRODUCTION_APPLY=BLOCKED')
    if ($Name -eq 'Preflight') {
        $session.preflightPassed=$false;Save-Session
        if (!$session.remoteKit) {
            if ($session.uploadRoot) { throw 'Previous upload was interrupted. Preserve it; use a new session file for a fresh upload.' }
            $r=Invoke-Remote 'umask 077; mktemp -d /tmp/hgdeploy2-rc-a-kit.XXXXXX'
            Require-Success $r
            $roots=@($r.Lines | Where-Object { $_ -match '^/tmp/hgdeploy2-rc-a-kit\.[A-Za-z0-9]{6}$' })
            if ($roots.Count -ne 1) { throw 'No unique upload directory.' }
            $session.uploadRoot=[string]$roots[0];Save-Session
            $archive=$session.uploadRoot+'/bundle.tar.gz';$kit=$session.uploadRoot+'/kit'
            & scp -O @sshOptions $cache ($Target+':'+$archive)
            if ($LASTEXITCODE -ne 0) { throw 'SCP failed; no extraction or apply was attempted.' }
            $command='actual=$(sha256sum '+$archive+'); test "${actual%% *}" = '+$BundleSha256+' && mkdir -m 700 '+$kit+' && tar -xzpf '+$archive+' -C '+$kit
            $r=Invoke-Remote $command;Require-Success $r
            $session.remoteKit=$kit;Save-Session
        }
        Require-Kit
        $r=Invoke-Remote ('sh '+$session.remoteKit+'/rc-a.sh preflight');Require-Success $r
        $session.preflightPassed=$true;Save-Session
    } elseif ($Name -eq 'Prepare') {
        Require-Kit
        if ($session.preflightPassed -ne $true) { throw 'Successful Preflight is required before Prepare.' }
        if ($session.lab) { throw 'Lab already exists; do not replay Prepare. Use Verify or explicit Rollback.' }
        $r=Invoke-Remote ('sh '+$session.remoteKit+'/rc-a.sh prepare')
        $labs=@($r.Lines | Where-Object { $_ -match '^RC_LAB=/tmp/hgdeploy2-rc-a\.[A-Za-z0-9]{6}$' })
        if ($labs.Count -eq 1) { $session.lab=([string]$labs[0]).Substring(7);Save-Session }
        Require-Success $r
        Require-Lab
    } else {
        Require-Lab
        $r=Invoke-Remote ('sh '+$session.remoteKit+'/rc-a.sh '+$Name.ToLowerInvariant()+' '+$session.lab)
        Require-Success $r
    }
    Write-Host ('RC_A_STAGE='+$Name+' RESULT=PASS SCOPE=ISOLATED_TMP PRODUCTION_APPLY=BLOCKED')
}
try {
    Save-Session
    if ($Stage -eq 'All') { foreach ($item in @('Preflight','Prepare','Apply','Verify')) { Run-Stage $item } }
    else { Run-Stage $Stage }
    Write-Host ('RC_A_RESULT=PASS SESSION='+$SessionFile+' PRODUCTION_MIGRATION=BLOCKED')
} catch {
    Write-Host 'RC_A_RESULT=STOP; no automatic rollback or replay. Production apply is unavailable.'
    Write-Host ('Keep session: '+$SessionFile)
    if ($session.lab) { Write-Host ('For this identified isolated lab, run the same command with -Stage Rollback: '+$session.lab) }
    throw
}
