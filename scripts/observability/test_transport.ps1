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
        File.WriteAllText(Environment.GetEnvironmentVariable("HG_DNS_TEST_COMMAND_FILE"), args[args.Length-1], new UTF8Encoding(false));
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
    if ($remote -notmatch "^printf '%b' '((?:\\0[0-7]{3})+)' \| sh -s -- 'acl_A2dNs'$") {
        throw 'Native argument transport corrupted the command'
    }
    $bytes=[byte[]]@(foreach ($octet in [regex]::Matches($Matches[1],'\\0([0-7]{3})')) {
        [Convert]::ToByte($octet.Groups[1].Value,8)
    })
    $expected=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-dns-preflight.sh')).Replace("`r`n","`n")
    if ([Text.Encoding]::UTF8.GetString($bytes) -cne $expected) { throw 'Native payload differs from script' }
    Write-Host 'DNS_NATIVE_TRANSPORT_TEST=PASS (fake ssh.exe; no network)'
} finally {
    $env:PATH=$previousPath
    $env:HG_DNS_TEST_COMMAND_FILE=$previousCapture
    foreach ($path in @($exe,$sessionFile,$reportFile)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    [IO.Directory]::Delete($root)
}
