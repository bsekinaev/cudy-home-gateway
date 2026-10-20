"""Production keeper over an isolated nft process boundary; no live network writes."""
import os
import re,json,shutil
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
        stat.write_text("#!/bin/sh\nif [ \"$1\" = -c ] && [ \"$2\" = %u ]; then echo 0; elif [ \"$1\" = -c ] && [ \"$2\" = '%u %a %F' ]; then /usr/bin/stat -c '%a %F' \"$3\" | sed 's/^/0 /'; else exec /usr/bin/stat \"$@\"; fi\n")
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

    def test_existing_shared_runtime_rejected_without_chmod(self):
        shared = self.base / 'shared'
        shared.mkdir(mode=0o1777)
        shared.chmod(0o1777)
        self.env['HG_ASATA_KEEPER_RUNTIME_DIR'] = str(shared)
        self.assertEqual(self.keeper().returncode, 70)
        self.assertEqual(shared.stat().st_mode & 0o7777, 0o1777)
        self.assertFalse((shared / 'asata-keeper.lock').exists())

    def test_exact_first_rule_needs_no_write(self):
        for mode in ('check', 'repair'):
            result = self.keeper(mode, True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'ASATA_KEEPER=OK\n')
            self.assertFalse((self.base / 'applied').exists())

    def test_owner_position_15_shape_with_numeric_and_symbolic_protocol(self):
        # Structural reproduction only: client IP/MAC are synthetic, not owner data.
        lease=self.base/'leases';lease.write_text('0 58:04:4f:81:09:6b 192.168.1.140 fixture *\n')
        self.env['HG_ASATA_LEASE_FILE']=str(lease)
        ip=self.base/'bin/ip';ip.write_text('#!/bin/sh\nexit 0\n');ip.chmod(0o755)
        prefix=['ip daddr @psw2_vps counter packets 0 bytes 0 return',
                'ct direction 1 counter packets 0 bytes 0 return',
                'ip daddr @psw2_wan counter packets 0 bytes 0 return']
        for guard in ['ether saddr 02:00:00:00:00:02','ip saddr 192.0.2.228']:
            for tail in ['udp dport 53 return','ip daddr 198.18.0.0/16 jump PSW2_RULE',
                         'jump PSW2_RULE','meta mark 0x50535732 tproxy ip to :2003','return']:
                prefix.append('ip protocol 17 '+guard+' '+tail.replace(' return',' counter packets 0 bytes 0 return'))
        prefix.append('ip protocol 17 udp dport 53 counter packets 0 bytes 0 return')
        rows=''.join(r+' # handle '+str(i+100)+'\n' for i,r in enumerate(prefix))
        self.assertEqual(len(prefix),14)
        for proto in ['udp','17']:
            (self.base/'rules').write_text(chain(rows+RULE.replace('l4proto udp','l4proto '+proto)))
            r=self.keeper();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
            self.assertFalse((self.base/'applied').exists())
            script='. "$HG_LIBDIR/common.sh"; . "$HG_LIBDIR/doctor.sh"; hg_doctor_asata; printf "FAIL=%s\\n" "$HG_DOCTOR_FAIL"'
            d=subprocess.run([self.busybox,'ash','-c',script],env=self.env,capture_output=True,text=True,timeout=8)
            self.assertEqual(d.returncode,0,d.stderr);self.assertIn('FAIL=0',d.stdout)
        (self.base/'rules').write_text(chain(rows.replace('02:00:00:00:00:02','58:04:4f:81:09:6b')+RULE))
        self.assertEqual(self.keeper().returncode,1) # ASATA itself must not be exempted
        (self.base/'rules').write_text(chain(rows+RULE))
        lease.write_text('')
        self.assertEqual(self.keeper().returncode,1) # no MAC exclusion without identity
        ip.write_text('#!/bin/sh\necho "192.168.1.140 dev br-lan lladdr 02:00:00:00:00:02 REACHABLE"\n')
        lease.write_text('0 58:04:4f:81:09:6b 192.168.1.140 fixture *\n')
        self.assertEqual(self.keeper().returncode,1) # conflicting current identity

    def test_intercepting_or_unproven_prefix_remains_blocked(self):
        bad=['meta l4proto udp jump PSW2_RULE',
             'ip saddr 192.168.1.140 meta mark 1 tproxy ip to :2003',
             'ip saddr 192.168.1.0/24 jump PSW2_RULE',
             'ip saddr != 192.0.2.228 jump PSW2_RULE',
             'meta mark set 1 ip saddr 192.0.2.228 return',
             'ip saddr 192.168.001.140 jump PSW2_RULE',
             'ip daddr @psw2_vps meta mark set 1 return']
        for prefix in bad:
            with self.subTest(prefix=prefix):
                (self.base/'rules').write_text(chain(prefix+' # handle 92\n'+RULE))
                self.assertEqual(self.keeper().returncode,1)
                self.assertFalse((self.base/'applied').exists())

    @unittest.skipUnless(shutil.which('ucode'),'ucode required')
    def test_exact_candidate_preflight_script_is_read_only_and_refuses_bad_prefix(self):
        source=(ROOT/'scripts/migration_rc/rc-b.uc').read_text()
        literal=re.search(r"const probe=('.*');",source).group(1)
        result=subprocess.run(['ucode','-e','print('+literal+');'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        args=[self.busybox,'ash','-c',result.stdout,'preflight',str(ROOT/'src/usr/lib/home-gateway/asata.sh')]
        p=subprocess.run(args,env=self.env,capture_output=True,text=True,timeout=8)
        self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout,'RC_B_ASATA_PREFLIGHT=PASS\n')
        self.assertFalse((self.base/'runtime').exists())
        (self.base/'rules').write_text(chain('meta l4proto udp jump PSW2_RULE # handle 91\n'+RULE))
        p=subprocess.run(args,env=self.env,capture_output=True,text=True,timeout=8)
        self.assertNotEqual(p.returncode,0);self.assertFalse((self.base/'runtime').exists())

    def test_repair_disabled_even_with_bad_rule(self):
        (self.base / 'rules').write_text(chain(''))
        self.assertEqual(self.keeper('repair').returncode, 70)
        self.assertFalse((self.base / 'applied').exists())

    def test_semantics_and_order_are_checked(self):
        wrong = [RULE.replace('.140 ', '.140/24 '), RULE.replace('udp ', 'tcp '),
                 RULE.replace('return ', 'accept '), RULE.replace('counter ', 'udp dport 53 counter '),
                 RULE.replace('return ', 'meta mark set 1 return '),
                 'meta l4proto udp jump PSW2_RULE # handle 2\n' + RULE, RULE + RULE.replace('handle 7', 'handle 8')]
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

    def test_missing_rule_also_requires_writer_coordination(self):
        (self.base / 'rules').write_text(chain('meta l4proto tcp return # handle 2\n'))
        result = self.keeper('repair', True)
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn('OWNER_COORDINATION_REQUIRED', result.stdout)
        self.assertFalse((self.base / 'applied').exists())

    def test_atomic_metadata_rejects_root_owned_symlink_to_directory(self):
        target = self.base / 'target'
        target.mkdir()
        (self.base / 'runtime').symlink_to(target, target_is_directory=True)
        self.assertEqual(self.keeper('repair', True).returncode, 70)
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.base / 'applied').exists())

    def test_failed_list_and_blocked_mutation_do_not_claim_success(self):
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
        runtime.mkdir(mode=0o700)
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

    def test_legacy_apply_boundary_is_never_reached(self):
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
        stat.write_text("#!/bin/sh\nif [ \"$1\" = -c ] && [ \"$2\" = '%u %a %F' ]; then echo '1000 755 directory'; else exec /usr/bin/stat \"$@\"; fi\n")
        stat.chmod(0o755)
        self.assertEqual(self.keeper('repair', True).returncode, 70)
        self.assertFalse((self.base / 'applied').exists())

    def test_doctor_distinguishes_busy_from_bad_semantics(self):
        import fcntl
        runtime = self.base / 'runtime'
        runtime.mkdir(mode=0o700)
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
