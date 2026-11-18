import pathlib, subprocess, tempfile, unittest, json, os
HERE=pathlib.Path(__file__).parent
class Guards(unittest.TestCase):
 def test_boot_active_and_unknown_fail_closed(self):
  self.assertTrue((HERE/'boot.init').exists(),'series boot guard missing')
  source=(HERE/'boot.init').read_text()
  for active,pin,expected in [('tx.'+'a'*32+'\n','b'*64+'\n',True),('broken\n','b'*64+'\n',False)]:
   with tempfile.TemporaryDirectory() as d:
    root=pathlib.Path(d); j=root/'etc/home-gateway-owner-series'; j.mkdir(parents=True,mode=0o700)
    (root/'tmp').mkdir(); (j/'active').write_text(active);(j/'active').chmod(0o600)
    generation=j/'generations'/('tx.'+'a'*32); generation.mkdir(parents=True,mode=0o700);generation.parent.chmod(0o700)
    (generation/'kit-pin').write_text(pin);(generation/'kit-pin').chmod(0o600)
    script=source.replace('/etc/home-gateway-owner-series',str(j)).replace('/tmp/home-gateway',str(root/'tmp/home-gateway')).replace('/usr/bin/ucode','ucode')+'\nstart\n'
    result=subprocess.run(['sh','-c',script],capture_output=True,text=True)
    self.assertEqual(result.returncode,0,result.stderr)
    lock=root/'tmp/home-gateway-deploy.lock';self.assertTrue(lock.is_dir())
    self.assertFalse((lock/'pid').exists())
    if expected:self.assertEqual((lock/'owner-series').read_text(),pin)
 def test_boot_no_active_and_foreign_lock_unchanged(self):
  source=(HERE/'boot.init').read_text()
  for active in [False,True]:
   with tempfile.TemporaryDirectory() as d:
    root=pathlib.Path(d);j=root/'etc/home-gateway-owner-series';j.mkdir(parents=True)
    (root/'tmp/home-gateway-deploy.lock').mkdir(parents=True)
    foreign=root/'tmp/home-gateway-deploy.lock/pid';foreign.write_text('foreign')
    if active:(j/'active').write_text('invalid')
    script=source.replace('/etc/home-gateway-owner-series',str(j)).replace('/tmp/home-gateway',str(root/'tmp/home-gateway')).replace('/usr/bin/ucode','ucode')+'\nstart\n'
    result=subprocess.run(['sh','-c',script],capture_output=True,text=True)
    self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(foreign.read_text(),'foreign')
    self.assertEqual(list(foreign.parent.iterdir()),[foreign])
 def test_native_pid_reuse_and_zombie(self):
  self.assertTrue((HERE/'watch.uc').exists(),'series guardian missing')
  source=(HERE/'watch.uc').read_text(); start=source.index('function owner_alive()');end=source.index('\nfunction ',start+10)
  fn=source[start:end]
  with tempfile.TemporaryDirectory() as d:
   root=pathlib.Path(d); (root/'proc/sys/kernel/random').mkdir(parents=True); (root/'proc/42').mkdir()
   (root/'proc/sys/kernel/random/boot_id').write_text('boot\n')
   for state,tick,want in [('S','123',True),('S','124',False),('Z','123',False)]:
    (root/'proc/42/stat').write_text('42 (a ) strange) '+state+' '+' '.join(['0']*18)+' '+tick+'\n')
    code="import * as fs from 'fs'; function require(ok,why){if(!ok)die(why);} let expected=['','boot','42','123'];"+fn.replace('/proc/',d+'/proc/')+' print(owner_alive());'
    result=subprocess.run(['ucode','-e',code],capture_output=True,text=True)
    self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,'true' if want else 'false')
 def test_native_revocation_rejects_foreign_pid_before_quiesce(self):
  source=(HERE/'watch.uc').read_text()
  regular=source[source.index('function regular('):source.index('function exclusive(')]
  body=source[source.index("    if(fs.lstat(LOCK+'/pid')"):source.index("    exclusive(dir+'/done'")]
  for legacy,good in [('42\n',True),('43\n',False),(None,True)]:
   with tempfile.TemporaryDirectory() as d:
    root=pathlib.Path(d)
    for name,raw in [('owner-pid','42\n'),('pid',legacy)]:
     if raw is not None:(root/name).write_text(raw);(root/name).chmod(0o600)
    code="import * as fs from 'fs';function require(ok,why){if(!ok)die(why);} function proof(){} function run(args){if(index(args,'-e')>=0){require(fs.lstat(LOCK+'/pid')==null,'ORDER');print('quiesced');}return true;} let expected=['','','42'];let LOCK="+json.dumps(d)+';'+regular+body
    result=subprocess.run(['ucode','-e',code],capture_output=True,text=True)
    if good:
     self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,'quiesced');self.assertFalse((root/'pid').exists())
    else:
     self.assertNotEqual(result.returncode,0);self.assertEqual(result.stdout,'');self.assertEqual((root/'pid').read_text(),legacy)
 def test_quiesce_follows_authenticated_revocation(self):
  self.assertTrue((HERE/'watch.uc').exists(),'series guardian missing')
  source=(HERE/'watch.uc').read_text()
  self.assertLess(source.index("regular(LOCK+'/pid'"),source.index("fs.unlink(LOCK+'/pid')"))
  self.assertLess(source.index("fs.unlink(LOCK+'/pid')"),source.index("quiesce_telegram(\"\""))
  self.assertNotIn('terminal()',source)
if __name__=='__main__':unittest.main()
