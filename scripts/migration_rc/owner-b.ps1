# HGDEPLOY2 RC-B 20261020.1 — verified retirement before a fresh transaction.
# Explicit owner stages, Windows PowerShell 5.1 / PowerShell 7. No automatic Apply.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$Target,
 [Parameter(Mandatory=$true)][string]$BundleUrl,
 [Parameter(Mandatory=$true)][string]$BundleSha256,
 [Parameter(Mandatory=$true)][string]$SessionFile,
 [ValidateSet('Preflight','Prepare','Apply','Verify','Rollback','UploadRecovery','Retire','RetireCheck')][string]$Stage='Preflight',
 [string]$PreviousSessionFile,
 [switch]$RetirementConfirmed,
 [switch]$RecoveryPathConfirmed
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
if ($Target -notmatch '^root@[A-Za-z0-9][A-Za-z0-9.-]{0,126}$') { throw 'Invalid SSH target.' }
if ($BundleSha256 -notmatch '^[0-9a-f]{64}$') { throw 'A pinned lowercase SHA256 is required.' }
if ($BundleUrl -notmatch '^https://raw\.githubusercontent\.com/bsekinaev/cudy-home-gateway/[0-9a-f]{40}/artifacts/[A-Za-z0-9_./-]+\.tar\.gz$' -or $BundleUrl.Contains('..')) { throw 'Use the published immutable RC-B URL.' }
foreach ($name in @('ssh','scp','tar')) { $null=Get-Command $name -ErrorAction Stop }
$SessionFile=[IO.Path]::GetFullPath($SessionFile);$parent=Split-Path -Parent $SessionFile
$null=New-Item -ItemType Directory -Force -Path $parent
$cache=Join-Path $parent ('rc-b-'+$BundleSha256+'.tar.gz')
if (!(Test-Path -LiteralPath $cache)) {
 $part=$cache+'.'+[guid]::NewGuid().ToString('N')+'.part'
 Invoke-WebRequest -UseBasicParsing -Uri $BundleUrl -OutFile $part
 if ((Get-FileHash -Algorithm SHA256 -LiteralPath $part).Hash.ToLowerInvariant() -ne $BundleSha256) { throw 'Downloaded SHA256 mismatch; STOP.' }
 Move-Item -LiteralPath $part -Destination $cache
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $cache).Hash.ToLowerInvariant() -ne $BundleSha256) { throw 'Cached SHA256 mismatch; STOP.' }
$inspect=Join-Path ([IO.Path]::GetTempPath()) ('hg-rc-b-manifest-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $inspect
try {
 & tar -xzf $cache -C $inspect manifest.json
 if ($LASTEXITCODE -ne 0) { throw 'Cannot read manifest.' }
 $file=Join-Path $inspect 'manifest.json'
 $manifest=Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
 $manifestPin=(Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
} finally { Remove-Item -LiteralPath $inspect -Recurse -Force }
if ($manifest.format -ne 'HGDEPLOY2_RC_B_V1' -or $manifest.delivery -ne 'B_OWNER_MANUAL' -or $manifest.production_apply -ne $true -or $manifest.source_commit -notmatch '^[0-9a-f]{40}$') { throw 'This is not an accepted owner RC-B. VM/blocked packages cannot install on CUDY.' }
$source=$manifest.source_commit
if (Test-Path -LiteralPath $SessionFile) {
 $session=Get-Content -Raw -LiteralPath $SessionFile | ConvertFrom-Json
 if ($session.format -ne 'HG_RC_B_SESSION_V1' -or $session.target -ne $Target -or $session.source -ne $source -or $session.bundleSha256 -ne $BundleSha256 -or $session.manifestSha256 -ne $manifestPin) { throw 'Session identity mismatch; STOP.' }
} else {
 $session=[pscustomobject]@{format='HG_RC_B_SESSION_V1';target=$Target;source=$source;bundleSha256=$BundleSha256;manifestSha256=$manifestPin;remoteKit=$null;uploadRoot=$null;transaction=$null;preflightPassed=$false;prepared=$false;applyAttempted=$false;retirementTransaction=$null;retirementAttempted=$false;retirementPassed=$false;retirementChecked=$false}
}
function Save-Session {
 $tmp=$SessionFile+'.'+[guid]::NewGuid().ToString('N')+'.new'
 $session | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $tmp
 Move-Item -Force -LiteralPath $tmp -Destination $SessionFile
}
$sshOptions=@('-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2')
function Remote([string]$Command) {
 $lines=@(& ssh @sshOptions $Target $Command);$code=$LASTEXITCODE
 foreach ($line in $lines) { Write-Host $line }
 return [pscustomobject]@{Lines=$lines;ExitCode=$code}
}
function Success($Result) { if ($Result.ExitCode -ne 0) { throw ('SSH stage failed with exit '+$Result.ExitCode+'. No automatic apply/rollback. Preserve session; use UploadRecovery then Rollback if the kit was lost.') } }
function Require-Kit {
 if ($session.remoteKit -notmatch '^/tmp/hgdeploy2-rc-b-kit\.[A-Za-z0-9]{6}/kit$') { throw 'No verified kit; use Preflight or UploadRecovery.' }
}
function Require-Transaction {
 if ($session.transaction -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'No captured transaction; do not guess/adopt router state. Inspect the preserved preparation output.' }
}
function Upload-Kit {
 $r=Remote 'umask 077; mktemp -d /tmp/hgdeploy2-rc-b-kit.XXXXXX';Success $r
 $roots=@($r.Lines | Where-Object { $_ -match '^/tmp/hgdeploy2-rc-b-kit\.[A-Za-z0-9]{6}$' })
 if ($roots.Count -ne 1) { throw 'No unique upload directory.' }
 $session.uploadRoot=[string]$roots[0];Save-Session
 $archive=$session.uploadRoot+'/bundle.tar.gz';$kit=$session.uploadRoot+'/kit'
 & scp -O @sshOptions $cache ($Target+':'+$archive)
 if ($LASTEXITCODE -ne 0) { throw 'SCP failed; target installation was not started.' }
 $r=Remote ('actual=$(sha256sum '+$archive+'); test "${actual%% *}" = '+$BundleSha256+' && mkdir -m 700 '+$kit+' && tar -xzpf '+$archive+' -C '+$kit);Success $r
 $r=Remote ('sh '+$kit+'/rc-b.sh check '+$manifestPin);Success $r
 $session.remoteKit=$kit;Save-Session
}
if ($Stage -eq 'UploadRecovery') {
 if ($session.transaction) { Require-Transaction }
 elseif (!$session.retirementAttempted -or $session.retirementTransaction -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'No recorded transaction or retirement attempt; do not adopt router state.' }
 Upload-Kit
 if ($session.transaction) { Write-Host 'RC_B_RECOVERY_KIT=VERIFIED. Run Rollback explicitly; no Apply was run.' } else { Write-Host 'RC_B_RECOVERY_KIT=VERIFIED. Resume Retire with the original PreviousSessionFile; no Apply was run.' }
 exit 0
}
if ($Stage -eq 'Retire' -or $Stage -eq 'RetireCheck') {
 if (!$PreviousSessionFile -or $session.transaction -or $session.applyAttempted) { throw 'Retire requires confirmed recovery, explicit RetirementConfirmed, the old session, and no new transaction.' }
 $oldPath=[IO.Path]::GetFullPath($PreviousSessionFile)
 if ([String]::Equals($oldPath,$SessionFile,[StringComparison]::OrdinalIgnoreCase)) { throw 'Old and new session must be separate; preserve the old session.' }
 $old=Get-Content -Raw -LiteralPath $oldPath | ConvertFrom-Json
 if ($old.format -ne 'HG_RC_B_SESSION_V1' -or $old.target -ne $Target -or $old.source -ne '908dd3222b81992d9fee056bd015a1266a0ce8d7' -or $old.bundleSha256 -ne 'd10beec6bc376a819a04e51cff1b4c779f2f0e1dec0412f20b38c6d2100a8f56' -or $old.manifestSha256 -ne '67b65f1ceabe1534ff74fba8f6c486e9d02bfce9a7e7999875bd11929df467a1' -or $old.transaction -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Old session is not the pinned RC-B 20261019.2 transaction.' }
 if ($session.retirementTransaction -and $session.retirementTransaction -ne $old.transaction) { throw 'Retirement transaction mismatch; STOP.' }
 if ($Stage -eq 'RetireCheck') {
  $session.retirementTransaction=$old.transaction;$session.retirementChecked=$false;Save-Session
  if (!$session.remoteKit) { Upload-Kit }
  Require-Kit
  $r=Remote ('sh '+$session.remoteKit+'/rc-b.sh retire-check '+$manifestPin+' '+$old.transaction);Success $r
  $expected='RC_B_RETIREMENT_CHECK=PASS TRANSACTION='+$old.transaction+' ARCHIVE='
  if (@($r.Lines | Where-Object { $_.StartsWith($expected,[StringComparison]::Ordinal) }).Count -ne 1) { throw 'No retirement check receipt; STOP.' }
  $session.retirementChecked=$true;Save-Session
  Write-Host 'RC_B_OWNER_STAGE=RetireCheck RESULT=PASS. Read-only target check; review before explicit Retire.'
  exit 0
 }
 if (!$RecoveryPathConfirmed -or !$RetirementConfirmed -or !$session.retirementChecked) { throw 'Retire requires successful RetireCheck, RecoveryPathConfirmed and RetirementConfirmed.' }
 $session.retirementChecked=$false
 $session.retirementTransaction=$old.transaction;$session.retirementAttempted=$true;$session.retirementPassed=$false;$session.preflightPassed=$false;Save-Session
 if (!$session.remoteKit) { Upload-Kit }
 Require-Kit
 $r=Remote ('sh '+$session.remoteKit+'/rc-b.sh retire '+$manifestPin+' '+$old.transaction+' retire:'+$source+':'+$old.transaction);Success $r
 $expected='RC_B_RETIREMENT=PASS TRANSACTION='+$old.transaction+' ARCHIVE=/etc/home-gateway-migration.retired.'+$old.transaction
 if (@($r.Lines | Where-Object { $_ -ceq $expected }).Count -ne 1) { throw 'No exact retirement receipt; STOP and preserve session.' }
 $session.retirementPassed=$true;Save-Session
 Write-Host 'RC_B_OWNER_STAGE=Retire RESULT=PASS. Old evidence/session preserved; run fresh Preflight. No Apply was run.'
 exit 0
}
if ($Stage -eq 'Preflight') {
 if ($session.transaction) { throw 'An existing transaction must use Verify/Rollback; no reinstallation preflight.' }
 $session.preflightPassed=$false;Save-Session
 if (!$session.remoteKit) { Upload-Kit }
 Require-Kit
 $r=Remote ('sh '+$session.remoteKit+'/rc-b.sh preflight '+$manifestPin);Success $r
 $session.preflightPassed=$true;Save-Session
 Write-Host 'PREFLIGHT=PASS. Prepare changes deployment/boot state; confirm a WORKING recovery path before Prepare.'
 exit 0
}
Require-Kit
if ($Stage -eq 'Prepare') {
 if ($session.preflightPassed -ne $true -or $session.transaction) { throw 'A fresh successful Preflight is required; Prepare is never replayed.' }
 if (!$RecoveryPathConfirmed) { throw 'GO/NO-GO: a working recovery path is not confirmed. Physical Ethernet availability alone is insufficient.' }
 $r=Remote ('sh '+$session.remoteKit+'/rc-b.sh prepare '+$manifestPin)
 $ids=@($r.Lines | Where-Object { $_ -match '^RC_B_TRANSACTION=[0-9a-f-]{36} SOURCE=[0-9a-f]{40}$' })
 if ($ids.Count -eq 1 -and ([string]$ids[0]) -match ('^RC_B_TRANSACTION=([0-9a-f-]{36}) SOURCE='+$source+'$')) { $session.transaction=$Matches[1];Save-Session }
 Success $r;Require-Transaction
 $session.prepared=$true;Save-Session
 exit 0
}
Require-Transaction
if ($Stage -eq 'Apply') {
 if (!$RecoveryPathConfirmed -or $session.prepared -ne $true -or $session.applyAttempted -ne $false) { throw 'Apply requires confirmed recovery, completed Prepare and no previous Apply attempt. Use Verify/Rollback after interruption.' }
 $session.applyAttempted=$true;Save-Session
 $r=Remote ('sh '+$session.remoteKit+'/rc-b.sh apply '+$manifestPin+' '+$session.transaction+' '+$source+':'+$session.transaction)
} else {
 $r=Remote ('sh '+$session.remoteKit+'/rc-b.sh '+$Stage.ToLowerInvariant()+' '+$manifestPin+' '+$session.transaction)
}
Success $r
Write-Host ('RC_B_OWNER_STAGE='+$Stage+' RESULT=PASS SOURCE='+$source)
