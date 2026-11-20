# Windows PowerShell 5.1; fake SSH boundary, no router connection.
$ErrorActionPreference='Stop'
$taskDir=Join-Path ([IO.Path]::GetTempPath()) ('cudy-monitor-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($taskDir) | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$source='1111111111111111111111111111111111111111'
$runner=Join-Path $taskDir 'check-monitor.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'check-monitor.ps1') -Destination $runner
[IO.File]::WriteAllText((Join-Path $taskDir 'SOURCE.txt'),$source,$utf8)
[IO.File]::WriteAllText((Join-Path $taskDir 'router-monitor-probe.sh'),"echo fixture`n",$utf8)
$session=Join-Path $taskDir 'session.json'; $report=Join-Path $taskDir 'report.txt'
$global:MonitorArgs=@(); $global:MonitorInput=''; $global:MonitorCalls=0
$global:MonitorCode=0
$valid=@{schema_version=1;source_commit=$source;capabilities=@{timeout=$true;setsid_functional=$true};elapsed_seconds=2.5;memory_available_before_kib=200000;memory_available_after_kib=199000;health_exit=1;health=@{schema_version=1}}
$global:MonitorReply=@('HG_MONITOR_READINESS_V1') + @($valid | ConvertTo-Json -Depth 5)
function global:ssh {
    $global:MonitorCalls++
    $global:MonitorArgs=@($args)
    $global:MonitorInput=@($input) -join ""
    $global:LASTEXITCODE=$global:MonitorCode
    $global:MonitorReply
}
try {
    @{format='HG_OWNER_SERIES_SESSION_V1';target='root@fixture.invalid';port=22} | ConvertTo-Json | Set-Content -LiteralPath $session -Encoding UTF8
    & $runner -SessionFile $session -ReportFile $report
    if ($global:MonitorCalls -ne 1 -or $global:MonitorArgs[-1] -cne 'timeout -k 1 45 sh -s --') { throw 'Wrong remote transport' }
    if ($global:MonitorInput -cne "echo fixture`n") { throw 'Stdin payload differs' }
    if ((Get-Content -LiteralPath $report)[0] -cne 'HG_MONITOR_READINESS_V1') { throw 'Report missing' }
    $valid.source_commit='2222222222222222222222222222222222222222'
    $global:MonitorReply=@('HG_MONITOR_READINESS_V1')+@($valid|ConvertTo-Json -Depth 5)
    $refused=$false
    try { & $runner -SessionFile $session -ReportFile $report } catch { $refused=$true }
    if (!$refused) { throw 'Mismatched source accepted' }
    @{format='HG_OWNER_SERIES_SESSION_V1';target='root@bad;command';port=22} | ConvertTo-Json | Set-Content -LiteralPath $session -Encoding UTF8
    $before=$global:MonitorCalls; $refused=$false
    try { & $runner -SessionFile $session -ReportFile $report } catch { $refused=$true }
    if (!$refused -or $global:MonitorCalls -ne $before) { throw 'Invalid target reached SSH' }
    Write-Host 'MONITOR_RUNNER_TEST=PASS (Windows 5.1, fake SSH only)'
} finally {
    Remove-Item Function:\ssh -ErrorAction SilentlyContinue
    foreach($path in @($runner,$session,$report,(Join-Path $taskDir 'SOURCE.txt'),(Join-Path $taskDir 'router-monitor-probe.sh'))) {
        if(Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    [IO.Directory]::Delete($taskDir)
}
