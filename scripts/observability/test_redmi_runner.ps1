# Offline test; generated candidate package directory is required, never SSH.
param([Parameter(Mandatory=$true)][string]$ProbeDirectory)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('cudy-redmi-runner-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$sessionFile=Join-Path $root 'session.json'
$reportFile=Join-Path $root 'report.txt'
$global:HGRedmiProbeCalls=0
$data=@{profile='acl_A2dNs';router_dns_state='OK';redmi_config_state='OK';redmi_xray_state='OK';redmi_policy_state='OK';redmi_killswitch_state='OK';redmi_dns_state='DOWN';redmi_dns_reason='query_failed';redmi_dns_port=2004;redmi_dns_source='live_probe';client_internet='unverified'}
$global:HGRedmiProbeReply=@('HG_REDMI_DNS_TEST_V1',($data | ConvertTo-Json -Compress))
function global:ssh {
    $global:HGRedmiProbeCalls++
    $null=@($input)
    if ($args[-1] -cne 'sh -s -- acl_A2dNs') { throw 'Unexpected remote command' }
    $global:LASTEXITCODE=0
    $global:HGRedmiProbeReply
}
try {
    @{format='HG_OWNER_SERIES_SESSION_V1';target='root@fixture.invalid';port=22} |
        ConvertTo-Json | Set-Content -LiteralPath $sessionFile -Encoding UTF8
    $runner=Join-Path $ProbeDirectory 'check-redmi.ps1'
    & $runner -SessionFile $sessionFile -ReportFile $reportFile
    if ($global:HGRedmiProbeCalls -ne 1) { throw 'Unexpected SSH call count' }
    $saved=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $reportFile)[1]
    if ($saved.redmi_dns_state -cne 'DOWN' -or $saved.client_internet -cne 'unverified') { throw 'Report changed evidence' }
    $data.private='DO_NOT_PRINT'
    $global:HGRedmiProbeReply=@('HG_REDMI_DNS_TEST_V1',($data | ConvertTo-Json -Compress))
    $refused=$false
    try { & $runner -SessionFile $sessionFile -ReportFile $reportFile } catch { $refused=$true }
    if (!$refused) { throw 'Unexpected private field was accepted' }
    Write-Host 'REDMI_RUNNER_TEST=PASS (offline)'
} finally {
    Remove-Item Function:\ssh -ErrorAction SilentlyContinue
    foreach ($path in @($sessionFile,$reportFile)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    [IO.Directory]::Delete($root)
}
