"""Provisional startup is scoped to verified 23-file tree and inherited guard."""
import os,shlex,subprocess,unittest
from pathlib import Path
import test_native_coordinator
SCRIPT=Path(__file__).with_name('migration-admission.sh')
class ServiceAdmission(unittest.TestCase):
 def test_start_ticket_never_admits_receiver_and_requires_exact_live_tree(self):
  fixture=test_native_coordinator.NativeCoordinatorTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
  r=fixture.run_native('prepare_coordinator(ARGV[0],s,ARGV[1],"'+'c'*40+'",1)');self.assertEqual(r.returncode,0,r.stderr);r=fixture.run_native('apply_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
  root,base,bb=fixture.root,fixture.base,fixture.bb
  lock=root/'etc/home-gateway-migration.lock';nonce=(base/'marker').read_text().split()[1]
  ticket=base/'service-check';ticket.write_text(f'HG_MIGRATION_SERVICE_CHECK_V1 {nonce} {lock.stat().st_ino}\n');ticket.chmod(0o600)
  shell=os.environ.get('HG_TEST_SHELL','/bin/sh').split()
  def run(*flags,held=True):
   gate=shell+[str(SCRIPT),'--test-root',str(root),*flags]
   if not held:return subprocess.run(gate,capture_output=True,text=True,timeout=15)
   body='exec 8< '+shlex.quote(str(lock))+'; '+shlex.join([bb,'flock','-n','8'])+' && '+shlex.join(gate)
   return subprocess.run(shell+['-c',body],capture_output=True,text=True,timeout=15)
  flags=('--telegram-start','--migration-start','--held-telegram-guard')
  p=run(*flags);self.assertEqual(p.returncode,0,p.stderr);self.assertIn('SERVICE_CHECK_ONLY',p.stdout)
  self.assertFalse((base/'admission').exists());self.assertEqual((base/'phase').read_text(),'APPLYING\n')
  self.assertNotEqual(run(*flags,held=False).returncode,0)
  self.assertNotEqual(run('--telegram-start','--held-telegram-guard').returncode,0)
  self.assertNotEqual(run('--receiver-recover','--migration-start','--held-telegram-guard').returncode,0)
  original=ticket.read_bytes();ticket.write_bytes(b'foreign\n');self.assertNotEqual(run(*flags).returncode,0);ticket.write_bytes(original)
  p=root/'usr/libexec/home-gateway-deploy/engine.sh';raw=p.read_bytes();p.write_bytes(b'foreign\n');self.assertNotEqual(run(*flags).returncode,0);p.write_bytes(raw)
  latest=root/'etc/home-gateway-deploy/latest';raw=latest.read_bytes();latest.write_bytes(b'tx.foreign\n');self.assertNotEqual(run(*flags).returncode,0);latest.write_bytes(raw)
  import json
  plan=base/'coordinator.json';raw=plan.read_bytes();value=json.loads(raw);value['was_running']=0;plan.write_text(json.dumps(value));self.assertNotEqual(run(*flags).returncode,0);plan.write_bytes(raw)
  anchor=latest.parent/latest.read_text().strip()
  for rel in ['backup/usr/bin/gateway','new.sha256','backup.sha256','commit','was-running','preflight.log']:
   target=anchor/rel;raw=target.read_bytes();target.write_bytes(b'corrupt\n');self.assertNotEqual(run(*flags).returncode,0,rel);target.write_bytes(raw)
  target=anchor/'backup/usr/bin/gateway';target.chmod(0o700);self.assertNotEqual(run(*flags).returncode,0);target.chmod(0o755)
  receipt=base/'handoff.json';raw=receipt.read_bytes();value=json.loads(raw);value['commit']='d'*40;receipt.write_text(json.dumps(value));self.assertNotEqual(run(*flags).returncode,0);receipt.write_bytes(raw)
  self.assertEqual(run(*flags).returncode,0)
  ram=root/'tmp/home-gateway-deploy.lock';ram.unlink();self.assertNotEqual(run(*flags).returncode,0)
if __name__=='__main__':unittest.main()
