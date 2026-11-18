"""Run the actual read-only target module with pinned native ucode.

Synthetic filesystem fixtures do not assert a real OpenWrt/procd lifecycle.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from parent import PATHS, CONTROLS, ORIGINAL, git

MODULE = Path(__file__).with_name('protocol.uc')


@unittest.skipUnless(shutil.which('ucode'), 'native ucode required')
class ProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        repo = MODULE.parents[2]
        cls.control_bytes = {path: git(repo, 'show', ORIGINAL + ':scripts/deploy/' + source)
                             for source, path in CONTROLS}
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.protocol_environment = {}
        self.borrow_action_guard = False
        self.put('.hg-owner-series-test-root', b'HG_OWNER_SERIES_TEST_ROOT_V1\n')
        self.inventory = {}
        for path in PATHS:
            data = ('fixture: ' + path + '\n').encode()
            self.put(path, data, 0o755 if path in PATHS[:3] else 0o644)
            self.inventory[path] = hashlib.sha256(data).hexdigest()

    def put(self, path, data, mode=0o600):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        for parent in target.parents:
            if parent == self.root:
                break
            if self.root in parent.parents:
                parent.chmod(0o700)
        target.write_bytes(data)
        target.chmod(mode)
        return target

    def snapshot(self):
        result = {}
        for path in sorted(self.root.rglob('*')):
            st = path.lstat()
            result[str(path.relative_to(self.root))] = (st.st_mode, st.st_mtime_ns,
                os.readlink(path) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else '')
        return result

    def run_protocol(self, operation, data=None):
        before = self.snapshot()
        if not MODULE.exists():
            self.fail('read-only native target protocol is missing')
        code = ('import { open_protocol } from ' + json.dumps(str(MODULE)) + ';'
                'import * as fs from "fs";let p=open_protocol(ARGV[0]);')
        if self.borrow_action_guard:
            code += ('let guard=fs.open(ARGV[0]+"/tmp/home-gateway/actions.lock","re");'
                     'if(!guard || guard.lock("xn")==null)die("TEST_LOCK");'
                     'let value=p.actions(guard);'
                     'if(guard.fileno()==null || guard.lock("xn")==null)die("BORROWED_LOCK_CLOSED");'
                     'guard.close();print(sprintf("%J\\n",value));')
        else:
            code += 'let value=p[ARGV[1]](json(ARGV[2])); print(sprintf("%J\\n",value));'
        result = subprocess.run(['ucode', '-e', code, '--', str(self.root), operation,
                                 json.dumps(data)], capture_output=True, text=True, timeout=20,
                                env={**os.environ, **self.protocol_environment})
        self.assertEqual(self.snapshot(), before, 'read-only inspection changed filesystem')
        return result

    def assert_refused(self, operation, data=None, reason=None):
        result = self.run_protocol(operation, data)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('OWNER_SERIES_', result.stderr)
        if reason:
            self.assertIn(reason, result.stderr)

    def test_complete_baseline_is_accepted_without_writes(self):
        result = self.run_protocol('runtime', self.inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'files': 20, 'status': 'VERIFIED'})

    def test_runtime_drift_and_extra_library_file_refuse_without_repair(self):
        self.put(PATHS[-1], b'drift', 0o644)
        self.assert_refused('runtime', self.inventory, 'LIVE_DRIFT')
        self.put(PATHS[-1], ('fixture: ' + PATHS[-1] + '\n').encode(), 0o644)
        self.put('usr/lib/home-gateway/unknown.uc', b'x', 0o644)
        self.assert_refused('runtime', self.inventory, 'UNKNOWN_RUNTIME')

    def test_runtime_symlink_hardlink_and_wrong_mode_refuse(self):
        target = self.root / PATHS[-1]
        target.unlink()
        target.symlink_to(self.root / PATHS[-2])
        self.assert_refused('runtime', self.inventory, 'METADATA')
        target.unlink()
        os.link(self.root / PATHS[-2], target)
        self.assert_refused('runtime', self.inventory, 'LINK')
        target.unlink()
        self.put(PATHS[-1], ('fixture: ' + PATHS[-1] + '\n').encode(), 0o666)
        self.assert_refused('runtime', self.inventory, 'METADATA')

    def test_runtime_requires_complete_canonical_hash_inventory(self):
        for inventory in ({}, {**self.inventory, 'unexpected': '0' * 64},
                          {**self.inventory, PATHS[0]: '0' * 63}):
            self.assert_refused('runtime', inventory, 'INVENTORY')

    def test_disabled_actions_with_no_state_is_read_only(self):
        result = self.run_protocol('actions')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'records': 0, 'status': 'DISABLED'})

    def record(self, phase='DONE'):
        return dict(action='restart-tailscale', token='a' * 32, user='1', chat='2', message='3',
                    created=100, expires=220, boot='12345678-1234-1234-1234-123456789abc',
                    phase=phase, started=101, finished=102, maintenance_until=0)

    def state(self, records):
        return self.put('etc/home-gateway/state/actions.json', json.dumps(dict(schema_version=1, records=records)).encode())

    def test_executing_and_unknown_actions_refuse_without_recovery_write(self):
        for phase in ('EXECUTING', 'UNKNOWN'):
            self.state([self.record(phase)])
            self.assert_refused('actions', reason='ACTION_UNRESOLVED')

    def test_actions_schema_and_policy_are_strict(self):
        self.put('etc/home-gateway/actions.enabled', b'1\n')
        self.assert_refused('actions', reason='ACTIONS_ENABLED')
        self.put('etc/home-gateway/actions.enabled', b'garbage\n')
        self.assert_refused('actions', reason='ACTION_POLICY')
        self.put('etc/home-gateway/actions.enabled', b'0\n')
        for records in ([self.record(), self.record()], [dict(self.record(), expires=999)],
                        [dict(self.record(), action='arbitrary')], [dict(self.record(), started=True)]):
            self.state(records)
            self.assert_refused('actions', reason='ACTION_STATE')

    def test_finished_actions_are_not_expired_or_rewritten(self):
        self.state([self.record('PENDING')])
        result = self.run_protocol('actions')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'records': 1, 'status': 'DISABLED'})

    def test_partial_or_duplicate_json_state_refuses(self):
        for raw in (b'{', b'{"schema_version":1,"records":[],"records":[]}',
                    b'{"schema_version":true,"records":[]}'):
            self.put('etc/home-gateway/state/actions.json', raw)
            self.assert_refused('actions', reason='ACTION_STATE')

    def test_actions_respects_existing_kernel_lock_without_creating_one(self):
        import fcntl
        lock = self.put('tmp/home-gateway/actions.lock', b'')
        with lock.open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assert_refused('actions', reason='ACTIONS_BUSY')
        result = self.run_protocol('actions')
        self.assertEqual(result.returncode, 0, result.stderr)
        with lock.open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_actions_can_recheck_under_the_writers_existing_guard(self):
        self.put('tmp/home-gateway/actions.lock', b'')
        self.borrow_action_guard = True
        result = self.run_protocol('actions')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.borrow_action_guard = False
        self.assert_refused('actions', {'fileno': 'forged'}, 'ACTION_LOCK_RESOURCE')

    def test_unchanged_deployment_controls_are_authenticated(self):
        controls = {}
        for path, data in self.control_bytes.items():
            mode = 0o755 if path.startswith('etc/init.d/') else 0o600 if path.endswith('.uc') else 0o700
            self.put(path, data, mode)
            controls[path] = hashlib.sha256(data).hexdigest()
        result = self.run_protocol('controls', controls)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'files': 14, 'status': 'VERIFIED'})
        path = 'usr/libexec/home-gateway-deploy/migration-state.uc'
        self.put(path, b'forged', 0o600)
        controls[path] = hashlib.sha256(b'forged').hexdigest()
        self.assert_refused('controls', controls, 'CONTROL_INVENTORY')

    def test_pending_actions_writer_and_escaped_duplicate_keys_refuse(self):
        pending = self.put('etc/home-gateway/state/actions.json.new', b'')
        self.assert_refused('actions', reason='ACTION_PENDING')
        pending.unlink()
        self.put('etc/home-gateway/state/actions.json', b'{"schema_version":1,"records":[],"recor\\u0064s":[]}')
        self.assert_refused('actions', reason='ACTION_STATE')

    def test_historical_snapshot_detects_closed_set_and_metadata_drift(self):
        self.put('etc/home-gateway-owner-update/phase', b'COMMITTED\n')
        result = self.run_protocol('history', ['/etc/home-gateway-owner-update'])
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)
        self.assertEqual(evidence['files'], 1)
        checked = self.run_protocol('verify_history', evidence)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.put('etc/home-gateway-owner-update/unexpected', b'x')
        self.assert_refused('verify_history', evidence, 'HISTORY_DRIFT')

    def test_history_rejects_private_or_unsafe_roots(self):
        for paths in (['/etc/home-gateway/state'], ['/etc/home-gateway/secrets'],
                      ['/etc/../etc/home-gateway-owner-update'], ['/tmp']):
            self.assert_refused('history', paths, 'HISTORY_ROOT')

    def test_history_modes_and_hardlinks_cannot_be_laundered(self):
        path = self.put('etc/home-gateway-owner-update/phase', b'COMMITTED\n')
        result = self.run_protocol('history', ['/etc/home-gateway-owner-update'])
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)
        path.chmod(0o644)
        self.assert_refused('verify_history', evidence, 'HISTORY_DRIFT')
        path.chmod(0o600)
        os.link(path, self.root / 'outside-link')
        self.assert_refused('history', ['/etc/home-gateway-owner-update'], 'LINK')

    def test_real_migration_snapshot_retains_private_executable_controls(self):
        self.put('etc/home-gateway-migration/old/runtime/usr/libexec/home-gateway-deploy/engine.sh',
                 self.control_bytes['usr/libexec/home-gateway-deploy/engine.sh'], 0o700)
        self.put('etc/home-gateway-migration/old/runtime/usr/libexec/home-gateway-deploy/wrapper.sh',
                 self.control_bytes['usr/libexec/home-gateway-deploy/wrapper.sh'], 0o700)
        result = self.run_protocol('history', ['/etc/home-gateway-migration'])
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)
        self.assertEqual(evidence['files'], 2)
        self.assertEqual(self.run_protocol('verify_history', evidence).returncode, 0)

    def test_history_inventory_files_can_grow_to_the_documented_budget(self):
        path = 'etc/home-gateway-owner-series/generations/tx.' + 'a' * 32
        self.put(path + '/history.json', b'{}' + b' ' * 262143)
        result = self.run_protocol('history', ['/' + path])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['files'], 1)
        self.put(path + '/history.json', b'{}' + b' ' * 2097150)
        result = self.run_protocol('history', ['/' + path])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.put(path + '/history.json', b'{}' + b' ' * 2097151)
        self.assert_refused('history', ['/' + path], 'SIZE')

    def test_action_location_overrides_are_refused_explicitly(self):
        enabled = self.put('override-policy', b'1\n')
        for name in ('HG_ACTION_POLICY_FILE', 'HG_ACTION_STATE_DIR', 'HG_ACTION_RUNTIME_DIR'):
            self.protocol_environment = {name: str(enabled)}
            self.assert_refused('actions', reason='ACTION_ENVIRONMENT')

    def test_hash_commands_cannot_be_replaced_using_caller_path(self):
        trap = self.root / 'trap-bin'
        trap.mkdir(mode=0o700)
        for command in ('timeout', 'sha256sum'):
            self.put('trap-bin/' + command, ('#!/bin/sh\nprintf touched > ' + str(self.root / 'unwanted-write') +
                     '\nexec /bin/busybox ' + command + ' "$@"\n').encode(), 0o755)
        self.protocol_environment = {'PATH': str(trap) + ':' + os.environ['PATH']}
        result = self.run_protocol('runtime', self.inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'unwanted-write').exists())

    def platform_fixture(self, owner=False):
        self.put('proc/1/comm', b'procd\n', 0o644)
        self.put('proc/sys/kernel/random/boot_id', b'12345678-1234-1234-1234-123456789abc\n', 0o444)
        self.put('proc/meminfo', b'MemTotal: 500000 kB\nMemAvailable: 200000 kB\n', 0o444)
        self.put('etc/openwrt_release', b"DISTRIB_RELEASE='25.12.5'\n", 0o644)
        self.put('etc/hg-disposable-vm', b'HG_NETWORKLESS_OPENWRT_VM_V1\n')
        self.put('.hg-owner-series-test-platform.json', json.dumps(dict(
            architecture='aarch64' if owner else 'x86_64', busybox_version='BusyBox v1.37.0',
            board=dict(model='Cudy TR3000 v1', release=dict(target='mediatek/filogic')))).encode())

    def test_platform_proof_keeps_test_scope_explicit(self):
        self.platform_fixture()
        result = self.run_protocol('platform', 'VM_ONLY')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['scope'], 'TEST_FS_ONLY')
        self.assertEqual(value['available_kib'], 200000)
        self.put('proc/1/comm', b'python\n', 0o644)
        self.assert_refused('platform', 'VM_ONLY', 'PROCD')

    def test_vm_profile_cannot_accept_arm_or_missing_disposable_marker(self):
        self.platform_fixture(owner=True)
        self.assert_refused('platform', 'VM_ONLY', 'VM_ONLY')
        self.platform_fixture()
        (self.root / 'etc/hg-disposable-vm').unlink()
        self.assert_refused('platform', 'VM_ONLY')

    def test_owner_hardware_and_memory_refuse_incompatible_target(self):
        self.platform_fixture(owner=True)
        result = self.run_protocol('platform', 'OWNER_MANUAL')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.put('proc/meminfo', b'MemTotal: 250000 kB\nMemAvailable: 200000 kB\n', 0o444)
        self.assert_refused('platform', 'OWNER_MANUAL', 'OWNER_HARDWARE')
        self.put('proc/meminfo', b'MemTotal: 500000 kB\nMemAvailable: 1000 kB\n', 0o444)
        self.assert_refused('platform', 'OWNER_MANUAL', 'MEMORY')

    def test_wrong_release_and_busybox_are_refused(self):
        self.platform_fixture()
        self.put('etc/openwrt_release', b"DISTRIB_RELEASE='24.10'\n", 0o644)
        self.assert_refused('platform', 'VM_ONLY', 'OPENWRT')
        self.platform_fixture()
        path = self.root / '.hg-owner-series-test-platform.json'
        record = json.loads(path.read_bytes())
        record['busybox_version'] = 'BusyBox v1.36.0'
        self.put(path.name, json.dumps(record).encode())
        self.assert_refused('platform', 'VM_ONLY', 'BUSYBOX')

    def package_fixture(self):
        kit = '/tmp/hg-series-test-kit'
        files = {}
        baseline = dict(self.inventory)
        candidate = dict(baseline)
        for name in ('baseline', 'candidate'):
            for path in PATHS:
                data = (self.root / path).read_bytes()
                if name == 'candidate' and path.endswith('/telegram-poller.uc'):
                    data += b'// UI fixture\n'
                    candidate[path] = hashlib.sha256(data).hexdigest()
                files[name + '/' + path] = (0o755 if path in PATHS[:3] else 0o644, data)
        for name, hashes in (('baseline', baseline), ('candidate', candidate)):
            files[name + '.sha256'] = (0o600, ''.join(hashes[p] + '  ' + p + '\n' for p in PATHS).encode())
        for name in ('protocol.uc', 'state.uc', 'engine.uc', 'watch.uc', 'boot.init', 'owner.ps1'):
            files[name] = (0o755 if name == 'boot.init' else 0o600, b'HOST PACKAGING FIXTURE\n')
        controls = {p: hashlib.sha256(d).hexdigest() for p, d in self.control_bytes.items()}
        previous = dict(format='HG_OWNER_UPDATE_V1', source_commit='d2039b6c62da3aa458f720af1c46fb619aee48dd',
                        inventories={'candidate': baseline}, controls=controls)
        parent = json.dumps(previous).encode()
        files['parent.json'] = (0o600, parent)
        files['bootstrap.tar.gz'] = (0o600, b'opaque witness; validated by separate anchor inspector\n')
        manifest = dict(format='HG_OWNER_UPDATE_V2', profile='VM_ONLY', production_apply=False,
                        source_commit='1' * 40, baseline_commit=previous['source_commit'], source_fixture=True,
                        inventories=dict(baseline=baseline, candidate=candidate),
                        changed=['usr/lib/home-gateway/telegram-poller.uc'], controls=controls,
                        parent=dict(format=previous['format'], source_commit=previous['source_commit'],
                            manifest_sha256=hashlib.sha256(parent).hexdigest(), archive_sha256=hashlib.sha256(files['bootstrap.tar.gz'][1]).hexdigest()),
                        bootstrap=dict(archive_sha256=hashlib.sha256(files['bootstrap.tar.gz'][1]).hexdigest(),
                                       manifest_sha256=hashlib.sha256(parent).hexdigest()),
                        files=[dict(path=p, mode=m, size=len(d), sha256=hashlib.sha256(d).hexdigest())
                               for p, (m, d) in sorted(files.items())])
        for path, (mode, data) in files.items():
            self.put(kit.lstrip('/') + '/' + path, data, mode)
        return kit, manifest

    def inspect_package(self, kit, manifest):
        raw = json.dumps(manifest).encode()
        self.put(kit.lstrip('/') + '/manifest.json', raw)
        return self.run_protocol('package', dict(kit=kit, manifest_sha256=hashlib.sha256(raw).hexdigest()))

    def test_package_file_closure_and_parent_identity_are_read_only(self):
        kit, manifest = self.package_fixture()
        result = self.inspect_package(kit, manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['source_commit'], '1' * 40)
        self.put(kit.lstrip('/') + '/unexpected', b'x')
        result = self.inspect_package(kit, manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PACKAGE_UNKNOWN', result.stderr)

    def test_package_hash_drift_and_forged_parent_are_refused(self):
        kit, manifest = self.package_fixture()
        self.put(kit.lstrip('/') + '/watch.uc', b'corrupt')
        result = self.inspect_package(kit, manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PACKAGE_FILE_PIN', result.stderr)
        self.put(kit.lstrip('/') + '/watch.uc', b'HOST PACKAGING FIXTURE\n')
        manifest['parent']['source_commit'] = '0' * 40
        result = self.inspect_package(kit, manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PACKAGE_PARENT', result.stderr)


if __name__ == '__main__':
    unittest.main()
