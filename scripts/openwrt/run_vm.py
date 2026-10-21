"""Run public synthetic tests in a disposable, networkless OpenWrt x86 VM.

No SSH, production address, host port forwarding or shared host directories.
Official immutable inputs: downloads.openwrt.org/releases/25.12.5/targets/x86/64/.
This is not CUDY/PassWall/Xray/LIVE acceptance or a production migration tool.
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
KERNEL_SHA = 'e440f082d59550072b1421f10d1a83449c6a4cf356eea5bfa9ac1306978d649b'
PACKAGE_SHA = {
    'coreutils-base64-9.9-r2.apk': '5f8e6073e8074515830789aff5adb5601447468b62643016fd277ec3dd7e16f4',
    'packages.adb': 'd0fe864ac61705f34e401099719ea3cf37625912eb3d54260a7cbcdcc8ae9126',
    'coreutils-9.9-r2.apk': 'fe275266eb3d917162986bad82d2d74bc3763db9f497a584b77215e40e53f158',
    'coreutils-stat-9.9-r2.apk': '8efa0a3c4e54ef0b91dd6176f494567b0732b550672185aaff2f1e9cf3122ba2',
    'coreutils-timeout-9.9-r2.apk': '5a9d7cbff353150164ba6e61457b65c699c5f94a62c3eb48606a6b4c6abf7257',
}
ROOTFS_SHA = 'a1cb366a0af03d0f4afbce90aed9b4db35b07140629eabf7ae21c45dc08eeb23'
RESULT = re.compile(r'^HGVM_RESULT=(PASS|FAIL) TOTAL=([0-9]+) FAILED=([0-9]+) SCOPE=ISOLATED_X86_NOT_CUDY$', re.M)
CHECK = re.compile(r'^HGVM_CHECK=([a-z0-9_]+):(PASS|FAIL)$', re.M)


def require(ok, reason):
    if not ok: raise ValueError(reason)


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], stderr=subprocess.PIPE)


def validated_input(path, sha, reason='INPUT_SHA256'):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as file:
        metadata = os.fstat(file.fileno())
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_size <= 16 * 1024 * 1024, 'INPUT_TYPE_OR_SIZE')
        data = file.read(16 * 1024 * 1024 + 1)
    require(hashlib.sha256(data).hexdigest() == sha, reason)
    return data


def debug_quote(value):
    require(re.fullmatch(r'[A-Za-z0-9_./-]+', value), 'DEBUGFS_PATH')
    return value


def regression_admission(commit):
    # Exact published .2 bytes; do not depend on a squashed PR object.
    before = git('show', commit + ':scripts/deploy/fixtures/rc-b-20261019.2-admission.sh')
    require(hashlib.sha256(before).hexdigest() == 'fd67fe516a98da0fd9cef2a444af85c573c66ea096efcd90cc60bed6e3e4875a', 'ADMISSION_REGRESSION_FIXTURE_SHA256')
    return before


def inject(image, workspace, commit, packages, scenario):
    commands = []
    created = set()
    def put(target, data, mode):
        require(target.startswith('/') and all(p not in ('', '.', '..') for p in target[1:].split('/')), 'GUEST_PATH')
        for parent in reversed(Path(target).parents):
            if str(parent) != '/' and str(parent) not in created:
                commands.append('mkdir ' + debug_quote(str(parent))); created.add(str(parent))
        source = workspace / ('inject-' + hashlib.sha256(target.encode()).hexdigest())
        source.write_bytes(data)
        commands.extend(['rm ' + debug_quote(target),
                         'write ' + debug_quote(str(source)) + ' ' + debug_quote(target),
                         'set_inode_field ' + debug_quote(target) + ' mode ' + ('%07o' % (stat.S_IFREG | mode))])
    entries = git('ls-tree', '-rz', commit, '--', 'src/').split(b'\0')
    manifest = []
    for entry in entries:
        if not entry: continue
        header, raw = entry.split(b'\t', 1); mode, kind, oid = header.decode().split()
        path = raw.decode().removeprefix('src/')
        require(kind == 'blob' and mode in ('100644', '100755') and
                (path in ('usr/bin/gateway', 'usr/bin/home-gateway-ci-smoke', 'etc/init.d/home-gateway-telegram') or
                 re.fullmatch(r'usr/lib/home-gateway/[a-z][a-z0-9-]*\.(sh|uc)', path)), 'RUNTIME_INVENTORY')
        data = git('cat-file', 'blob', oid)
        put('/' + path, data, int(mode[-3:], 8))
        manifest.append(hashlib.sha256(data).hexdigest() + '  /' + path + '\n')
    require(len(manifest) == 20, 'RUNTIME_INVENTORY')
    for name, sha in PACKAGE_SHA.items():
        put('/opt/hg-vm-lab/packages/' + name, validated_input(packages / name, sha, 'PACKAGE_INDEX_SHA256' if name == 'packages.adb' else 'PACKAGE_SHA256'), 0o600)
    put('/opt/hg-vm-lab/packages/repositories', b'/opt/hg-vm-lab/packages/packages.adb\n', 0o600)
    for source in ('migration-admission.sh', 'engine.sh'):
        put('/usr/libexec/home-gateway-deploy/' + source, git('show', commit + ':scripts/deploy/' + source), 0o700)
    if scenario == 'overlay-identity':
        put('/opt/hg-vm-lab/admission-before-overlay-fix.sh', regression_admission(commit), 0o700)
    put('/opt/hg-vm-lab/legacy-engine.sh', git('show', commit + ':scripts/deploy/fixtures/legacy-engine-18.sh'), 0o700)
    put('/opt/hg-vm-lab/migration-state.uc', git('show', commit + ':scripts/deploy/migration-state.uc'), 0o600)
    put('/opt/hg-vm-lab/native-batch-inventory.uc', git('show', commit + ':scripts/deploy/native-batch-inventory.uc'), 0o600)
    lab='/etc/hg-native-snapshot'
    def service_init_namespace(raw):
        first,body=raw.decode().split('\n',1)
        body=re.sub(r'/(?:etc|usr|tmp)(?=/|[ \"\']|$)',lambda m:lab+m.group(),body)
        body=body.replace('/bin/sh "$admission"','/bin/sh "$admission" --test-root '+lab)
        env=('HG_LIBDIR='+lab+'/usr/lib/home-gateway HG_TELEGRAM_SECRETS_DIR='+lab+'/etc/home-gateway/secrets '
             'HG_TELEGRAM_RUNTIME_DIR='+lab+'/tmp/home-gateway HG_TELEGRAM_TOKEN_FILE='+lab+'/etc/home-gateway/secrets/telegram.token '
             'HG_NOTIFICATION_STATE_DIR='+lab+'/etc/home-gateway/state HG_NOTIFICATION_RUNTIME_DIR='+lab+'/tmp/home-gateway '
             'HG_NOTIFICATION_SECRETS_DIR='+lab+'/etc/home-gateway/secrets HG_INCIDENT_STATE_DIR='+lab+'/etc/home-gateway/state '
             'HG_INCIDENT_RUNTIME_DIR='+lab+'/tmp/home-gateway')
        body=body.replace('procd_set_param respawn','procd_set_param env '+env+'\n\tprocd_set_param respawn')
        return (first+'\n'+body).encode()
    if scenario in ('owner-update', 'rc-b-crash-apply', 'rc-b-crash-restore', 'retirement-reboot', 'rc-b-root-cycle', 'service-cycle', 'control-cycle', 'legacy-snapshot', 'candidate-snapshot', 'runtime-cycle', 'runtime-crash-apply', 'runtime-crash-restore', 'runtime-crash-phase'):
        put('/opt/hg-vm-lab/migration-snapshot.uc', git('show', commit + ':scripts/deploy/migration-snapshot.uc'), 0o600)
        # Public synthetic 18-file fixture on the guest's persistent filesystem.
        # Create its journal through the exact trusted shell receiver, not a mock.
        lab='/etc/hg-native-snapshot'
        put(lab + '/.hg-deploy-test-root', b'DISPOSABLE\n', 0o600)
        old_paths=[row.split('  /', 1)[1].strip() for row in manifest
                   if not row.endswith('/actions.uc\n') and not row.endswith('/notifications.uc\n')]
        wire=[b'HGDEPLOY1 ' + b'b'*40 + b'\n']
        for index, rel in enumerate(old_paths):
            perm=0o755 if index < 3 else 0o644
            raw=(b'#!/bin/sh\ncase "$1" in running) exit 1;; *) exit 0;; esac\n'
                 if rel.startswith('etc/init.d/') else b'// synthetic VM library\n' if rel.endswith('.uc')
                 else b'#!/bin/sh\nexit 0\n')
            if scenario in ('owner-update','rc-b-crash-apply','rc-b-crash-restore','rc-b-root-cycle','service-cycle') and rel in ('etc/init.d/home-gateway-telegram','usr/lib/home-gateway/telegram-poller.uc'):
                # Real legacy workers/init, explicitly synthetic old CLI: the
                # networkless VM cannot satisfy CUDY hardware doctor checks.
                raw=git('show','c921c2d:src/'+rel)
                if scenario=='service-cycle' and rel=='etc/init.d/home-gateway-telegram':raw=service_init_namespace(raw)
                elif scenario=='service-cycle':raw=raw.replace(b'/etc/home-gateway', (lab+'/etc/home-gateway').encode()).replace(b'/tmp/home-gateway',(lab+'/tmp/home-gateway').encode())
            put(lab + '/' + rel, raw, perm)
            if rel.endswith('/common.sh'): raw += b'# installed legacy revision\n'
            wire += [f'{perm:04o} {len(raw)} {hashlib.sha256(raw).hexdigest()}\n'.encode(),
                     base64.b64encode(raw) + b'\n']
        for source, dest, perm in (
            ('legacy-engine-18.sh', 'usr/libexec/home-gateway-deploy/engine.sh', 0o700),
            ('legacy-wrapper.sh', 'usr/libexec/home-gateway-deploy/wrapper.sh', 0o700),
            ('legacy-recovery.init', 'etc/init.d/home-gateway-deploy-recover', 0o755)):
            put(lab + '/' + dest, git('show', commit + ':scripts/deploy/fixtures/' + source), perm)
        payload=b''.join(wire) + b'END\n'
        put('/opt/hg-vm-lab/legacy-fixture.wire', payload, 0o600)
        put('/opt/hg-vm-lab/legacy-fixture.sha256', hashlib.sha256(payload).hexdigest().encode() + b'\n', 0o600)
    if scenario in ('service-cycle', 'control-cycle', 'candidate-snapshot', 'runtime-cycle', 'runtime-crash-apply', 'runtime-crash-restore', 'runtime-crash-phase'):
        put('/opt/hg-vm-lab/migration-candidate.uc', git('show', commit + ':scripts/deploy/migration-candidate.uc'), 0o600)
        candidate='/opt/hg-vm-lab/native-candidate'
        records=[]
        for entry in entries:
            if not entry: continue
            header, raw=entry.split(b'\t', 1)
            perm, kind, oid=header.decode().split()
            rel=raw.decode().removeprefix('src/')
            data=git('cat-file', 'blob', oid)
            if scenario=='service-cycle' and rel=='etc/init.d/home-gateway-telegram':data=service_init_namespace(data)
            put(candidate + '/' + rel, data, int(perm[-3:], 8))
            records.append(hashlib.sha256(data).hexdigest() + '  ' + rel + '\n')
        for source, rel, perm in (('engine.sh', 'usr/libexec/home-gateway-deploy/engine.sh', 0o700),
                                  ('wrapper.sh', 'usr/libexec/home-gateway-deploy/wrapper.sh', 0o700),
                                  ('recovery.init', 'etc/init.d/home-gateway-deploy-recover', 0o755)):
            data=git('show', commit + ':scripts/deploy/' + source)
            put(candidate + '/' + rel, data, perm)
            records.append(hashlib.sha256(data).hexdigest() + '  ' + rel + '\n')
        raw=''.join(records).encode()
        put(candidate + '/migration.sha256', raw, 0o600)
        put('/opt/hg-vm-lab/candidate.pin', hashlib.sha256(raw).hexdigest().encode() + b'\n', 0o600)
    if scenario in ('service-cycle', 'control-cycle', 'runtime-cycle', 'runtime-crash-apply', 'runtime-crash-restore', 'runtime-crash-phase'):
        for module in ('migration-runtime.uc','migration-handoff.uc','migration-coordinator.uc'):
            put('/opt/hg-vm-lab/'+module, git('show', commit+':scripts/deploy/'+module), 0o600)
    if scenario in ('control-cycle','service-cycle'):
        put('/opt/hg-vm-lab/migration-controls.uc', git('show', commit+':scripts/deploy/migration-controls.uc'), 0o600)
        put('/opt/hg-vm-lab/migration-service.uc', git('show', commit+':scripts/deploy/migration-service.uc'), 0o600)
        put('/opt/hg-vm-lab/migration-terminal.uc', git('show', commit+':scripts/deploy/migration-terminal.uc'), 0o600)
        put('/opt/hg-vm-lab/migration-retirement.uc', git('show', commit+':scripts/deploy/migration-retirement.uc'), 0o600)
        put('/opt/hg-vm-lab/legacy-telegram.init',git('show','c921c2d:src/etc/init.d/home-gateway-telegram'),0o755)
        rows=[]
        controls=[('migration-'+n+'.uc','usr/libexec/home-gateway-deploy/migration-'+n+'.uc',0o600)
                  for n in ('state','snapshot','candidate','runtime','handoff','coordinator','controls','service','terminal')]
        controls += [('migration-admission.sh','usr/libexec/home-gateway-deploy/migration-admission.sh',0o700),
                     ('migration-boot.init','etc/init.d/home-gateway-migration',0o755)]
        for source, rel, perm in controls:
            raw=git('show',commit+':scripts/deploy/'+source)
            put('/opt/hg-vm-lab/control-input/'+rel,raw,perm)
            rows.append(hashlib.sha256(raw).hexdigest()+'  '+rel+'\n')
        raw=''.join(rows).encode()
        put('/opt/hg-vm-lab/control-input/controls.sha256',raw,0o600)
        put('/opt/hg-vm-lab/control.pin',hashlib.sha256(raw).hexdigest().encode()+b'\n',0o600)
    if scenario == 'runtime-crash-phase':
        # Real rc.common S08 hook, before rc.local. Only this disposable lab
        # adapts the production hook's namespace and binds its volatile /tmp.
        boot=git('show', commit+':scripts/deploy/migration-boot.init').decode()
        boot=boot.replace('/etc/home-gateway-migration','/etc/hg-native-snapshot/etc/home-gateway-migration')
        boot=boot.replace('/tmp/home-gateway-deploy.lock','/etc/hg-native-snapshot/tmp/home-gateway-deploy.lock')
        boot=boot.replace('/usr/libexec/home-gateway-deploy/migration-state.uc','/opt/hg-vm-lab/migration-state.uc')
        boot=boot.replace('restore_boot_fence("",null)','restore_boot_fence("/etc/hg-native-snapshot","/bin/busybox")')
        setup="    if [ -d /etc/hg-native-snapshot/etc/home-gateway-migration ]; then\n        umask 077\n        mkdir -p /tmp/hg-crash-ram\n        mount --bind /tmp/hg-crash-ram /etc/hg-native-snapshot/tmp || return 1\n        if [ ! -e /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ] && [ ! -L /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ]; then\n            printf 'ABSENT\\n' > /etc/hg-vm-lab/boot-fence-before\n        else printf 'PRESENT\\n' > /etc/hg-vm-lab/boot-fence-before; fi\n        cat /proc/sys/kernel/random/boot_id > /etc/hg-vm-lab/boot-guard.boot\n    fi\n"
        boot=boot.replace('start() {\n','start() {\n'+setup)
        put('/etc/rc.d/S08hg-migration-lab-guard',boot.encode(),0o755)
    if scenario in ('rc-b-crash-apply','rc-b-crash-restore','retirement-reboot'):
        fault=workspace/'fault-runtime.c';fault.write_bytes(git('show',commit+':scripts/openwrt/fault-runtime.c'))
        binary=workspace/'fault-runtime'
        subprocess.run(['cc','-static','-O2','-Wall','-Wextra','-Werror','-o',str(binary),str(fault)],check=True,timeout=30)
        put('/opt/hg-vm-lab/fault-runtime',binary.read_bytes(),0o700)
    if scenario in ('owner-update','rc-b-root-cycle','rc-b-crash-apply','rc-b-crash-restore','retirement-reboot'):
        subprocess.run(['python3', str(ROOT / 'scripts/migration_rc/build_b.py'), '--ref', '62592457237e7f026786c086d1ca6fdd4b6c095d' if scenario=='owner-update' else commit,
                        '--output', str(workspace / 'rc-b-package')], check=True, stdout=subprocess.DEVNULL)
        archive=next((workspace / 'rc-b-package').glob('*.tar.gz'))
        put('/opt/hg-vm-lab/rc-b.tar.gz', archive.read_bytes(), 0o600)
    if scenario == 'rc-a-package':
        subprocess.run(['python3', str(ROOT / 'scripts/migration_rc/build.py'), '--ref', commit,
                        '--output', str(workspace / 'rc-package')], check=True, stdout=subprocess.DEVNULL)
        archive = next((workspace / 'rc-package').glob('*.tar.gz'))
        put('/opt/hg-vm-lab/rc-a.tar.gz', archive.read_bytes(), 0o600)
    if scenario=='owner-update':
        subprocess.run(['python3',str(ROOT/'scripts/owner_update/build.py'),'--ref',commit,'--output',str(workspace/'owner-update')],check=True,stdout=subprocess.DEVNULL)
        put('/opt/hg-vm-lab/owner-update.tar.gz',next((workspace/'owner-update').glob('*.tar.gz')).read_bytes(),0o600)
    guest={'owner-update':'guest-owner-update.sh','retirement-reboot':'guest-retirement.sh','rc-b-crash-apply':'guest-rc-b-crash-apply.sh','rc-b-crash-restore':'guest-rc-b-crash-restore.sh','rc-b-root-cycle':'guest-rc-b.sh', 'baseline':'guest-smoke.sh', 'legacy-snapshot':'guest-snapshot.sh', 'candidate-snapshot':'guest-candidate.sh', 'overlay-identity':'guest-overlay.sh', 'runtime-cycle':'guest-runtime.sh', 'runtime-crash-apply':'guest-crash-apply.sh', 'runtime-crash-restore':'guest-crash-restore.sh', 'runtime-crash-phase':'guest-crash-phase.sh', 'rc-a-package':'guest-rc-a.sh', 'control-cycle':'guest-controls.sh', 'service-cycle':'guest-service-cycle.sh'}[scenario]
    smoke = git('show', commit + ':scripts/openwrt/' + guest)
    subprocess.run(['sh', '-n'], input=smoke, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    service = git('show', commit + ':scripts/openwrt/fixture-service.sh')
    put('/opt/hg-vm-lab/guest-smoke.sh', smoke, 0o700)
    put('/opt/hg-vm-lab/init/tailscale', service, 0o755)
    put('/opt/hg-vm-lab/runtime.sha256', ''.join(manifest).encode(), 0o600)
    put('/etc/hg-disposable-vm', b'HG_NETWORKLESS_OPENWRT_VM_V1\n', 0o600)
    put('/etc/rc.local', b'#!/bin/sh\n/bin/sh /opt/hg-vm-lab/guest-smoke.sh >/dev/ttyS0 2>&1 &\nexit 0\n', 0o755)
    batch = workspace / 'debugfs-commands'; batch.write_text('\n'.join(commands) + '\n')
    subprocess.run(['debugfs', '-w', '-f', str(batch), str(image)], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=True, timeout=30)
    return {name.decode() for name in re.findall(rb'^\s*check ([a-z0-9_]+) ', smoke, re.M)}


def parse_result(console, expected):
    rows = CHECK.findall(console.replace('\r', ''))
    results = RESULT.findall(console.replace('\r', ''))
    require(len(results) == 1, 'NO_SINGLE_COMPLETION')
    require(len(rows) == len(expected) and {name for name, _ in rows} == expected, 'INCOMPLETE_CHECKS')
    status, total, failed = results[0]
    require(int(total) == len(rows) and int(failed) == sum(s != 'PASS' for _, s in rows), 'COUNT_MISMATCH')
    require((status == 'PASS') == (int(failed) == 0), 'STATUS_MISMATCH')
    return dict(schema_version=1, status=status, scope='ISOLATED_X86_NOT_CUDY',
                checks=dict(rows), total=int(total), failed=int(failed), production_supported=False)


def run(args):
    commit = git('rev-parse', '--verify', '--end-of-options', args.ref + '^{commit}').decode().strip()
    kernel_data = validated_input(args.kernel, KERNEL_SHA)
    root_data = validated_input(args.rootfs, ROOTFS_SHA)
    with tempfile.TemporaryDirectory(prefix='hg-openwrt-vm-') as temporary:
        workspace = Path(temporary)
        kernel = workspace / 'kernel.bin'; kernel.write_bytes(kernel_data)
        compressed = workspace / 'root.img.gz'; compressed.write_bytes(root_data)
        image = workspace / 'root.img'
        with gzip.open(compressed, 'rb') as source, image.open('wb') as destination:
            total = 0
            while block := source.read(1024 * 1024):
                total += len(block); require(total <= 256 * 1024 * 1024, 'EXPANDED_IMAGE_LIMIT')
                destination.write(block)
        expected = inject(image, workspace, commit, args.packages_directory, args.scenario)
        command = [args.qemu, '-accel', 'tcg', '-m', '256', '-smp', '1',
                   '-kernel', str(kernel), '-append', 'root=/dev/vda rootwait console=ttyS0,115200n8',
                   '-drive', 'file=' + str(image) + ',format=raw,if=virtio', '-snapshot',
                   '-display', 'none', '-vga', 'none', '-monitor', 'none', '-serial', 'stdio',
                   '-nic', 'none', '-no-user-config']
        if args.scenario in ('owner-update', 'rc-b-crash-apply', 'rc-b-crash-restore', 'retirement-reboot', 'overlay-identity', 'runtime-crash-apply', 'runtime-crash-restore', 'runtime-crash-phase'):
            # A real guest reboot exits QEMU; supervise a cold boot of the same
            # private writable disk. The immutable input is never mounted.
            command.remove('-snapshot'); command += ['-no-reboot']
        if args.qemu_data: command += ['-L', str(args.qemu_data)]
        if args.bios: command += ['-bios', str(args.bios)]
        # The control scenario snapshots runtime plus its dependency closure.
        # TCG-only hosts need a separate bounded budget; assertions are unchanged.
        console = bytearray(); deadline = time.monotonic() + (900 if args.scenario=='retirement-reboot' else 600 if args.scenario in ('owner-update','rc-b-crash-apply','rc-b-crash-restore') else 300 if args.scenario in ('rc-b-root-cycle','control-cycle','service-cycle') else 180)
        try:
            for boot in range(2 if args.scenario in ('owner-update', 'rc-b-crash-apply', 'rc-b-crash-restore', 'retirement-reboot', 'overlay-identity','runtime-crash-apply','runtime-crash-restore', 'runtime-crash-phase') else 1):
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    with selectors.DefaultSelector() as selector:
                        selector.register(child.stdout, selectors.EVENT_READ)
                        while time.monotonic() < deadline:
                            events = selector.select(1)
                            for key, _ in events:
                                chunk = os.read(key.fileobj.fileno(), 65536)
                                if not chunk: selector.unregister(key.fileobj); break
                                console.extend(chunk); require(len(console) <= 4 * 1024 * 1024, 'CONSOLE_LIMIT')
                            if not selector.get_map(): break
                        try:
                            status=child.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            raise ValueError('VM_TIME_LIMIT') from None
                        require(status == 0, 'VM_EXIT_FAILED')
                finally:
                    if child.poll() is None:
                        child.terminate()
                        try: child.wait(timeout=2)
                        except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=2)
                    child.stdout.close()
                if args.scenario in ('owner-update', 'rc-b-crash-apply', 'rc-b-crash-restore', 'retirement-reboot', 'overlay-identity','runtime-crash-apply','runtime-crash-restore', 'runtime-crash-phase') and boot == 0:
                    raw=console.decode('utf-8',errors='replace')
                    require(raw.count('HGVM_REBOOT=REQUESTED') == boot+1 and 'reboot: Restarting system' in raw and not RESULT.search(raw), 'GUEST_REBOOT_NOT_OBSERVED')
        finally:
            if args.diagnostic_log:
                fd = os.open(args.diagnostic_log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'wb') as log: log.write(console)
        report = parse_result(console.decode('utf-8', errors='replace'), expected)
        if report['failed']:
            # Fixed public native refusal codes only; never raw guest output,
            # secrets, stderr, command lines or diagnostic log publication.
            report['native_refusals']=sorted(set(re.findall(r'\bMIGRATION_[A-Z0-9_]{1,80}\b', console.decode('utf-8',errors='replace'))))[:32]
        report.update(commit=commit, scenario=args.scenario, kernel_sha256=KERNEL_SHA, rootfs_sha256=ROOTFS_SHA,
                      network_devices=0, host_shared_directories=0, package_sha256=PACKAGE_SHA)
        if args.scenario in ('owner-update', 'rc-b-crash-apply', 'rc-b-crash-restore', 'retirement-reboot', 'overlay-identity', 'runtime-crash-apply', 'runtime-crash-restore', 'runtime-crash-phase'): report['reboot_mechanism']='GUEST_REBOOT_SUPERVISED_COLD_BOOT'
        return report


def failure_report(error):
    # Expose only fixed public codes, never subprocess output or local paths.
    reason = str(error) if isinstance(error, ValueError) else ''
    allowed = {'GUEST_REBOOT_NOT_OBSERVED', 'VM_TIME_LIMIT', 'INPUT_SHA256', 'PACKAGE_INDEX_SHA256', 'PACKAGE_SHA256',
               'INPUT_TYPE_OR_SIZE', 'DEBUGFS_PATH', 'GUEST_PATH', 'RUNTIME_INVENTORY',
               'NO_SINGLE_COMPLETION', 'INCOMPLETE_CHECKS', 'COUNT_MISMATCH',
               'STATUS_MISMATCH', 'EXPANDED_IMAGE_LIMIT', 'CONSOLE_LIMIT', 'VM_EXIT_FAILED'}
    if reason not in allowed:
        reason = ('IO_ERROR' if isinstance(error, OSError) else
                  'VALIDATION_ERROR' if isinstance(error, ValueError) else 'SUBPROCESS_ERROR')
    return dict(schema_version=1, status='VM_FAILED', scope='ISOLATED_X86_NOT_CUDY',
                production_supported=False, reason=reason)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', type=Path, required=True)
    parser.add_argument('--rootfs', type=Path, required=True)
    parser.add_argument('--qemu', default='qemu-system-x86_64')
    parser.add_argument('--qemu-data', type=Path)
    parser.add_argument('--bios', type=Path)
    parser.add_argument('--packages-directory', type=Path, required=True, help='Pinned official stat/timeout APKs, installed offline only in guest')
    parser.add_argument('--ref', default='HEAD')
    parser.add_argument('--scenario', choices=('owner-update', 'rc-b-crash-apply', 'rc-b-crash-restore', 'retirement-reboot', 'rc-b-root-cycle', 'baseline', 'legacy-snapshot', 'candidate-snapshot', 'overlay-identity', 'runtime-cycle', 'runtime-crash-apply', 'runtime-crash-restore', 'runtime-crash-phase', 'rc-a-package', 'control-cycle', 'service-cycle'), default='baseline')
    parser.add_argument('--diagnostic-log', type=Path, help='Private local diagnostic only; never CI artifact')
    args = parser.parse_args()
    try: report = run(args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps(failure_report(error)))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__': raise SystemExit(main())
