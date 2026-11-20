"""Power-loss tail recovery keeps the delivery journal usable."""
import os, subprocess, unittest
import test_monitor_history as fixtures
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class JournalTailTests(unittest.TestCase):
 def setUp(self):
  self.f=fixtures.MonitorHistoryTests('test_three_unique_failures_two_unique_successes_and_unknown')
  self.f.setUp(); self.addCleanup(self.f.doCleanups)
 def sync(self):
  return subprocess.run(['ucode',str(ROOT/'src/usr/lib/home-gateway/notifications.uc'),str(self.f.gateway),'sync'],env=self.f.env,capture_output=True,text=True,timeout=5)
 def test_partial_power_loss_tail_is_removed_before_next_tick(self):
  for t in (10,20,30): self.f.tick(t)
  path=self.f.base/'state/incidents.jsonl'; complete=path.read_bytes()
  with path.open('ab') as f: f.write(b'{"schema_version":1,"event":"RECOV')
  self.f.tick(40,'UNKNOWN')
  self.assertEqual(path.read_bytes(),complete)
  self.assertEqual(self.sync().returncode,0)
  self.assertEqual(self.f.status()['active_count'],1)
  self.assertTrue(self.f.summary()['truncated'])
 def test_complete_record_missing_only_newline_is_preserved(self):
  for t in (10,20,30): self.f.tick(t)
  path=self.f.base/'state/incidents.jsonl'; complete=path.read_bytes()
  path.write_bytes(complete.rstrip(b'\n')); self.f.tick(40,'UNKNOWN')
  self.assertEqual(path.read_bytes(),complete)
  self.assertEqual(self.sync().returncode,0)
 def test_interior_corruption_is_not_silently_deleted(self):
  for t in (10,20,30): self.f.tick(t)
  path=self.f.base/'state/incidents.jsonl'
  content=b'broken interior\n'+path.read_bytes(); path.write_bytes(content)
  self.f.tick(40,'UNKNOWN')
  self.assertEqual(path.read_bytes(),content)
  self.assertNotEqual(self.sync().returncode,0)
if __name__=='__main__': unittest.main()
