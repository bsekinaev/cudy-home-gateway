"""Production ucode confirmations/state/locks with isolated fixed service boundary."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'src/usr/lib/home-gateway/actions.uc'


class ActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        for name in ('state', 'runtime', 'secrets', 'init'):
            (self.base / name).mkdir()
        (self.base / 'secrets/telegram.user_id').write_text('111\n')
        (self.base / 'secrets/telegram.chat_id').write_text('222\n')
        for service in ('tailscale', 'uhttpd'):
            (self.base / 'init' / service).write_text('''#!/bin/sh
if [ "$1" = restart ]; then
    printf 'restart\\n' >> "$HG_ACTION_TEST_BASE/executed"
    [ "${HG_ACTION_TEST_CRASH:-0}" = 0 ] || kill -9 "$PPID"
    [ "${HG_ACTION_TEST_WAIT:-0}" = 0 ] || sleep 1
fi
exit "${HG_ACTION_TEST_RC:-0}"
''')
            (self.base / 'init' / service).chmod(0o755)
        self.env = dict(os.environ, HG_ACTION_STATE_DIR=str(self.base / 'state'),
                        HG_ACTION_RUNTIME_DIR=str(self.base / 'runtime'),
                        HG_ACTION_SECRETS_DIR=str(self.base / 'secrets'),
                        HG_ACTION_INIT_DIR=str(self.base / 'init'),
                        HG_ACTION_TEST_BASE=str(self.base), HG_ACTION_POLICY_FILE=str(self.base / 'enabled'), HG_ACTION_EXECUTION_ENABLED='1')

    def run_action(self, *args):
        return subprocess.run(['ucode', str(ENGINE), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def prepare(self, action='restart-tailscale'):
        result = self.run_action('prepare', action, '111', '222', '900')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)['token']

    def confirm(self, token):
        return self.run_action('confirm', token, '111', '222', '900')

    def state(self):
        return json.loads((self.base / 'state/actions.json').read_text())

    def rewrite(self, state):
        (self.base / 'state/actions.json').write_text(json.dumps(state))

    def test_confirmation_runs_exact_service_once_and_private_audit(self):
        token = self.prepare()
        self.assertFalse((self.base / 'executed').exists())
        result = self.confirm(token)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'DONE')
        self.assertEqual(self.confirm(token).returncode, 75)
        self.assertEqual((self.base / 'executed').read_text(), 'restart\n')
        state = self.state()
        self.assertEqual(state['records'][0]['phase'], 'DONE')
        self.assertEqual((self.base / 'state/actions.json').stat().st_mode & 0o777, 0o600)
        shown = self.run_action('show')
        self.assertNotIn(token, shown.stdout)
        self.assertNotIn('111', shown.stdout)

    def test_openwrt_rc_common_shebang_is_honored(self):
        rc = self.base / 'rc.common'
        rc.write_text('#!/bin/sh\n[ "$2" != restart ] || echo restart >> "$HG_ACTION_TEST_BASE/executed"\nexit 0\n')
        service = self.base / 'init/tailscale'
        service.write_text('#!/bin/sh ' + str(rc) + '\nexit 97\n')
        token = self.prepare()
        self.assertEqual(self.confirm(token).returncode, 0)
        self.assertEqual((self.base / 'executed').read_text(), 'restart\n')

    def test_disabled_default_and_allowlist(self):
        self.env['HG_ACTION_EXECUTION_ENABLED'] = '0'
        self.assertEqual(self.run_action('prepare', 'restart-tailscale', '111', '222', '900').returncode, 70)
        self.env['HG_ACTION_EXECUTION_ENABLED'] = '1'
        for action in ('restart-network', 'restart-passwall2', 'restart-dnsmasq', 'restart-firewall', 'arbitrary;echo unsafe'):
            self.assertEqual(self.run_action('prepare', action, '111', '222', '900').returncode, 2)
        self.assertFalse((self.base / 'executed').exists())

    def test_user_chat_message_binding(self):
        token = self.prepare()
        for user, chat, message in [('999', '222', '900'), ('111', '999', '900'), ('111', '222', '901')]:
            self.assertEqual(self.run_action('confirm', token, user, chat, message).returncode, 77)
        self.assertFalse((self.base / 'executed').exists())

    def test_expired_future_clock_and_reboot_confirmations_rejected(self):
        for mutate in ('expired', 'future', 'boot'):
            token = self.prepare()
            data = self.state()
            row = data['records'][-1]
            if mutate == 'expired': row['created'] = int(time.time()) - 121
            if mutate == 'future': row['created'] = int(time.time()) + 121
            if mutate == 'boot': row['boot'] = '00000000-0000-0000-0000-000000000000'
            row['expires'] = row['created'] + 120
            self.rewrite(data)
            self.assertEqual(self.confirm(token).returncode, 75)
        self.assertFalse((self.base / 'executed').exists())

    def test_prepare_cancels_previous_same_resource(self):
        old = self.prepare()
        new = self.prepare()
        self.assertNotEqual(old, new)
        self.assertEqual(self.confirm(old).returncode, 75)
        self.assertEqual(self.confirm(new).returncode, 0)

    def test_crash_execution_is_unknown_and_never_replayed(self):
        token = self.prepare()
        data = self.state()
        row = data['records'][0]
        row['phase'] = 'EXECUTING'
        row['started'] = int(time.time())
        row['maintenance_until'] = row['started'] + 120
        self.rewrite(data)
        self.assertEqual(self.confirm(token).returncode, 75)
        self.assertEqual(self.state()['records'][0]['phase'], 'UNKNOWN')
        self.assertFalse((self.base / 'executed').exists())
        self.assertEqual(self.run_action('maintenance').stdout, 'NONE\n')

    def test_actual_sigkill_after_durable_consumption_never_reexecutes(self):
        token = self.prepare()
        self.env['HG_ACTION_TEST_WAIT'] = '1'
        child = subprocess.Popen(['ucode', str(ENGINE), 'confirm', token, '111', '222', '900'],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, start_new_session=True)
        import signal
        self.addCleanup(lambda: self._kill_group(child.pid))
        deadline = time.monotonic() + 3
        while not (self.base / 'executed').exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue((self.base / 'executed').exists())
        self.assertEqual(self.state()['records'][0]['phase'], 'EXECUTING')
        child.kill()
        child.wait(timeout=5)
        # Service child still runs: CLOEXEC must release locks after engine death.
        self.assertEqual(self.confirm(token).returncode, 75)
        self.assertEqual(self.state()['records'][0]['phase'], 'UNKNOWN')
        self.assertEqual((self.base / 'executed').read_text(), 'restart\n')
        self._kill_group(child.pid)
        child.stdout.close()
        child.stderr.close()

    @staticmethod
    def _kill_group(pid):
        import signal
        try: os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError: pass

    def test_failed_restart_is_terminal_and_replay_protected(self):
        token = self.prepare()
        self.env['HG_ACTION_TEST_RC'] = '1'
        result = self.confirm(token)
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertEqual(self.state()['records'][0]['phase'], 'FAILED')
        self.assertEqual(self.confirm(token).returncode, 75)
        self.assertEqual((self.base / 'executed').read_text(), 'restart\n')
        self.assertEqual(self.run_action('maintenance').stdout, 'NONE\n')

    def test_kernel_locks_exclude_parallel_confirmation(self):
        token = self.prepare()
        for path in ('actions.lock', 'action-tailscale.lock'):
            with (self.base / 'runtime' / path).open('a') as f:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(self.confirm(token).returncode, 73)
                self.assertFalse((self.base / 'executed').exists())
        self.assertEqual(self.confirm(token).returncode, 0)

    def test_corrupt_oversized_or_symlink_state_is_fail_closed(self):
        token = self.prepare()
        file = self.base / 'state/actions.json'
        for raw in ('{', 'x' * 131073, '{"schema_version":1,"records":[{}]}'):
            file.write_text(raw)
            self.assertEqual(self.confirm(token).returncode, 70)
        file.unlink()
        file.symlink_to(self.base / 'secrets/telegram.user_id')
        self.assertEqual(self.confirm(token).returncode, 70)
        self.assertFalse((self.base / 'executed').exists())

    def test_untrusted_ancestors_and_writable_service_are_rejected(self):
        parent=self.base/'writable'; parent.mkdir(); parent.chmod(0o777)
        self.env['HG_ACTION_RUNTIME_DIR']=str(parent/'runtime')
        result=self.run_action('prepare','restart-tailscale','111','222','900')
        self.assertEqual(result.returncode,70)
        self.env['HG_ACTION_RUNTIME_DIR']=str(self.base/'runtime')
        token=self.prepare()
        (self.base/'init/tailscale').chmod(0o777)
        self.assertEqual(self.confirm(token).returncode,70)
        self.assertEqual(self.state()['records'][-1]['phase'],'PENDING')
        self.assertFalse((self.base/'executed').exists())

    def test_invalid_phase_and_writable_state_are_corrupt(self):
        token=self.prepare()
        data=self.state(); data['records'][0]['phase']='BOGUS'; self.rewrite(data)
        self.assertEqual(self.confirm(token).returncode,70)
        (self.base/'state/actions.json').chmod(0o666)
        self.assertEqual(self.confirm(token).returncode,70)
        self.assertFalse((self.base/'executed').exists())

    def test_health_maintenance_masks_only_tailscale(self):
        self.prepare()
        data=self.state(); now=int(time.time())
        data['records'][0].update(phase='EXECUTING',started=now,maintenance_until=now+120)
        self.rewrite(data)
        env=dict(self.env,HG_LIBDIR=str(ROOT/'src/usr/lib/home-gateway'))
        script = '. "$HG_LIBDIR/common.sh"; . "$HG_LIBDIR/health.sh"; hg_status_collect() { :; }; HG_NETWORK_WAN_STATE=OK; HG_DNS_STATE=OK; HG_VPN_MAIN_STATE=OK; HG_TAILSCALE_STATE=DOWN; hg_health_collect; printf "%s %s %s %s\\n" "$HG_HEALTH_WAN_STATE" "$HG_HEALTH_DNS_STATE" "$HG_HEALTH_MAIN_STATE" "$HG_HEALTH_TAILSCALE_STATE"'
        r=subprocess.run([os.environ.get('HG_TEST_BUSYBOX','busybox'),'ash','-c',script],env=env,capture_output=True,text=True,timeout=5)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout.strip(),'OK OK OK MAINTENANCE')

    def test_maintenance_is_bounded_and_only_for_matching_boot(self):
        self.prepare()
        data = self.state()
        row = data['records'][0]
        row.update(phase='EXECUTING', started=int(time.time()), maintenance_until=int(time.time())+120)
        self.rewrite(data)
        self.assertEqual(self.run_action('maintenance').stdout, 'MAINTENANCE\n')
        row['maintenance_until'] = row['started'] + 121
        self.rewrite(data)
        self.assertEqual(self.run_action('maintenance').stdout, 'NONE\n')
        row['maintenance_until'] = row['started'] - 1
        self.rewrite(data)
        self.assertEqual(self.run_action('maintenance').stdout, 'NONE\n')


class TelegramActionTests(unittest.TestCase):
    setUp = ActionTests.setUp
    state = ActionTests.state
    rewrite = ActionTests.rewrite

    def poll(self, update):
        import shlex
        self.env.update(HG_LIBDIR=str(ROOT / 'src/usr/lib/home-gateway'),
                        HG_TELEGRAM_RUNTIME_DIR=str(self.base / 'runtime'),
                        HG_TELEGRAM_SECRETS_DIR=str(self.base / 'secrets'),
                        HG_ACTION_TEST_BUSYBOX=os.environ.get('HG_TEST_BUSYBOX', 'busybox'),
                        HG_ACTION_TEST_GATEWAY=str(ROOT / 'src/usr/bin/gateway'))
        helper = self.base / 'bridge.py'
        helper.write_text('''import json,os,pathlib,subprocess,sys
base=pathlib.Path(os.environ['HG_ACTION_TEST_BASE']); args=sys.argv[1:]
with (base/'calls').open('a') as f: f.write(json.dumps(args)+'\\n')
if args[0]=='actions':
 r=subprocess.run([os.environ['HG_ACTION_TEST_BUSYBOX'],'ash',os.environ['HG_ACTION_TEST_GATEWAY'],*args],capture_output=True)
 sys.stdout.buffer.write(r.stdout); sys.exit(r.returncode)
if args[:2]==['telegram','get-updates']: print(json.dumps({'ok':True,'result':json.loads((base/'updates').read_text())}))
else: print(json.dumps({'ok':True,'result':{'message_id':900}}))
''')
        bridge = self.base / 'gateway'
        bridge.write_text('#!/bin/sh\nexec python3 '+shlex.quote(str(helper))+' "$@"\n')
        (self.base / 'updates').write_text(json.dumps([update]))
        r=subprocess.run(['ucode',str(ROOT/'src/usr/lib/home-gateway/telegram-poller.uc'),str(bridge),'once'],
                         env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(r.returncode,0,r.stderr)
        return [json.loads(line) for line in (self.base/'calls').read_text().splitlines()]

    def menu(self, user=111):
        calls=self.poll({'update_id':1,'message':{'from':{'id':user},'chat':{'id':222},'date':int(time.time()),'text':'/actions'}})
        sent=next((c for c in calls if c[:2]==['telegram','send-message']),None)
        return calls,sent

    def callback(self, data, message=900, user=111, update_id=2):
        return self.poll({'update_id':update_id,'callback_query':{'id':'cb','from':{'id':user},
                          'message':{'chat':{'id':222},'message_id':message},'data':data}})

    def confirmation(self):
        calls,sent=self.menu()
        button=json.loads(sent[4])['inline_keyboard'][0][0]
        self.callback(button['callback_data'])
        self.assertFalse((self.base/'executed').exists())
        row=self.state()['records'][-1]
        return 'confirm:'+row['token']

    def test_end_to_end_prepare_confirm_and_replay(self):
        callback=self.confirmation()
        self.callback(callback,update_id=3)
        self.assertEqual((self.base/'executed').read_text(),'restart\n')
        self.callback(callback,update_id=4)
        self.assertEqual((self.base/'executed').read_text(),'restart\n')

    def test_wrong_identity_message_and_expired_confirm_never_execute(self):
        callback=self.confirmation()
        self.callback(callback,user=999,update_id=3)
        self.callback(callback,message=901,update_id=4)
        data=self.state(); row=data['records'][-1]
        row['created']=int(time.time())-121;row['expires']=row['created']+120
        self.rewrite(data)
        self.callback(callback,update_id=5)
        self.assertFalse((self.base/'executed').exists())

    def test_status_cancels_pending_confirmation(self):
        callback=self.confirmation()
        self.poll({'update_id':4,'message':{'from':{'id':111},'chat':{'id':222},'date':int(time.time()),'text':'/status'}})
        self.callback(callback,update_id=5)
        self.assertEqual(self.state()['records'][0]['phase'],'CANCELLED')
        self.assertFalse((self.base/'executed').exists())

    def test_disabled_menu_has_no_prepare_buttons(self):
        self.env['HG_ACTION_EXECUTION_ENABLED']='0'
        _,sent=self.menu()
        self.assertNotIn('prepare-',sent[4])
        self.assertIn('отключено',sent[3])
        self.assertFalse((self.base/'executed').exists())

    def test_wrong_user_never_gets_action_menu(self):
        calls,sent=self.menu(user=999)
        self.assertIsNone(sent)
        self.assertFalse(any(c[0]=='actions' for c in calls))


if __name__ == '__main__':
    unittest.main()
