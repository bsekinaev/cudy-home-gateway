"""Production keeper over an isolated nft process boundary; no live network writes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GATEWAY = ROOT / 'src/usr/bin/gateway'
RULE = 'ip saddr 192.168.1.140 meta l4proto udp counter packets 12 bytes 345 return comment "ASATA-UDP-DIRECT" # handle 7\n'


def chain(rules):
    return 'table inet passwall2 {\n chain PSW2_MANGLE {\n' + rules + ' }\n}\n'


class KeeperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        (self.base / 'bin').mkdir()
        nft = self.base / 'bin/nft'
        nft.write_text('''#!/bin/sh
if [ "$1" = '-a' ]; then
    [ "${HG_KEEPER_IGNORE_TERM:-0}" = 0 ] || trap '' TERM
    [ "${HG_KEEPER_LIST_STALL:-0}" = 0 ] || exec sleep 30
    cat "$HG_KEEPER_FIXTURE/rules"
    exit "${HG_KEEPER_LIST_RC:-0}"
fi
if [ "$1" = '-f' ]; then
    cat "$2" > "$HG_KEEPER_FIXTURE/applied"
    [ "${HG_KEEPER_APPLY_RC:-0}" = 0 ] || exit 1
    if [ "${HG_KEEPER_POST_INVALID:-0}" = 0 ]; then
        printf 'table inet passwall2 {\n chain PSW2_MANGLE {\n ip saddr 192.168.1.140 meta l4proto udp counter packets 0 bytes 0 return comment "ASATA-UDP-DIRECT" # handle 99\n }\n}\n' > "$HG_KEEPER_FIXTURE/rules"
    fi
    exit 0
fi
exit 97
''')
        nft.chmod(0o755)
        logger = self.base / 'bin/logger'
        logger.write_text('#!/bin/sh\nexit 0\n')
        logger.chmod(0o755)
        # nft/stat process boundaries emulate root metadata on non-root CI workers.
        stat = self.base / 'bin/stat'
        stat.write_text('#!/bin/sh\nif [ "$1" = -c ] && [ "$2" = %u ]; then echo 0; else exec /usr/bin/stat "$@"; fi\n')
        stat.chmod(0o755)
        self.busybox = os.environ.get('HG_TEST_BUSYBOX', 'busybox')
        self.env = dict(os.environ, PATH=str(self.base / 'bin') + ':' + os.environ['PATH'],
                        HG_LIBDIR=str(ROOT / 'src/usr/lib/home-gateway'),
                        HG_ASATA_KEEPER_RUNTIME_DIR=str(self.base / 'runtime'),
                        HG_KEEPER_FIXTURE=str(self.base))
        (self.base / 'rules').write_text(chain(RULE))

    def keeper(self, mode='check', authorized=False):
        env = dict(self.env, HG_ASATA_KEEPER_AUTHORIZED='1' if authorized else '0')
        return subprocess.run([self.busybox, 'ash', str(GATEWAY), 'asata-keeper', mode],
                              env=env, text=True, capture_output=True, timeout=8)

    def test_exact_first_rule_needs_no_write(self):
        for mode in ('check', 'repair'):
            result = self.keeper(mode, True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'ASATA_KEEPER=OK\n')
            self.assertFalse((self.base / 'applied').exists())

    def test_repair_disabled_even_with_bad_rule(self):
        (self.base / 'rules').write_text(chain(''))
        self.assertEqual(self.keeper('repair').returncode, 70)
        self.assertFalse((self.base / 'applied').exists())

    def test_semantics_and_order_are_checked(self):
        wrong = [RULE.replace('.140 ', '.140/24 '), RULE.replace('udp ', 'tcp '),
                 RULE.replace('return ', 'accept '), RULE.replace('counter ', 'udp dport 53 counter '),
                 RULE.replace('return ', 'meta mark set 1 return '),
                 'meta l4proto tcp return # handle 2\n' + RULE, RULE + RULE.replace('handle 7', 'handle 8')]
        for rules in wrong:
            with self.subTest(rules=rules):
                (self.base / 'rules').write_text(chain(rules))
                self.assertEqual(self.keeper().returncode, 1)
                self.assertFalse((self.base / 'applied').exists())

    def test_existing_marked_rule_never_mutated_by_stale_handle(self):
        (self.base / 'rules').write_text(chain('meta l4proto tcp return # handle 2\n' + RULE + RULE.replace('handle 7','handle 8').replace('return ', 'accept ')))
        result = self.keeper('repair', True)
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn('OWNER_COORDINATION_REQUIRED', result.stdout)
        self.assertFalse((self.base / 'applied').exists())

    def test_missing_rule_insert_preserves_every_existing_handle(self):
        (self.base / 'rules').write_text(chain('meta l4proto tcp return # handle 2\n'))
        result = self.keeper('repair', True)
        self.assertEqual(result.returncode, 0, result.stderr)
        batch = (self.base / 'applied').read_text()
        self.assertNotIn('delete', batch)
        self.assertEqual(len(batch.splitlines()), 1)
        self.assertIn('insert rule inet passwall2 PSW2_MANGLE ip saddr 192.168.1.140 meta l4proto udp counter return', batch)

    def test_failed_list_and_apply_do_not_claim_success(self):
        self.env['HG_KEEPER_LIST_RC'] = '1'
        self.assertEqual(self.keeper('repair', True).returncode, 70)
        self.assertFalse((self.base / 'applied').exists())
        del self.env['HG_KEEPER_LIST_RC']
        (self.base / 'rules').write_text(chain(''))
        self.env['HG_KEEPER_APPLY_RC'] = '1'
        result = self.keeper('repair', True)
        self.assertEqual(result.returncode, 70)
        self.assertNotIn('REPAIRED', result.stdout)

    def test_corrupt_or_oversized_chain_never_applied(self):
        for rules in [RULE, chain(RULE.replace('handle 7', 'handle invalid')),
                      chain(RULE.replace('handle 7','handle 12345678901')),
                      chain(RULE * 2), chain('ip saddr 192.168.1.1 return\n' + RULE), chain('x' * 65537)]:
            (self.base / 'rules').write_text(rules)
            self.assertEqual(self.keeper('repair', True).returncode, 70)
            self.assertFalse((self.base / 'applied').exists())

    def test_lock_excludes_parallel_process_and_recovers_after_crash(self):
        runtime = self.base / 'runtime'
        runtime.mkdir()
        # This test holds the actual kernel flock, then kills its owner (no PID-directory simulation).
        import sys
        child = subprocess.Popen([sys.executable, '-c',
            'import fcntl,signal,sys; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); print("locked",flush=True); signal.pause()',
            str(runtime / 'asata-keeper.lock')], stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        self.assertEqual(child.stdout.readline().strip(), 'locked')
        self.assertEqual(self.keeper('repair', True).returncode, 73)
        child.kill()
        child.wait(timeout=5)
        child.stdout.close()
        self.assertEqual(self.keeper().returncode, 0)

    def test_zero_exit_without_valid_postcheck_is_failure(self):
        (self.base / 'rules').write_text(chain(''))
        self.env['HG_KEEPER_POST_INVALID'] = '1'
        result = self.keeper('repair', True)
        self.assertEqual(result.returncode, 70)
        self.assertNotIn('REPAIRED', result.stdout)

    def test_hung_nft_is_bounded_and_never_applied(self):
        self.env['HG_KEEPER_LIST_STALL'] = '1'
        self.env['HG_KEEPER_IGNORE_TERM'] = '1'
        self.assertEqual(self.keeper('repair', True).returncode, 70)
        self.assertFalse((self.base / 'applied').exists())

    def test_loop_is_opt_in_singleton_and_recovers_after_group_crash(self):
        self.assertEqual(self.keeper('loop').returncode, 70)
        env = dict(self.env, HG_ASATA_KEEPER_AUTHORIZED='1')
        child = subprocess.Popen([self.busybox, 'ash', str(GATEWAY), 'asata-keeper', 'loop'],
                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, start_new_session=True)
        import signal
        self.addCleanup(lambda: child.poll() is None and os.killpg(child.pid, signal.SIGKILL))
        self.assertEqual(child.stdout.readline().strip(), 'ASATA_KEEPER=OK')
        self.assertEqual(self.keeper('loop', True).returncode, 73)
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)
        child.stdout.close()
        child.stderr.close()
        self.assertEqual(self.keeper().returncode, 0)

    def test_untrusted_ancestor_and_symlink_runtime_are_rejected(self):
        parent = self.base / 'writable'
        parent.mkdir(mode=0o777)
        parent.chmod(0o777)
        self.env['HG_ASATA_KEEPER_RUNTIME_DIR'] = str(parent / 'runtime')
        self.assertEqual(self.keeper('repair', True).returncode, 70)
        alias = self.base / 'alias'
        alias.symlink_to(self.base / 'runtime', target_is_directory=True)
        self.env['HG_ASATA_KEEPER_RUNTIME_DIR'] = str(alias)
        self.assertEqual(self.keeper('repair', True).returncode, 70)
        self.assertFalse((self.base / 'applied').exists())

    def test_nonroot_runtime_owner_is_rejected(self):
        tools = self.base / 'bin'
        stat = tools / 'stat'
        stat.write_text('#!/bin/sh\nif [ "$1" = -c ] && [ "$2" = %u ]; then echo 1000; else exec /usr/bin/stat "$@"; fi\n')
        stat.chmod(0o755)
        self.assertEqual(self.keeper('repair', True).returncode, 70)
        self.assertFalse((self.base / 'applied').exists())

    def test_doctor_distinguishes_busy_from_bad_semantics(self):
        import fcntl
        runtime = self.base / 'runtime'
        runtime.mkdir()
        with (runtime / 'asata-keeper.lock').open('w') as file:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            script = '. "$HG_LIBDIR/common.sh"; . "$HG_LIBDIR/doctor.sh"; hg_doctor_asata; printf "FAIL=%s\\n" "$HG_DOCTOR_FAIL"'
            result = subprocess.run([self.busybox, 'ash', '-c', script], env=self.env,
                                    text=True, capture_output=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('[WARN]', result.stdout)
            self.assertIn('FAIL=0', result.stdout)

    def test_arguments_are_fixed(self):
        self.assertEqual(self.keeper('arbitrary').returncode, 2)
        self.assertFalse((self.base / 'applied').exists())


if __name__ == '__main__':
    unittest.main()
