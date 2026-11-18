import gzip, hashlib, io, json, pathlib, shutil, subprocess, tarfile, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parent
PS='powershell.exe'
def invoke(code):
    runner=ROOT/'owner.ps1'
    harness="$ErrorActionPreference='Stop'; $parseErrors=$null; $ast=[System.Management.Automation.Language.Parser]::ParseFile('"+str(runner).replace("'","''")+"',[ref]$null,[ref]$parseErrors); if($parseErrors.Count) { throw ($parseErrors | Out-String) }; $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }; "+code
    return subprocess.run([PS,'-NoProfile','-NonInteractive','-Command',harness],capture_output=True,encoding='utf-8',errors='replace')
def bundle(entries):
    out=io.BytesIO()
    with tarfile.open(fileobj=out,mode='w',format=tarfile.USTAR_FORMAT) as t:
        for name,data,kind,mode in entries:
            i=tarfile.TarInfo(name); i.mode=mode; i.type=kind; i.size=len(data); t.addfile(i,io.BytesIO(data))
    return gzip.compress(out.getvalue(),mtime=0)
@unittest.skipUnless(shutil.which(PS), 'Windows PowerShell 5.1 required')
class RunnerTests(unittest.TestCase):
    def archive(self,raw,pin=None):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'kit.gz'; p.write_bytes(raw)
            return invoke("$x=Read-Archive '"+str(p)+"' '"+(pin or hashlib.sha256(raw).hexdigest())+"'; Write-Output ('COUNT='+$x.Count)")
    def test_valid_archive(self):
        r=self.archive(bundle([('manifest.json',b'{}',tarfile.REGTYPE,0o600)])); self.assertEqual(r.returncode,0,r.stderr); self.assertIn('COUNT=1',r.stdout)
    def test_archive_rejections(self):
        good=bundle([('manifest.json',b'{}',tarfile.REGTYPE,0o600)])
        for raw,pin in [(good,'0'*64),(good+b'x',None),(gzip.compress(b'x'*8388609),None), (bundle([('../escape',b'x',tarfile.REGTYPE,0o600)]),None),(bundle([('link',b'',tarfile.SYMTYPE,0o600)]),None),(bundle([('x',b'x',tarfile.REGTYPE,0o777)]),None),(bundle([('x',b'x',tarfile.REGTYPE,0o600),('x',b'x',tarfile.REGTYPE,0o600)]),None),(bundle([('dir/x',b'x',tarfile.REGTYPE,0o600)]),None)]:
            with self.subTest(pin=pin,raw=len(raw)): self.assertNotEqual(self.archive(raw,pin).returncode,0)
    def test_duplicate_json(self):
        self.assertNotEqual(invoke("Read-StrictJson ([Text.Encoding]::UTF8.GetBytes('{\"a\":1,\"a\":2}'))").returncode,0)
    def test_exact_success_token(self):
        token='OWNER_SERIES_STAGE=apply RESULT=PASS SOURCE='+'a'*40+' OPERATION=tx.'+'b'*32
        for lines,code,ok in [(token,0,True),(token,1,False),(token+' junk',0,False),('diagnostic\n'+token,0,True),('diagnostic',0,False)]:
            r=invoke("Assert-Success ([pscustomobject]@{Code="+str(code)+";Text='"+lines+"'}) 'apply' '"+'a'*40+"' 'tx."+'b'*32+"'")
            self.assertEqual(r.returncode==0,ok,r.stderr)
    def test_session_replay_guards(self):
        for apply,rollback,preflight,stage,ok in [(False,False,False,'Apply',False),(False,False,True,'Apply',True),(True,False,True,'Apply',False),(True,True,True,'Apply',False),(True,False,False,'Rollback',True),(True,True,True,'Rollback',False),(False,False,True,'Rollback',False),(True,True,False,'Recover',True)]:
            code="$s=[pscustomobject]@{apply_attempted=$"+str(apply).lower()+";rollback_attempted=$"+str(rollback).lower()+";preflightPassed=$"+str(preflight).lower()+"}; Assert-StageAllowed $s '"+stage+"'"
            r=invoke(code); self.assertEqual(r.returncode==0,ok,r.stderr)
    def test_approval_source_and_native_report(self):
        source='a'*40
        good=dict(format='HG_OWNER_SERIES_ACCEPTANCE_V1',commit=source,ci_head=source,ci_conclusion='success',review_head=source,review_blockers=0,ci_url='https://github.com/bsekinaev/cudy-home-gateway/actions/runs/123',report=dict(commit=source,scenario='owner-series',status='PASS',failed=0))
        variants=[(good,True)]
        for key,value in [('ci_head','b'*40),('review_blockers',False),('ci_conclusion','failure')]:
            bad=dict(good); bad[key]=value; variants.append((bad,False))
        bad=dict(good); bad['report']=dict(good['report'],scenario='owner-update'); variants.append((bad,False))
        for data,ok in variants:
            r=invoke("$a=Read-StrictJson ([Text.Encoding]::UTF8.GetBytes('"+json.dumps(data)+"')); Assert-Approval $a '"+source+"'")
            self.assertEqual(r.returncode==0,ok,r.stderr)
    def test_utf8_native_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            output=pathlib.Path(d)/'session'
            code="$SessionFile='"+str(output)+"'; $command=\"[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); Write-Output ([char]0x041F+[string][char]0x0440+[char]0x0438+[char]0x0432+[char]0x0435+[char]0x0442)\"; $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)); $r=Invoke-Native 'powershell.exe' @('-NoProfile','-EncodedCommand',$encoded); if($r.Code -ne 0) { throw 'native failure' }"
            r=invoke(code); self.assertEqual(r.returncode,0,r.stderr)
            evidence=list(pathlib.Path(d).glob('*.txt')); self.assertEqual(len(evidence),1)
            self.assertIn('Привет',evidence[0].read_text(encoding='utf-8'))
    def test_additional_archive_metadata_and_crc(self):
        raw=bundle([('manifest.json',b'{}',tarfile.REGTYPE,0o600)])
        tampered=bytearray(raw); tampered[-8]^=1
        for bad in [bytes(tampered),raw+raw,raw[:-1],bundle([('manifest.json',b'x'*65537,tarfile.REGTYPE,0o600)]),bundle([('x',b'x'*262145,tarfile.REGTYPE,0o600)])]:
            self.assertNotEqual(self.archive(bad).returncode,0)
    def test_strict_json_grammar(self):
        for bad in ['{"a":NaN}', '{a:1}', '{"a":1,}', '/*x*/{}', '[1,]', '{}{}', '{"a":1,"\\u0061":2}']:
            with self.subTest(bad=bad):
                r=invoke("Read-StrictJson ([Text.Encoding]::UTF8.GetBytes('"+bad+"'))")
                self.assertNotEqual(r.returncode,0)
    def test_atomic_session_persistence(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'session.json'
            code="$SessionFile='"+str(p)+"'; $session=[pscustomobject]@{apply_id=('tx.'+[guid]::NewGuid().ToString('N'));last_operation_id=$null;apply_attempted=$false}; Save-Session; $session.apply_attempted=$true; $session.last_operation_id=$session.apply_id; Save-Session"
            r=invoke(code); self.assertEqual(r.returncode,0,r.stderr)
            session=json.loads(p.read_text(encoding='utf-8')); self.assertTrue(session['apply_attempted']); self.assertEqual(session['last_operation_id'],session['apply_id']); self.assertRegex(session['apply_id'],r'^tx\.[0-9a-f]{32}$')
            self.assertEqual(list(pathlib.Path(d).glob('*.new')),[])
    def test_syntax(self):
        r=invoke("Write-Output 'parsed'"); self.assertEqual(r.returncode,0,r.stderr)
if __name__=='__main__': unittest.main()
