"""Real ucode scheduler deadline checks (run in the offline test image)."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'src/usr/lib/home-gateway/notifications.uc'

class SchedulerTests(unittest.TestCase):
    def test_recovery_deadline_kills_descendants_and_observes(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            target = base / 'gateway'
            target.write_text('''#!/bin/sh
if [ "$*" = "notifications recover" ]; then
  (trap '' TERM; while :; do sleep 1; echo alive >> "$HG_TEST_BASE/alive"; done) &
  wait
fi
if [ "$*" = "incidents tick" ]; then touch "$HG_TEST_BASE/tick"; fi
''')
            env = dict(os.environ, HG_TEST_BASE=folder,
                       HG_NOTIFICATION_RUNTIME_DIR=folder+'/runtime',
                       HG_NOTIFICATION_STATE_DIR=folder+'/state')
            proc = subprocess.Popen(['ucode', str(ENGINE), str(target), 'loop'], env=env,
                                    start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                limit = time.monotonic() + 6
                heartbeat = {}
                path = base/'runtime/monitor-heartbeat.json'
                # The child writes tick before its parent publishes the completed
                # cycle heartbeat; wait for both independently observed facts.
                while time.monotonic() < limit:
                    if path.exists(): heartbeat = json.loads(path.read_text())
                    if (base/'tick').exists() and 'recovery_result' in heartbeat: break
                    time.sleep(.05)
                self.assertTrue((base/'tick').exists(), 'hung recovery blocked observation')
                self.assertEqual(heartbeat['recovery_result'], 'TIMEOUT')
                count = (base/'alive').stat().st_size
                time.sleep(1.2)
                self.assertEqual((base/'alive').stat().st_size, count, 'grandchild survived deadline')
            finally:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.communicate(timeout=3)

    def test_observation_deadline_and_incarnation_envelope(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            target = base/'gateway'
            target.write_text('''#!/bin/sh
if [ "$*" = "incidents tick" ]; then
  printf '%s %s %s' "$HG_MONITOR_ACTIVE" "$HG_MONITOR_INCARNATION" "$HG_MONITOR_SEQUENCE" > "$HG_TEST_BASE/envelope"
  trap '' TERM
  while :; do sleep 1; done
fi
''')
            env = dict(os.environ, HG_TEST_BASE=folder,
                       HG_NOTIFICATION_RUNTIME_DIR=folder+'/runtime',
                       HG_NOTIFICATION_STATE_DIR=folder+'/state')
            proc = subprocess.Popen(['ucode', str(ENGINE), str(target), 'loop'], env=env,
                                    start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            started = time.monotonic()
            try:
                path = base/'runtime/monitor-heartbeat.json'
                status = {}
                while time.monotonic()-started < 39:
                    if path.exists(): status = json.loads(path.read_text())
                    if status.get('observation_result') == 'TIMEOUT': break
                    time.sleep(.05)
                self.assertEqual(status.get('observation_result'), 'TIMEOUT')
                self.assertEqual(status['delivery_result'], 'SKIPPED')
                self.assertLess(time.monotonic()-started, 38)
                active, incarnation, sequence = (base/'envelope').read_text().split()
                self.assertEqual((active, sequence), ('1', '1'))
                self.assertEqual(incarnation, status['worker_incarnation'])
                self.assertAlmostEqual(status['next_due_monotonic']-status['scheduled_monotonic'], 60, places=5)
            finally:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.communicate(timeout=3)
    def test_monitored_dispatch_processes_only_one_queue_item(self):
        import test_notifications
        fixture = test_notifications.DispatcherTests('test_success_and_no_resend_after_process_restart')
        fixture.setUp()
        try:
            fixture.journal([fixture.event(), fixture.event(component='dns', incident='dns-101', at=101)])
            fixture.env['HG_MONITOR_ACTIVE'] = '1'
            fixture.run_cli('dispatch')
            self.assertEqual(len(fixture.calls()), 1)
            self.assertEqual([item['status'] for item in fixture.queue()], ['SENT', 'PENDING'])
        finally:
            fixture.doCleanups()
    def test_killing_worker_drains_detached_observation_descendants(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            target = base/'gateway'
            target.write_text('''#!/bin/sh
if [ "$*" = "incidents tick" ]; then
  trap '' TERM
  while :; do echo alive >> "$HG_TEST_BASE/alive"; sleep .1; done
fi
''')
            env = dict(os.environ, HG_TEST_BASE=folder,
                       HG_NOTIFICATION_RUNTIME_DIR=folder+'/runtime',
                       HG_NOTIFICATION_STATE_DIR=folder+'/state')
            proc = subprocess.Popen(['ucode', str(ENGINE), str(target), 'loop'], env=env,
                                    start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                until = time.monotonic()+3
                while not (base/'alive').exists() and time.monotonic()<until: time.sleep(.02)
                self.assertTrue((base/'alive').exists())
                proc.kill()
                proc.communicate(timeout=3)
                time.sleep(.4)
                count = (base/'alive').stat().st_size
                time.sleep(.3)
                self.assertEqual((base/'alive').stat().st_size, count)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate(timeout=3)
    def test_committed_observation_with_history_failure_still_dispatches(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder); target=base/'gateway'
            target.write_text('#!/bin/sh\nif [ "$*" = "incidents tick" ]; then exit 75; fi\nif [ "$*" = "notifications dispatch" ]; then touch "$HG_TEST_BASE/dispatched"; fi\n')
            env=dict(os.environ,HG_TEST_BASE=folder,HG_NOTIFICATION_RUNTIME_DIR=folder+'/runtime',HG_NOTIFICATION_STATE_DIR=folder+'/state')
            proc=subprocess.Popen(['ucode',str(ENGINE),str(target),'loop'],env=env,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                until=time.monotonic()+3
                while not (base/'dispatched').exists() and time.monotonic()<until: time.sleep(.02)
                self.assertTrue((base/'dispatched').exists(),'history failure blocked committed incident delivery')
            finally:
                os.killpg(proc.pid,signal.SIGTERM); proc.communicate(timeout=3)

if __name__ == '__main__': unittest.main()
