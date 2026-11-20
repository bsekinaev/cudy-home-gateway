# Run explicitly by the owner. Reads connection identity; never invokes updater.
[CmdletBinding()]
param(
    [string]$SessionFile=(Join-Path $env:USERPROFILE 'CUDY-Update-20261119-fb8d9e3/owner-session.json'),
    [ValidatePattern('^[A-Za-z0-9_]+$')][string]$Profile='acl_A2dNs',
    [string]$ReportFile=(Join-Path $env:USERPROFILE ('CUDY-REDMI-Probe-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt'))
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
$scriptPath=Join-Path $PSScriptRoot 'router-redmi-probe.sh'
$text=[IO.File]::ReadAllText($scriptPath).Replace("`r`n","`n")
# Keep the SSH exec request short; send the script separately on stdin.
$remote="sh -s -- $Profile"
Write-Host 'Checking router DNS and the REDMI profile; no installation or network changes.'
$previousOutputEncoding=$OutputEncoding
try {
    $OutputEncoding=New-Object Text.UTF8Encoding($false)
    $report=@($text | & ssh -T -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p $session.port $session.target $remote)
    $sshExit=$LASTEXITCODE
} finally { $OutputEncoding=$previousOutputEncoding }
if ($sshExit -ne 0) { throw "SSH discovery failed (exit $sshExit). No updater stage was invoked." }
if ($report.Count -ne 2 -or $report[0] -cne 'HG_REDMI_DNS_TEST_V1') { throw 'Incomplete or unexpected REDMI probe response.' }
if ($report[1].Length -gt 4096) { throw 'Oversized REDMI probe response.' }
$data=ConvertFrom-Json -InputObject $report[1]
$expected=@('profile','router_dns_state','redmi_config_state','redmi_xray_state','redmi_policy_state','redmi_killswitch_state','redmi_dns_state','redmi_dns_reason','redmi_dns_port','redmi_dns_source','client_internet')
if ((@($data.PSObject.Properties.Name | Sort-Object) -join ',') -cne (@($expected | Sort-Object) -join ',')) { throw 'Unexpected REDMI probe fields.' }
if ($data.profile -cne $Profile -or $data.client_internet -cne 'unverified') { throw 'Invalid REDMI probe identity.' }
foreach ($field in @('router_dns_state','redmi_config_state','redmi_xray_state','redmi_policy_state','redmi_killswitch_state','redmi_dns_state')) {
    if ($data.$field -cnotmatch '^(OK|DEGRADED|DOWN|UNKNOWN|MAINTENANCE)$') { throw 'Invalid probe state.' }
}
if ($data.redmi_dns_reason -cnotmatch '^(answer|query_failed|profile_unavailable|tool_unavailable|runtime_unverified|runtime_changed|invalid_endpoint|invalid_domain)$' -or
    $data.redmi_dns_source -cnotmatch '^(live_probe|unverified)$') { throw 'Invalid probe evidence.' }
if ($null -ne $data.redmi_dns_port -and
    (($data.redmi_dns_port -isnot [int] -and $data.redmi_dns_port -isnot [long]) -or $data.redmi_dns_port -lt 1 -or $data.redmi_dns_port -gt 65535)) { throw 'Invalid probe port.' }
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllLines($ReportFile,[string[]]$report,$utf8)
$report | ForEach-Object { Write-Host $_ }
Write-Host ('REPORT='+$ReportFile)
