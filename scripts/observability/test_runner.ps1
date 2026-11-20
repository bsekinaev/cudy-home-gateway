# Offline Windows PowerShell 5.1 contract. SSH is replaced before the runner runs.
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('cudy-dns-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$sessionFile=Join-Path $root 'session.json'
$reportFile=Join-Path $root 'report.txt'
$global:HGDiscoveryTestCalls=0
$global:HGDiscoveryTestArgs=@()
$global:HGDiscoveryTestReply=@('HG_DNS_DISCOVERY_V1','profile=acl_A2dNs',
    'busybox_version=1.37.0','nslookup_A=supported','timeout_kill=supported',
    'busybox_awk=supported','router_dns_port=53','runtime_dns=[]','network_changes=none')
function global:ssh {
    $global:HGDiscoveryTestCalls++
    $global:HGDiscoveryTestArgs=@($args)
    $global:LASTEXITCODE=0
    $global:HGDiscoveryTestReply
}
try {
    @{format='HG_OWNER_SERIES_SESSION_V1';target='root@fixture.invalid';port=22} |
        ConvertTo-Json | Set-Content -LiteralPath $sessionFile -Encoding UTF8
    & (Join-Path $PSScriptRoot 'check-dns.ps1') -SessionFile $sessionFile -ReportFile $reportFile
    if ($global:HGDiscoveryTestCalls -ne 1) { throw 'SSH not invoked exactly once' }
    if ((Get-Content -LiteralPath $reportFile)[0] -cne 'HG_DNS_DISCOVERY_V1') { throw 'Report missing' }
    if ($global:HGDiscoveryTestArgs -notcontains 'root@fixture.invalid') { throw 'Target identity lost' }
    $remote=[string]$global:HGDiscoveryTestArgs[-1]
    if ($remote -notmatch "^printf '%s' '([A-Za-z0-9+/=]+)' \| busybox base64 -d \| sh -s -- 'acl_A2dNs'$") {
        throw 'Unexpected remote command'
    }
    $decoded=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
    if (!$decoded.StartsWith('#!/bin/sh') -or $decoded.Contains("`r")) { throw 'Bad payload bytes' }
    @{format='HG_OWNER_SERIES_SESSION_V1';target='root@bad;touch';port=22} |
        ConvertTo-Json | Set-Content -LiteralPath $sessionFile -Encoding UTF8
    $refused=$false
    try { & (Join-Path $PSScriptRoot 'check-dns.ps1') -SessionFile $sessionFile -ReportFile $reportFile }
    catch { $refused=$true }
    if (!$refused -or $global:HGDiscoveryTestCalls -ne 1) { throw 'Invalid target reached SSH' }
    @{format='HG_OWNER_SERIES_SESSION_V1';target='root@fixture.invalid';port=22} |
        ConvertTo-Json | Set-Content -LiteralPath $sessionFile -Encoding UTF8
    $global:HGDiscoveryTestReply[7]='runtime_dns=[{"port":2007,"loopback":true,"protocol":"dokodemo-door"}]'
    & (Join-Path $PSScriptRoot 'check-dns.ps1') -SessionFile $sessionFile -ReportFile $reportFile
    $global:HGDiscoveryTestReply[7]='runtime=unreadable_or_unsupported'
    & (Join-Path $PSScriptRoot 'check-dns.ps1') -SessionFile $sessionFile -ReportFile $reportFile
    foreach ($reply in @(@('HG_DNS_DISCOVERY_V1'),
                         @('HG_DNS_DISCOVERY_V1','unexpected=PRIVATE'))) {
        $global:HGDiscoveryTestReply=$reply
        $refused=$false
        try { & (Join-Path $PSScriptRoot 'check-dns.ps1') -SessionFile $sessionFile -ReportFile $reportFile }
        catch { $refused=$true }
        if (!$refused) { throw 'Incomplete or unexpected output was accepted' }
    }
    Write-Host 'DNS_RUNNER_TEST=PASS (offline; no real SSH)'
} finally {
    Remove-Item Function:\ssh -ErrorAction SilentlyContinue
    # Only exact files created above; no recursive filesystem operations.
    foreach ($path in @($sessionFile,$reportFile)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    [IO.Directory]::Delete($root)
}
