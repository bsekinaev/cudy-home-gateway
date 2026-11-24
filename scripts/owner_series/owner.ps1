# Explicit owner stages. Local authentication completes before any transport.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [Parameter(Mandatory=$true)][string]$BundleSha256,
    [Parameter(Mandatory=$true)][ValidatePattern('^root@[A-Za-z0-9][A-Za-z0-9.-]{0,126}$')][string]$Target,
    [Parameter(Mandatory=$true)][string]$SessionFile,
    [ValidateRange(1,65535)][int]$Port=22,
    [ValidateSet('Preflight','Apply','Verify','Rollback','Recover')][string]$Stage='Preflight',
    [switch]$ReserveAccessConfirmed
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'

function Get-Digest([byte[]]$Bytes) {
    $h=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($h.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $h.Dispose() }
}
function Initialize-ArchiveReader {
    if ('OwnerSeriesArchive' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Collections.Generic;
using System.Text.RegularExpressions;
public sealed class OwnerSeriesJson {
 string s; int p;
 OwnerSeriesJson(string text) { s=text; }
 void White() { while(p<s.Length && " \r\n\t".IndexOf(s[p])>=0) p++; }
 bool Take(char c) { White(); if(p<s.Length && s[p]==c) { p++; return true; } return false; }
 string Str() {
  White(); int start=p;
  if(p>=s.Length || s[p++]!='"') throw new Exception("JSON_STRING");
  while(p<s.Length) {
   char c=s[p++]; if(c=='"') return s.Substring(start,p-start);
   if(c<32) throw new Exception("JSON_CONTROL");
   if(c=='\\') {
    if(p>=s.Length) throw new Exception("JSON_ESCAPE"); c=s[p++];
    if(c=='u') { for(int i=0;i<4;i++) if(p>=s.Length || !Uri.IsHexDigit(s[p++])) throw new Exception("JSON_ESCAPE"); }
    else if("\"\\/bfnrt".IndexOf(c)<0) throw new Exception("JSON_ESCAPE");
   }
  }
  throw new Exception("JSON_STRING_END");
 }
 void Value(int depth) {
  if(depth>32) throw new Exception("JSON_DEPTH"); White();
  if(p>=s.Length) throw new Exception("JSON_VALUE");
  if(Take('{')) {
   if(Take('}')) return;
   do { Str(); if(!Take(':')) throw new Exception("JSON_COLON"); Value(depth+1); } while(Take(','));
   if(!Take('}')) throw new Exception("JSON_OBJECT"); return;
  }
  if(Take('[')) {
   if(Take(']')) return;
   do { Value(depth+1); } while(Take(','));
   if(!Take(']')) throw new Exception("JSON_ARRAY"); return;
  }
  if(s[p]=='"') { Str(); return; }
  var m=Regex.Match(s.Substring(p),"^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)");
  if(!m.Success) throw new Exception("JSON_LITERAL"); p+=m.Length;
 }
 public static void Validate(string text) { var j=new OwnerSeriesJson(text); j.Value(0); j.White(); if(j.p!=text.Length) throw new Exception("JSON_TRAILING"); }
}
public sealed class OwnerSeriesArchive : MemoryStream {
 public static void Publish(string temporary,string destination) {
  if(File.Exists(destination)) File.Replace(temporary,destination,null);
  else File.Move(temporary,destination);
 }
 public OwnerSeriesArchive(byte[] b) : base(b, false) { Position=10; }
 public override int Read(byte[] b,int o,int n) { return base.Read(b,o,Math.Min(n,1)); }
 public static byte[] Expand(byte[] raw) {
  if(raw.Length<18 || raw[0]!=31 || raw[1]!=139 || raw[2]!=8 || raw[3]!=0) throw new Exception("ARCHIVE_GZIP_HEADER");
  using(var input=new OwnerSeriesArchive(raw)) using(var output=new MemoryStream()) {
   using(var d=new DeflateStream(input,CompressionMode.Decompress,true)) {
    byte[] b=new byte[8192]; int n;
    while((n=d.Read(b,0,b.Length))>0) { if(output.Length+n>8388608) throw new Exception("ARCHIVE_EXPANDED_SIZE"); output.Write(b,0,n); }
   }
   if(input.Position!=raw.Length-8) throw new Exception("ARCHIVE_GZIP_TRAILING");
   byte[] data=output.ToArray(); uint crc=0xffffffff;
   foreach(byte v in data) { crc^=v; for(int j=0;j<8;j++) crc=(crc>>1)^((crc&1)!=0?0xedb88320u:0u); }
   if((crc^0xffffffff)!=BitConverter.ToUInt32(raw,raw.Length-8) || (uint)data.Length!=BitConverter.ToUInt32(raw,raw.Length-4)) throw new Exception("ARCHIVE_GZIP_CRC");
   return data;
  }
 }
}
'@
}
function Get-Octal([byte[]]$Data,[int]$Offset,[int]$Length) {
    $s=[Text.Encoding]::ASCII.GetString($Data,$Offset,$Length)
    if ($s -cnotmatch '^[0-7]+[\x00 ]*$') { throw 'ARCHIVE_OCTAL' }
    return [Convert]::ToInt64($s.TrimEnd([char[]]@([char]0,' ')),8)
}
function Get-TarText([byte[]]$Data,[int]$Offset,[int]$Length) {
    $s=[Text.Encoding]::GetEncoding('us-ascii',[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback).GetString($Data,$Offset,$Length)
    if ($s -cnotmatch '^[^\x00]*(\x00*)$') { throw 'ARCHIVE_TEXT_PADDING' }
    return $s.TrimEnd([char]0)
}
function Assert-Zero([byte[]]$Data,[int]$Start,[int]$End) {
    for ($i=$Start;$i -lt $End;$i++) { if ($Data[$i] -ne 0) { throw 'ARCHIVE_NONZERO_PADDING' } }
}
function Read-Archive([string]$Path,[string]$Pin) {
    $file=Get-Item -LiteralPath $Path
    if ($file.Length -gt 8388608) { throw 'ARCHIVE_COMPRESSED_SIZE' }
    $inputStream=[IO.File]::OpenRead($file.FullName)
    try {
        $buffer=New-Object byte[] 8388609; $length=0
        while($length -lt $buffer.Length) { $read=$inputStream.Read($buffer,$length,$buffer.Length-$length); if(!$read) { break }; $length+=$read }
        if($length -gt 8388608) { throw 'ARCHIVE_COMPRESSED_SIZE' }
        $raw=New-Object byte[] $length; [Array]::Copy($buffer,$raw,$length)
    } finally { $inputStream.Dispose() }
    if ($Pin -cnotmatch '^[0-9a-f]{64}$' -or (Get-Digest $raw) -cne $Pin) { throw 'ARCHIVE_DIGEST' }
    Initialize-ArchiveReader
    $data=[OwnerSeriesArchive]::Expand($raw)
    if ($data.Length % 512) { throw 'ARCHIVE_ALIGNMENT' }
    $files=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $dirs=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $terminated=$false; $offset=0
    while ($offset -lt $data.Length) {
        $h=$offset; $nonzero=$false
        for($i=$h;$i -lt $h+512;$i++) { if($data[$i]) { $nonzero=$true; break } }
        if (!$nonzero) { if($data.Length-$h -lt 1024) { throw 'ARCHIVE_TERMINATOR' }; Assert-Zero $data $h $data.Length; $terminated=$true; break }
        if($seen.Count -ge 256) { throw 'ARCHIVE_ENTRY_COUNT' }
        $sum=256L
        for($i=0;$i -lt 512;$i++) { if($i -lt 148 -or $i -ge 156) { $sum+=$data[$h+$i] } }
        if ((Get-Octal $data ($h+148) 8) -ne $sum) { throw 'ARCHIVE_CHECKSUM' }
        if ([Text.Encoding]::ASCII.GetString($data,$h+257,8) -cne "ustar`000") { throw 'ARCHIVE_USTAR' }
        Assert-Zero $data ($h+157) ($h+257); Assert-Zero $data ($h+265) ($h+329)
        Assert-Zero $data ($h+329) ($h+345); Assert-Zero $data ($h+500) ($h+512)
        if((Get-Octal $data ($h+108) 8) -ne 0 -or (Get-Octal $data ($h+116) 8) -ne 0) { throw 'ARCHIVE_OWNER' }
        $null=Get-Octal $data ($h+136) 12
        $name=Get-TarText $data $h 100; $prefix=Get-TarText $data ($h+345) 155
        if($prefix) { $name=$prefix+'/'+$name }
        $directory=$data[$h+156] -eq 53
        if(!$directory -and $data[$h+156] -ne 48) { throw 'ARCHIVE_TYPE' }
        if($directory -and $name.EndsWith('/')) { $name=$name.Substring(0,$name.Length-1) }
        if($name -cnotmatch '^[A-Za-z0-9._/-]+$' -or $name.Length -gt 255 -or $name.Split('/').Count -gt 8 -or @($name.Split('/') | Where-Object { $_ -in @('','.','..') }).Count) { throw 'ARCHIVE_PATH' }
        if(!$seen.Add($name)) { throw 'ARCHIVE_DUPLICATE' }
        $mode=Get-Octal $data ($h+100) 8; $size=Get-Octal $data ($h+124) 12
        $limit=262144; if($name -ceq 'manifest.json') { $limit=65536 }
        if(($directory -and ($size -ne 0 -or $mode -ne 448)) -or (!$directory -and ($mode -notin @(384,420,448,493) -or $size -gt $limit))) { throw 'ARCHIVE_MODE_OR_SIZE' }
        $offset=$h+512; $end=$offset+$size; $padded=$offset+[int64]([Math]::Ceiling($size/512.0)*512)
        if($padded -gt $data.Length) { throw 'ARCHIVE_TRUNCATED' }
        Assert-Zero $data $end $padded
        if($directory) { $null=$dirs.Add($name) } else {
            $body=New-Object byte[] $size; [Array]::Copy($data,$offset,$body,0,$size)
            $files.Add($name,[pscustomobject]@{Mode=$mode;Bytes=$body})
        }
        $offset=$padded
    }
    if(!$terminated -or !$files.Count) { throw 'ARCHIVE_INCOMPLETE' }
    $parents=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($name in $files.Keys) { $parent=$name; while($parent.Contains('/')) { $parent=$parent.Substring(0,$parent.LastIndexOf('/')); $null=$parents.Add($parent) } }
    if(!$parents.SetEquals($dirs)) { throw 'ARCHIVE_DIRECTORY_CLOSURE' }
    foreach($name in $parents) { if($files.ContainsKey($name)) { throw 'ARCHIVE_DIRECTORY_COLLISION' } }
    return ,$files
}
function Read-StrictJson([byte[]]$Bytes) {
    $text=(New-Object Text.UTF8Encoding($false,$true)).GetString($Bytes)
    Initialize-ArchiveReader
    [OwnerSeriesJson]::Validate($text)
    $stack=New-Object Collections.Stack
    $tokens=[regex]::Matches($text,'"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|[{}\[\]:,]')
    for($i=0;$i -lt $tokens.Count;$i++) {
        $t=$tokens[$i].Value
        if($t -eq '{') { $stack.Push((New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))) }
        elseif($t -eq '[') { $stack.Push($null) }
        elseif($t -in @('}',']')) { if(!$stack.Count) { throw 'JSON_STRUCTURE' }; $null=$stack.Pop() }
        elseif($t.StartsWith('"') -and $i+1 -lt $tokens.Count -and $tokens[$i+1].Value -eq ':') {
            $key=ConvertFrom-Json ('{"v":'+$t+'}')
            if(!$stack.Count -or $null -eq $stack.Peek() -or !$stack.Peek().Add($key.v)) { throw 'JSON_DUPLICATE_KEY' }
        }
    }
    if($stack.Count) { throw 'JSON_STRUCTURE' }
    return ConvertFrom-Json $text
}
function Assert-Keys($Object,[string[]]$Keys) {
    if($null -eq $Object) { throw 'SCHEMA_OBJECT' }
    $actual=@($Object.PSObject.Properties.Name)
    if($actual.Count -ne $Keys.Count -or @($actual | Where-Object { $_ -cnotin $Keys }).Count) { throw 'SCHEMA_KEYS' }
}
function Assert-Success($Result,[string]$Operation,[string]$Source,[string]$Id) {
    $token='OWNER_SERIES_STAGE='+$Operation+' RESULT=PASS SOURCE='+$Source+' OPERATION='+$Id
    $matches=@($Result.Text -split '\r?\n' | Where-Object { $_ -ceq $token })
    if($Result.Code -ne 0 -or $matches.Count -ne 1) { throw 'Stage failed or exact success token missing. Preserve evidence; use explicit Recover for an interrupted operation.' }
}
function Assert-Approval($Approval,[string]$Source,[bool]$Monitor=$false,[bool]$Wan=$false) {
    if($Approval.format -cne 'HG_OWNER_SERIES_ACCEPTANCE_V1' -or $Approval.commit -cne $Source -or $Approval.ci_head -cne $Source -or $Approval.ci_conclusion -cne 'success' -or $Approval.review_head -cne $Source -or $Approval.review_blockers -isnot [int] -or $Approval.review_blockers -ne 0 -or $Approval.ci_url -cnotmatch '^https://github.com/bsekinaev/cudy-home-gateway/actions/runs/[0-9]+$') { throw 'SERIES_APPROVAL' }
    $report=$Approval.report
    $scenario='owner-series'; if($Monitor) { $scenario='owner-monitor' }; if($Wan) { $scenario='owner-wan' }
    if($report.commit -cne $Source -or $report.scenario -cne $scenario -or $report.status -cne 'PASS' -or $report.failed -isnot [int] -or $report.failed -ne 0) { throw 'SERIES_APPROVAL_REPORT' }
}
function Assert-StageAllowed($Session,[string]$RequestedStage) {
    if($RequestedStage -eq 'Apply' -and ($Session.apply_attempted -or $Session.rollback_attempted -or !$Session.preflightPassed)) { throw 'Apply requires successful Preflight and an unused session. An attempted Apply is never replayed; use explicit Recover.' }
    if($RequestedStage -eq 'Rollback' -and (!$Session.apply_attempted -or $Session.rollback_attempted)) { throw 'Rollback requires an attempted Apply and a new rollback operation; use Recover after an attempted Rollback.' }
}

$files=Read-Archive ([IO.Path]::GetFullPath($Bundle)) $BundleSha256
if(!$files.ContainsKey('manifest.json') -or $files['manifest.json'].Mode -ne 384) { throw 'SERIES_MANIFEST' }
$manifest=Read-StrictJson $files['manifest.json'].Bytes
Assert-Keys $manifest @('format','profile','production_apply','source_commit','baseline_commit','source_fixture','parent','bootstrap','inventories','changed','controls','files')
if($manifest.format -cnotin @('HG_OWNER_UPDATE_V2','HG_OWNER_MONITOR_V3','HG_OWNER_WAN_V4') -or $manifest.profile -cne 'OWNER_MANUAL' -or $manifest.production_apply -isnot [bool] -or !$manifest.production_apply -or $manifest.source_fixture -isnot [bool] -or $manifest.source_fixture -or $manifest.source_commit -cnotmatch '^[0-9a-f]{40}$' -or $manifest.baseline_commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Approved OWNER_MANUAL package required; VM_ONLY and source fixtures are refused.' }
$monitor=$manifest.format -ceq 'HG_OWNER_MONITOR_V3'
$wan=$manifest.format -ceq 'HG_OWNER_WAN_V4'
if($wan -and ($manifest.baseline_commit -cne '1fc822c3bddc1021a1d641c7d7cce71fab7332b8' -or $manifest.parent.format -cne 'HG_OWNER_MONITOR_V3' -or $manifest.parent.archive_sha256 -cne 'a9f86d3d972c2c8ec9b5f531d9660eb97d0690342da5eed3c2f2cc6d0ad36a65')) { throw 'SERIES_WAN_BASELINE' }
if($monitor -and ($manifest.baseline_commit -cne '62b5c4a9f25bc657fa1456eeacdfdc9039648cae' -or $manifest.parent.format -cne 'HG_OWNER_UPDATE_V2')) { throw 'SERIES_MONITOR_BASELINE' }
$pin=Get-Digest $files['manifest.json'].Bytes
$runtime=@('etc/init.d/home-gateway-telegram','usr/bin/gateway','usr/bin/home-gateway-ci-smoke')
$runtime+=@('actions.uc','asata.sh','common.sh','dns.sh','doctor.sh','health.sh','incidents.uc','network.sh','notifications.uc','redmi.sh','selftest.sh','status.sh','tailscale.sh','telegram-poller.uc','telegram.sh','torrent.sh','vpn.sh') | ForEach-Object { 'usr/lib/home-gateway/'+$_ }
$expected=@{'protocol.uc'=384;'engine.uc'=384;'watch.uc'=384;'state.uc'=384;'boot.init'=493;'owner.ps1'=384;'baseline.sha256'=384;'candidate.sha256'=384;'bootstrap.tar.gz'=384;'parent.json'=384}
$expected['acceptance.json']=384
foreach($side in @('baseline','candidate')) { foreach($p in $runtime) { $mode=420; if($p -cin $runtime[0..2]) { $mode=493 }; $expected[$side+'/'+$p]=$mode } }
if($manifest.files -isnot [array] -or $manifest.files.Count -ne $expected.Count -or $files.Count -ne $expected.Count+1) { throw 'SERIES_INVENTORY' }
$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach($entry in $manifest.files) {
    Assert-Keys $entry @('path','mode','size','sha256')
    if($entry.path -isnot [string] -or !$seen.Add($entry.path) -or $entry.path -cnotin @($expected.Keys) -or !$files.ContainsKey($entry.path)) { throw 'SERIES_INVENTORY' }
    $f=$files[$entry.path]
    if($entry.mode -isnot [int] -or $entry.size -isnot [int] -or $entry.mode -ne $expected[$entry.path] -or $f.Mode -ne $entry.mode -or $entry.size -ne $f.Bytes.Length -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-Digest $f.Bytes) -cne $entry.sha256) { throw 'SERIES_FILE_PIN' }
}
$approval=Read-StrictJson $files['acceptance.json'].Bytes
Assert-Approval $approval $manifest.source_commit $monitor $wan
if($wan -and ($approval.report.delivery -cne 'wan' -or $approval.report.package_format -cne $manifest.format -or $approval.report.baseline_commit -cne $manifest.baseline_commit)) { throw 'SERIES_WAN_APPROVAL' }
if($wan) { $parentFormats=@('HG_OWNER_MONITOR_V3') } else { $parentFormats=@('HG_OWNER_UPDATE_V1','HG_OWNER_UPDATE_V2') }
if($monitor) {
    $monitorApproval=Read-StrictJson $files['acceptance.json'].Bytes
    if($monitorApproval.report.delivery -cne 'monitor' -or $monitorApproval.report.package_format -cne 'HG_OWNER_MONITOR_V3' -or $monitorApproval.report.baseline_commit -cne '62b5c4a9f25bc657fa1456eeacdfdc9039648cae') { throw 'SERIES_MONITOR_APPROVAL' }
}
Assert-Keys $manifest.inventories @('baseline','candidate')
foreach($side in @('baseline','candidate')) {
    $inventory=$manifest.inventories.$side; Assert-Keys $inventory $runtime
    $sums=''
    foreach($p in $runtime) { if($inventory.$p -cnotmatch '^[0-9a-f]{64}$' -or $inventory.$p -cne (Get-Digest $files[$side+'/'+$p].Bytes)) { throw 'SERIES_RUNTIME_PIN' }; $sums+=$inventory.$p+'  '+$p+"`n" }
    if([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sums)) -cne [Convert]::ToBase64String($files[$side+'.sha256'].Bytes)) { throw 'SERIES_RUNTIME_SUMS' }
}
$changed=@($runtime | Where-Object { $manifest.inventories.baseline.$_ -cne $manifest.inventories.candidate.$_ })
$allowed=@('dns.sh','health.sh','redmi.sh','status.sh','telegram-poller.uc') | ForEach-Object { 'usr/lib/home-gateway/'+$_ }
if($monitor) { $allowed=@('usr/bin/gateway')+@('health.sh','network.sh','vpn.sh','incidents.uc','notifications.uc','telegram-poller.uc','torrent.sh' | ForEach-Object { 'usr/lib/home-gateway/'+$_ }) }
if($wan) { $allowed=@('network.sh','health.sh','vpn.sh','torrent.sh' | ForEach-Object { 'usr/lib/home-gateway/'+$_ }) }
if(!$changed.Count -or @($changed | Where-Object { $_ -cnotin $allowed }).Count -or ($changed -join "`n") -cne ($manifest.changed -join "`n")) { throw 'SERIES_DELTA' }
$controlPaths=@('usr/libexec/home-gateway-deploy/engine.sh','usr/libexec/home-gateway-deploy/wrapper.sh','etc/init.d/home-gateway-deploy-recover','etc/init.d/home-gateway-migration','usr/libexec/home-gateway-deploy/migration-admission.sh')
$controlPaths+=@('state','snapshot','candidate','runtime','handoff','coordinator','controls','service','terminal') | ForEach-Object { 'usr/libexec/home-gateway-deploy/migration-'+$_+'.uc' }
Assert-Keys $manifest.controls $controlPaths
foreach($p in $controlPaths) { if($manifest.controls.$p -cnotmatch '^[0-9a-f]{64}$') { throw 'SERIES_CONTROL_PIN' } }
Assert-Keys $manifest.bootstrap @('archive_sha256','manifest_sha256')
if($manifest.bootstrap.archive_sha256 -cne 'a39fb710909661d6c03c4f2f73f3b7645017b14a07999c80666de6735b926eed' -or $manifest.bootstrap.manifest_sha256 -cne '430383e3b0bfff46fbee688068cfea4e1446ca4491d6ded83d67ef1179e6b0df' -or (Get-Digest $files['bootstrap.tar.gz'].Bytes) -cne $manifest.bootstrap.archive_sha256) { throw 'SERIES_BOOTSTRAP_PIN' }
Assert-Keys $manifest.parent @('format','source_commit','manifest_sha256','archive_sha256')
if($files['parent.json'].Bytes.Length -gt 65536) { throw 'SERIES_PARENT_SIZE' }
$parent=Read-StrictJson $files['parent.json'].Bytes
if($files['parent.json'].Bytes.Length -gt 65536 -or $manifest.parent.format -cnotin $parentFormats -or $parent.format -cne $manifest.parent.format -or $parent.source_commit -cne $manifest.baseline_commit -or $manifest.parent.source_commit -cne $manifest.baseline_commit -or $manifest.parent.manifest_sha256 -cne (Get-Digest $files['parent.json'].Bytes) -or $manifest.parent.archive_sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'SERIES_PARENT_LINK' }
if($parent.format -ceq 'HG_OWNER_UPDATE_V1') {
    if($manifest.parent.archive_sha256 -cne $manifest.bootstrap.archive_sha256 -or $manifest.parent.manifest_sha256 -cne $manifest.bootstrap.manifest_sha256 -or $manifest.baseline_commit -cne 'd2039b6c62da3aa458f720af1c46fb619aee48dd') { throw 'SERIES_PARENT_BOOTSTRAP' }
} elseif($parent.source_fixture -isnot [bool] -or $parent.source_fixture -or $parent.profile -cne 'OWNER_MANUAL' -or $parent.production_apply -ne $true -or $parent.bootstrap.archive_sha256 -cne $manifest.bootstrap.archive_sha256 -or $parent.bootstrap.manifest_sha256 -cne $manifest.bootstrap.manifest_sha256) { throw 'SERIES_PARENT_OWNER' }
foreach($p in $runtime) { if($parent.inventories.candidate.$p -cne $manifest.inventories.baseline.$p) { throw 'SERIES_PARENT_RUNTIME' } }
foreach($p in $controlPaths) { if($parent.controls.$p -cne $manifest.controls.$p) { throw 'SERIES_PARENT_CONTROLS' } }

$SessionFile=[IO.Path]::GetFullPath($SessionFile)
$lock=$null
function Save-Session {
    Initialize-ArchiveReader
    $tmp=$SessionFile+'.'+[guid]::NewGuid().ToString('N')+'.new'
    $bytes=[Text.Encoding]::UTF8.GetBytes(($session | ConvertTo-Json -Depth 8))
    $stream=New-Object IO.FileStream($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [OwnerSeriesArchive]::Publish($tmp,$SessionFile)
}
function Invoke-Native([string]$Program,[string[]]$Arguments) {
    $oldConsole=[Console]::OutputEncoding; $oldOutput=$OutputEncoding; $oldPreference=$ErrorActionPreference
    try {
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); $OutputEncoding=[Console]::OutputEncoding; $ErrorActionPreference='Continue'
        $lines=@(& $Program @Arguments 2>&1); $code=$LASTEXITCODE
    } finally { [Console]::OutputEncoding=$oldConsole; $OutputEncoding=$oldOutput; $ErrorActionPreference=$oldPreference }
    $text=($lines | ForEach-Object { [string]$_ }) -join "`n"
    $path=$SessionFile+'.transport.'+[guid]::NewGuid().ToString('N')+'.txt'
    [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
    Write-Host $text; Write-Host ('PRIVATE_OWNER_TRANSPORT_EVIDENCE='+$path)
    return [pscustomobject]@{Code=$code;Text=$text}
}
function Invoke-Remote([string]$Command) {
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    return Invoke-Native 'ssh' (@('-T','-p',[string]$Port)+$common+@($Target,('printf %s '+$encoded+' | base64 -d | sh')))
}
try {
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($SessionFile))
    $lock=New-Object IO.FileStream(($SessionFile+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if([IO.File]::Exists($SessionFile)) {
        if((Get-Item -LiteralPath $SessionFile).Length -gt 65536) { throw 'Session exceeds size limit.' }
        $session=Read-StrictJson ([IO.File]::ReadAllBytes($SessionFile))
        Assert-Keys $session @('format','target','port','sha256','source','baseline','manifest_sha256','remoteKit','apply_id','rollback_id','last_operation_id','apply_attempted','rollback_attempted','preflightPassed')
        if($session.format -cne 'HG_OWNER_SERIES_SESSION_V1' -or $session.target -cne $Target -or $session.port -ne $Port -or $session.sha256 -cne $BundleSha256 -or $session.source -cne $manifest.source_commit -or $session.baseline -cne $manifest.baseline_commit -or $session.manifest_sha256 -cne $pin -or $session.apply_id -cnotmatch '^tx\.[0-9a-f]{32}$') { throw 'Session identity mismatch. Preserve the old session.' }
        foreach($id in @($session.rollback_id,$session.last_operation_id)) { if($null -ne $id -and $id -cnotmatch '^tx\.[0-9a-f]{32}$') { throw 'Invalid session operation identity.' } }
        foreach($flag in @($session.apply_attempted,$session.rollback_attempted,$session.preflightPassed)) { if($flag -isnot [bool]) { throw 'Invalid session state.' } }
        if(($session.rollback_attempted -and (!$session.apply_attempted -or !$session.rollback_id -or $session.last_operation_id -cne $session.rollback_id -or $session.rollback_id -ceq $session.apply_id)) -or (!$session.rollback_attempted -and $null -ne $session.rollback_id) -or (!$session.rollback_attempted -and $session.apply_attempted -and $session.last_operation_id -cne $session.apply_id) -or (!$session.apply_attempted -and $null -ne $session.last_operation_id)) { throw 'Inconsistent session operation state.' }
    } else {
        if($Stage -ne 'Preflight') { throw 'Start a new session with Preflight.' }
        $session=[pscustomobject]@{format='HG_OWNER_SERIES_SESSION_V1';target=$Target;port=$Port;sha256=$BundleSha256;source=$manifest.source_commit;baseline=$manifest.baseline_commit;manifest_sha256=$pin;remoteKit=$null;apply_id=('tx.'+[guid]::NewGuid().ToString('N'));rollback_id=$null;last_operation_id=$null;apply_attempted=$false;rollback_attempted=$false;preflightPassed=$false}
        Save-Session
    }
    Assert-StageAllowed $session $Stage
    if($session.remoteKit -and $session.remoteKit -cnotmatch '^/tmp/hg-owner-series-kit\.[A-Za-z0-9]{6}/kit$') { throw 'Invalid session kit path.' }
    $common=@('-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2')
    foreach($program in @('ssh','scp')) { $null=Get-Command $program -ErrorAction Stop }
    if($session.remoteKit) {
        $exists=Invoke-Remote ('test -d '+$session.remoteKit)
        if($exists.Code -eq 1) { $session.remoteKit=$null; Save-Session } elseif($exists.Code -ne 0) { throw 'Cannot check preserved staging directory.' }
    }
    if(!$session.remoteKit) {
        $created=Invoke-Remote 'umask 077; mktemp -d /tmp/hg-owner-series-kit.XXXXXX'
        $roots=@($created.Text -split '\r?\n' | Where-Object { $_ -cmatch '^/tmp/hg-owner-series-kit\.[A-Za-z0-9]{6}$' })
        if($created.Code -ne 0 -or $roots.Count -ne 1) { throw 'No unique staging directory.' }
        $root=$roots[0]; $archive=$root+'/bundle.tar.gz'
        $upload=Invoke-Native 'scp' (@('-O','-P',[string]$Port)+$common+@([IO.Path]::GetFullPath($Bundle),($Target+':'+$archive)))
        if($upload.Code -ne 0) { throw 'Upload failed. Preserve evidence.' }
        $unpack=Invoke-Remote ('actual=$(sha256sum '+$archive+'); test "${actual%% *}" = '+$BundleSha256+' && mkdir -m 700 '+$root+'/kit && tar -xzpf '+$archive+' -C '+$root+'/kit')
        if($unpack.Code -ne 0) { throw 'Remote archive authentication or extraction failed.' }
        $session.remoteKit=$root+'/kit'; Save-Session
    }
    $id=$session.apply_id
    if($Stage -eq 'Preflight') { $session.preflightPassed=$false; Save-Session }
    elseif($Stage -eq 'Apply') { $session.apply_attempted=$true; $session.last_operation_id=$id; Save-Session }
    elseif($Stage -eq 'Rollback') { $id='tx.'+[guid]::NewGuid().ToString('N'); $session.rollback_id=$id; $session.rollback_attempted=$true; $session.last_operation_id=$id; Save-Session }
    elseif($session.last_operation_id) { $id=$session.last_operation_id }
    $operation=$Stage.ToLowerInvariant()
    $result=Invoke-Remote ('/usr/bin/ucode '+$session.remoteKit+'/engine.uc '+$operation+' '+$session.remoteKit+' '+$pin+' '+$id)
    Assert-Success $result $operation $session.source $id
    if($Stage -eq 'Preflight') { $session.preflightPassed=$true; Save-Session }
    Write-Host ('OWNER_SERIES_STAGE='+$operation+' RESULT=PASS SOURCE='+$session.source+' OPERATION='+$id)
} finally { if($null -ne $lock) { $lock.Dispose() } }
