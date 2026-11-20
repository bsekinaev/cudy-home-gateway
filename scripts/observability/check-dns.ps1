# Run explicitly by the owner. Reads connection identity; never invokes updater.
[CmdletBinding()]
param(
    [string]$SessionFile=(Join-Path $env:USERPROFILE 'CUDY-Update-20261119-fb8d9e3/owner-session.json'),
    [ValidatePattern('^[A-Za-z0-9_]+$')][string]$Profile='acl_A2dNs',
    [string]$ReportFile=(Join-Path $env:USERPROFILE ('CUDY-DNS-Discovery-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt'))
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
$scriptPath=Join-Path $PSScriptRoot 'router-dns-preflight.sh'
$text=[IO.File]::ReadAllText($scriptPath).Replace("`r`n","`n")
# POSIX shell printf is sufficient; target BusyBox need not include base64.
$encoded=(@([Text.Encoding]::UTF8.GetBytes($text) | ForEach-Object {
    '\0'+[Convert]::ToString($_,8).PadLeft(3,'0')
}) -join '')
$remote="printf '%b' '$encoded' | sh -s -- '$Profile'"
if ($remote.Length -gt 28000) { throw 'Discovery script exceeds Windows transport budget.' }
Write-Host 'Reading DNS capabilities and REDMI endpoint; network settings stay unchanged.'
$report=@(& ssh -T -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p $session.port $session.target $remote)
if ($LASTEXITCODE -ne 0) { throw 'SSH discovery failed. No updater stage was invoked.' }
if ($report.Count -eq 0 -or $report[0] -cne 'HG_DNS_DISCOVERY_V1') { throw 'Unexpected discovery response.' }
if ($report.Count -ne 9) { throw 'Incomplete discovery response.' }
$fields=@{}
foreach ($line in $report[1..8]) {
    if ($line.Length -gt 4096 -or $line -notmatch '^([A-Za-z_]+)=(.*)$' -or $fields.ContainsKey($Matches[1])) {
        throw 'Unexpected discovery field.'
    }
    $fields[$Matches[1]]=$Matches[2]
}
foreach ($key in @('profile','busybox_version','nslookup_A','timeout_kill','busybox_awk','router_dns_port','network_changes')) {
    if (!$fields.ContainsKey($key)) { throw 'Missing discovery field.' }
}
if ($fields.profile -cne $Profile -or $fields.network_changes -cne 'none' -or
    $fields.busybox_version -cnotmatch '^(unknown|[0-9]+\.[0-9]+\.[0-9]+)$') { throw 'Invalid discovery identity.' }
foreach ($key in @('nslookup_A','timeout_kill','busybox_awk')) {
    if ($fields[$key] -cnotmatch '^(supported|unsupported)$') { throw 'Invalid capability field.' }
}
$dnsPort=$fields.router_dns_port
if ($dnsPort -cnotmatch '^(disabled|invalid|unavailable)$' -and
    ($dnsPort -cnotmatch '^[1-9][0-9]{0,4}$' -or [int]$dnsPort -gt 65535)) { throw 'Invalid DNS port field.' }
if ($fields.ContainsKey('runtime')) {
    if ($fields.runtime -cne 'unreadable_or_unsupported') { throw 'Invalid runtime outcome.' }
} elseif ($fields.ContainsKey('runtime_dns')) {
    if ($fields.runtime_dns -cnotmatch '^\s*\[.*\]\s*$') { throw 'Expected runtime endpoint array.' }
    $parsedEndpoints=ConvertFrom-Json -InputObject $fields.runtime_dns
    $endpoints=@()
    if ($null -ne $parsedEndpoints) { $endpoints=@($parsedEndpoints) }
    if ($endpoints.Count -gt 16) { throw 'Too many runtime endpoints.' }
    foreach ($endpoint in $endpoints) {
        $names=@($endpoint.PSObject.Properties.Name | Sort-Object)
        if (($names -join ',') -cne 'loopback,port,protocol' -or
            $endpoint.loopback -isnot [bool] -or
            $endpoint.protocol -cnotmatch '^(dokodemo-door|tunnel|unsupported)$' -or
            ($null -ne $endpoint.port -and
             (($endpoint.port -isnot [int] -and $endpoint.port -isnot [long]) -or $endpoint.port -lt 1 -or $endpoint.port -gt 65535))) {
            throw 'Invalid runtime endpoint.'
        }
    }
} else { throw 'Missing runtime outcome.' }
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllLines($ReportFile,[string[]]$report,$utf8)
$report | ForEach-Object { Write-Host $_ }
Write-Host ('REPORT='+$ReportFile)
