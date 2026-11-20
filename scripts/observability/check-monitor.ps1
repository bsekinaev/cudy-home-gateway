# Owner-run read-only readiness discovery; never invokes the updater.
[CmdletBinding()]
param(
    [string]$SessionFile=(Join-Path $env:USERPROFILE 'CUDY-Update-20261120-62b5c4a/owner-session.json'),
    [string]$ReportFile=(Join-Path $env:USERPROFILE ('CUDY-Monitor-Readiness-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt'))
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$session=Get-Content -LiteralPath $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($session.format -cne 'HG_OWNER_SERIES_SESSION_V1' -or
    $session.target -cnotmatch '^root@[A-Za-z0-9][A-Za-z0-9.-]{0,126}$' -or
    ($session.port -isnot [int] -and $session.port -isnot [long]) -or
    $session.port -lt 1 -or $session.port -gt 65535) {
    throw 'Unsupported connection identity. No SSH command was run.'
}
$source=([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'SOURCE.txt'))).Trim()
if ($source -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid package source identity.' }
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-monitor-probe.sh')).Replace("`r`n","`n")
$remote='timeout -k 1 45 sh -s --'
Write-Host 'Checking monitoring readiness and resources; this performs DNS/HTTPS checks without installation.'
$previousOutputEncoding=$OutputEncoding
try {
    $OutputEncoding=New-Object Text.UTF8Encoding($false)
    $report=@($text | & ssh -T -o ConnectTimeout=10 -o ServerAliveInterval=6 -o ServerAliveCountMax=10 -p $session.port $session.target $remote)
    $sshExit=$LASTEXITCODE
} finally { $OutputEncoding=$previousOutputEncoding }
$utf8=New-Object Text.UTF8Encoding($false)
if ($sshExit -ne 0) {
    [IO.File]::WriteAllLines($ReportFile,[string[]]$report,$utf8)
    Write-Host ('REPORT='+$ReportFile)
    Write-Error "Readiness SSH probe failed (exit $sshExit). No updater stage was invoked." -ErrorAction Continue
    exit $sshExit
}
if ($report.Count -lt 2 -or $report[0] -cne 'HG_MONITOR_READINESS_V1') { throw 'Incomplete or unexpected monitoring response.' }
$json=($report[1..($report.Count-1)] -join "`n")
if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 65536) { throw 'Oversized monitoring response.' }
$data=ConvertFrom-Json -InputObject $json
$expected=@('schema_version','source_commit','capabilities','elapsed_seconds','memory_available_before_kib','memory_available_after_kib','health_exit','health')
if ((@($data.PSObject.Properties.Name | Sort-Object) -join ',') -cne (@($expected | Sort-Object) -join ',')) { throw 'Unexpected monitoring fields.' }
if ($data.schema_version -ne 1 -or $data.source_commit -cne $source) { throw 'Monitoring source identity mismatch.' }
if ((@($data.capabilities.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'setsid_functional,timeout' -or
    $data.capabilities.timeout -isnot [bool] -or $data.capabilities.setsid_functional -isnot [bool]) { throw 'Invalid capability evidence.' }
if ($data.health_exit -notin @(0,1) -or $null -eq $data.health -or $data.health.schema_version -ne 1) { throw 'Incomplete health evidence.' }
foreach ($name in @('elapsed_seconds','memory_available_before_kib','memory_available_after_kib')) {
    $value=$data.$name
    if ($null -eq $value -or ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) -or $value -lt 0) {
        throw 'Invalid resource measurement.'
    }
}
[IO.File]::WriteAllLines($ReportFile,[string[]]$report,$utf8)
$report | ForEach-Object { Write-Host $_ }
Write-Host ('REPORT='+$ReportFile)
