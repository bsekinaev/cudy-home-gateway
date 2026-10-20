"""Delivery B packaging and actual PowerShell stage protocol (no router access)."""
import hashlib,importlib.util,io,json,os,shutil,subprocess,tarfile,tempfile,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('hg_delivery_b',Path(__file__).with_name('build_b.py'))
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
class Bundle(unittest.TestCase):
 def test_vm_package_is_deterministic_and_owner_package_requires_acceptance(self):
  with tempfile.TemporaryDirectory() as d:
   a=builder.build(builder.REPO,'HEAD',Path(d)/'one');b=builder.build(builder.REPO,'HEAD',Path(d)/'two')
   self.assertEqual(a.read_bytes(),b.read_bytes())
   with tarfile.open(a) as t:
    m=json.load(t.extractfile('manifest.json'));self.assertFalse(m['production_apply']);self.assertEqual(m['delivery'],'B_VM_ACCEPTANCE')
    self.assertEqual(len([r for r in m['files'] if r['path'].startswith('candidate/')]),24)
    self.assertEqual(len([r for r in m['files'] if r['path'].startswith('native/')]),10)
    for r in m['files']:
     info=t.getmember(r['path']);self.assertEqual((info.uid,info.gid,info.mode,info.size),(0,0,r['mode'],r['size']))
     self.assertEqual(hashlib.sha256(t.extractfile(info).read()).hexdigest(),r['sha256'])
   with self.assertRaisesRegex(ValueError,'OWNER_ACCEPTANCE_REQUIRED'):builder.content(builder.REPO,'HEAD','owner')
   with self.assertRaises(ValueError):builder.validate_acceptance(b'{}',m['source_commit'])
@unittest.skipUnless(shutil.which('pwsh'),'PowerShell unavailable')
class Owner(unittest.TestCase):
 def test_one_shot_apply_and_recovery_after_interrupted_prepare(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);source='a'*40;nonce='11111111-2222-3333-4444-555555555555'
   # Protocol-only fixture: actual package acceptance is tested separately.
   manifest=json.dumps(dict(format='HGDEPLOY2_RC_B_V1',delivery='B_OWNER_MANUAL',production_apply=True,source_commit=source)).encode()
   buf=io.BytesIO()
   with tarfile.open(fileobj=buf,mode='w:gz') as t:
    item=tarfile.TarInfo('manifest.json');item.size=len(manifest);t.addfile(item,io.BytesIO(manifest))
   raw=buf.getvalue();digest=hashlib.sha256(raw).hexdigest();(root/('rc-b-'+digest+'.tar.gz')).write_bytes(raw)
   commands=root/'commands';commands.mkdir();log=root/'calls'
   shim='''#!/usr/bin/env python3
import os,sys
s=sys.argv[-1]
with open(os.environ['RC_CALLS'],'a') as f:f.write(sys.argv[0].split('/')[-1]+' '+s+'\\n')
if 'mktemp -d' in s:print('/tmp/hgdeploy2-rc-b-kit.Abc123')
if '/rc-b.sh prepare ' in s:
 print('RC_B_TRANSACTION=11111111-2222-3333-4444-555555555555 SOURCE='+'a'*40)
 if os.environ.get('RC_FAIL')=='prepare':sys.exit(255)
if '/rc-b.sh retire-check ' in s:
 n=s.split()[-1];print('RC_B_RETIREMENT_CHECK=PASS TRANSACTION='+n+' ARCHIVE=/etc/home-gateway-migration')
if '/rc-b.sh retire ' in s:
 n=s.split()[-2];print('RC_B_RETIREMENT=PASS TRANSACTION='+n+' ARCHIVE=/etc/home-gateway-migration.retired.'+n)
if '/rc-b.sh apply ' in s and os.environ.get('RC_FAIL')=='apply':sys.exit(70)
'''
   for name in ('ssh','scp'):
    p=commands/name;p.write_text(shim);p.chmod(0o755)
   env=dict(os.environ,PATH=str(commands)+os.pathsep+os.environ['PATH'],RC_CALLS=str(log))
   def run(session,stage,recovery=False,fail='',previous=None,retirement=False):
    env['RC_FAIL']=fail
    args=['pwsh','-NoProfile','-File',str(Path(__file__).with_name('owner-b.ps1')),'-Target','root@fixture.invalid','-BundleUrl','https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/'+source+'/artifacts/test.tar.gz','-BundleSha256',digest,'-SessionFile',str(root/session),'-Stage',stage]
    if recovery:args+=['-RecoveryPathConfirmed']
    if previous:args+=['-PreviousSessionFile',str(root/previous)]
    if retirement:args+=['-RetirementConfirmed']
    return subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
   old=dict(format='HG_RC_B_SESSION_V1',target='root@fixture.invalid',source='908dd3222b81992d9fee056bd015a1266a0ce8d7',bundleSha256='d10beec6bc376a819a04e51cff1b4c779f2f0e1dec0412f20b38c6d2100a8f56',manifestSha256='67b65f1ceabe1534ff74fba8f6c486e9d02bfce9a7e7999875bd11929df467a1',transaction=nonce)
   previous=root/'previous.json';previous.write_text(json.dumps(old));saved=previous.read_bytes()
   p=run('retire.json','Retire',True,previous='previous.json');self.assertNotEqual(p.returncode,0);self.assertFalse(log.exists())
   p=run('retire.json','RetireCheck',previous='previous.json');self.assertEqual(p.returncode,0,p.stdout)
   p=run('retire.json','Retire',True,previous='previous.json',retirement=True);self.assertEqual(p.returncode,0,p.stdout)
   state=json.loads((root/'retire.json').read_text(encoding='utf-8-sig'));self.assertIsNone(state['transaction']);self.assertTrue(state['retirementPassed']);self.assertFalse(state['applyAttempted'])
   self.assertEqual(previous.read_bytes(),saved);self.assertNotIn('rc-b.sh apply',log.read_text())
   p=run('retire.json','UploadRecovery');self.assertEqual(p.returncode,0,p.stdout)
   p=run('retire.json','RetireCheck',previous='previous.json');self.assertEqual(p.returncode,0,p.stdout)
   p=run('retire.json','Retire',True,previous='previous.json',retirement=True);self.assertEqual(p.returncode,0,p.stdout)
   p=run('retire.json','Preflight');self.assertEqual(p.returncode,0,p.stdout)
   current=dict(old,source='6b7d3ada6fe6b513e08db22469ccde10a6d47ee3',bundleSha256='e1e7df7fa84d9e1cfc8a3881b16d374fa3d417d2ec41a440f999b7c708e236d6',manifestSha256='10a5ac968a539a9c0287d4b711f065acdc71d54382854803d1b3fc0b551b6501')
   recent=root/'recent.json';recent.write_text(json.dumps(current));preserved=recent.read_bytes()
   p=run('recent-retire.json','RetireCheck',previous='recent.json');self.assertEqual(p.returncode,0,p.stdout)
   p=run('recent-retire.json','Retire',True,previous='recent.json',retirement=True);self.assertEqual(p.returncode,0,p.stdout)
   self.assertEqual(recent.read_bytes(),preserved)
   corrupt=dict(current,bundleSha256='f'*64);(root/'bad-recent.json').write_text(json.dumps(corrupt))
   before=log.read_bytes();p=run('bad-retire.json','RetireCheck',previous='bad-recent.json');self.assertNotEqual(p.returncode,0);self.assertEqual(log.read_bytes(),before)
   p=run('one.json','Preflight');self.assertEqual(p.returncode,0,p.stdout);self.assertNotIn('rc-b.sh apply',log.read_text())
   p=run('one.json','Prepare');self.assertNotEqual(p.returncode,0);self.assertNotIn('rc-b.sh prepare',log.read_text())
   p=run('one.json','Prepare',True);self.assertEqual(p.returncode,0,p.stdout)
   p=run('one.json','Apply',True,'apply');self.assertNotEqual(p.returncode,0)
   self.assertTrue(json.loads((root/'one.json').read_text(encoding='utf-8-sig'))['applyAttempted'])
   before=log.read_text();p=run('one.json','Apply',True);self.assertNotEqual(p.returncode,0);self.assertEqual(log.read_text(),before)
   self.assertNotIn('rc-b.sh rollback',before)
   for stage in ('Verify','UploadRecovery','Rollback'):
    p=run('one.json',stage);self.assertEqual(p.returncode,0,p.stdout)
   p=run('two.json','Preflight');self.assertEqual(p.returncode,0,p.stdout)
   p=run('two.json','Prepare',True,'prepare');self.assertNotEqual(p.returncode,0)
   s=json.loads((root/'two.json').read_text(encoding='utf-8-sig'));self.assertEqual(s['transaction'],nonce);self.assertFalse(s['prepared'])
   p=run('two.json','Rollback');self.assertEqual(p.returncode,0,p.stdout)
if __name__=='__main__':unittest.main()
