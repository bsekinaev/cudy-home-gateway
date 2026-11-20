# Offline native argument-boundary regression: fake ssh.exe never opens a socket.
param([Parameter(Mandatory=$true)][string]$CommandFile)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('cudy-dns-native-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$previousPath=$env:PATH
$previousCapture=$env:HG_DNS_TEST_COMMAND_FILE
$sessionFile=Join-Path $root 'session.json'
$reportFile=Join-Path $root 'report.txt'
$exe=Join-Path $root 'ssh.exe'
try {
    Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public class CaptureSSH {
    public static void Main(string[] args) {
        string path = Environment.GetEnvironmentVariable("HG_DNS_TEST_COMMAND_FILE");
        string command = args[args.Length-1];
        File.WriteAllText(path, command, new UTF8Encoding(false));
        if (command.Length > 9000) { Console.Error.WriteLine("fixture: exec command exceeds Dropbear limit"); Environment.Exit(255); }
        using (var input = Console.OpenStandardInput())
        using (var file = File.Create(path + ".stdin")) { input.CopyTo(file); }
        Console.WriteLine("HG_DNS_DISCOVERY_V1\nprofile=acl_A2dNs\nbusybox_version=1.37.0\nnslookup_A=supported\ntimeout_kill=supported\nbusybox_awk=supported\nrouter_dns_port=53\nruntime_dns=[]\nnetwork_changes=none");
    }
}
'@
    $env:PATH=$root+';'+$previousPath
    $env:HG_DNS_TEST_COMMAND_FILE=[IO.Path]::GetFullPath($CommandFile)
    @{format='HG_OWNER_SERIES_SESSION_V1';target='root@fixture.invalid';port=22} |
        ConvertTo-Json | Set-Content -LiteralPath $sessionFile -Encoding UTF8
    & (Join-Path $PSScriptRoot 'check-dns.ps1') -SessionFile $sessionFile -ReportFile $reportFile
    $remote=[IO.File]::ReadAllText($CommandFile)
    if ($remote -cne 'sh -s -- acl_A2dNs') { throw 'Native transport must send a short command' }
    $payload=[IO.File]::ReadAllText($CommandFile+'.stdin')
    $expected=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-dns-preflight.sh')).Replace("`r`n","`n")
    if ($payload.Contains("`r") -and $payload.TrimEnd("`r","`n").Contains("`r")) { throw 'CR inside shell payload' }
    if ($payload.TrimEnd("`r","`n") -cne $expected.TrimEnd("`n")) { throw 'Native stdin differs from script' }
    Write-Host 'DNS_NATIVE_TRANSPORT_TEST=PASS (fake ssh.exe; no network)'
} finally {
    $env:PATH=$previousPath
    $env:HG_DNS_TEST_COMMAND_FILE=$previousCapture
    foreach ($path in @($exe,$sessionFile,$reportFile)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    [IO.Directory]::Delete($root)
}
