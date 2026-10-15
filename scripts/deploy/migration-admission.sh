#!/bin/sh
# Read-only ucode boundary; no Python, cleanup, services, UCI or nft changes.
set -eu
UCODE=/usr/bin/ucode
# Explicit disposable fixtures only; production has no executable override.
if [ "${1:-}" = --test-root ]; then
    UCODE=${HG_TEST_UCODE_BIN:-$(command -v ucode)}
    HG_TEST_BUSYBOX=$(command -v "${HG_TEST_BUSYBOX:-busybox}")
    export HG_TEST_BUSYBOX
fi
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec "$UCODE" -e "$(cat <<'UCODE'
import * as fs from 'fs';
function require(ok) { if (!ok) { warn('MIGRATION_ADMISSION=BLOCKED\n'); exit(73); } }
function quote(s) { return "'" + replace(s, "'", "'\\''") + "'"; }
function command(args) {
    let p=fs.popen(join(' ', map(args, quote)) + ' >/dev/null 2>&1', 'r');
    require(p != null); return p.close();
}
let args=[ ...ARGV ], root='', owner=0, group=0;
if (args[0] == '--test-root') {
    shift(args); root=shift(args);
    require(type(root) == 'string' && root != '/' && match(root, /^\/[A-Za-z0-9_.\/-]+$/) && !match(root, /(^|\/)\.\.?($|\/)/));
    let marker=fs.lstat(root + '/.hg-deploy-test-root'), top=fs.lstat(root);
    require(top?.type == 'directory' && marker?.type == 'file' && marker.nlink == 1 && marker.size <= 128 && marker.uid == top.uid && marker.gid == top.gid);
    owner=top.uid; group=top.gid;
}
let scope='default';
if (args[0] == '--receiver-recover') { scope='recover'; shift(args); }
else if (args[0] == '--telegram-start') { scope='telegram'; shift(args); }
let provisional=scope=='telegram' && args[0]=='--migration-start';
if(provisional)shift(args);
let borrowed=scope == 'telegram' && args[0] == '--held-telegram-guard';
if (borrowed) shift(args);
require(length(args) == 0 && (!provisional || borrowed));
const BASE=root + '/etc/home-gateway-migration', FENCE=root + '/tmp/home-gateway-deploy.lock';
function checked(path, kind, mode, limit) {
    let parts=split(path, '/'), prefix='';
    for (let i=1; i<length(parts)-1; i++) {
        prefix += '/' + parts[i]; let s=fs.lstat(prefix);
        require(s?.type == 'directory' && (s.uid == 0 || s.uid == owner) && (!(s.mode & 022) || s.perm.sticky));
    }
    let s=fs.lstat(path);
    require(s?.type == kind && s.uid == owner && s.gid == group && s.mode == mode);
    if (kind == 'file') require(s.nlink == 1 && s.size <= limit);
    return s;
}
function read(path, limit) {
    let s=checked(path, 'file', 0600, limit), f=fs.open(path, 're'); require(f != null);
    let held=fs.stat('/proc/self/fd/' + f.fileno());
    require(held?.inode == s.inode && held.dev.major == s.dev.major && held.dev.minor == s.dev.minor);
    let raw=f.read(limit+1), closed=f.close(), after=fs.lstat(path);
    require(closed != null && type(raw) == 'string' && length(raw) == s.size && after?.inode == s.inode && after.size == s.size && after.mtime == s.mtime && after.type == s.type && after.dev.major == s.dev.major && after.dev.minor == s.dev.minor && after.uid == s.uid && after.gid == s.gid && after.mode == s.mode && after.nlink == s.nlink);
    return raw;
}
const LOCK=root + '/etc/home-gateway-migration.lock';
let guard=null, identity=null;
if (fs.lstat(BASE) != null || fs.lstat(LOCK) != null || borrowed) {
    let st=checked(LOCK, 'file', 0600, 0), held;
    if (borrowed) {
        held=fs.stat('/proc/self/fd/8');
        require(held?.inode == st.inode && held.dev.major == st.dev.major && held.dev.minor == st.dev.minor &&
            held.uid == owner && held.gid == group && held.mode == 0600 && held.nlink == 1 && held.size == 0);
        // FD8 belongs to rc.common's parent startup handshake. This child shares
        // its open file description; it must not unlock or close the parent FD.
        let bb=root == '' ? '/bin/busybox' : getenv('HG_TEST_BUSYBOX');
        require(type(bb) == 'string' && length(bb) > 0 && command([ bb, 'flock', '-n', '8' ]) == 0);
    } else {
        guard=fs.open(LOCK, 're'); require(guard != null);
        held=fs.stat('/proc/self/fd/' + guard.fileno());
        require(held?.inode == st.inode && held.dev.major == st.dev.major && held.dev.minor == st.dev.minor && guard.lock('xn') != null);
    }
    require(fs.lstat(LOCK)?.inode == held.inode);
    identity=st;
}
if (fs.lstat(BASE) == null) { require(!provisional && fs.lstat(FENCE) == null); exit(0); }
let base_stat=checked(BASE, 'directory', 0700, 0);
require(identity.dev.major == base_stat.dev.major && identity.dev.minor == base_stat.dev.minor);
let marker=read(BASE + '/marker', 128);
require(match(marker, /^HG_MIGRATION_STATE_V1 [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\n$/) != null);
require(fs.lstat(BASE + '/phase.new') == null && fs.lstat(BASE + '/admission.new') == null);
let raw=read(BASE + '/phase', 32), phase=trim(raw);
require(raw==phase+'\n' && (provisional ? phase=='APPLYING' : (phase=='COMMITTED' || phase=='ROLLED_BACK')));
if(!provisional)require(read(BASE + '/admission', 128) == 'HG_MIGRATION_ADMITTED_V2 ' + phase + ' ' + trim(substr(marker, length('HG_MIGRATION_STATE_V1 '))) + ' ' + identity.inode + '\n');
let pid=null;
if (provisional) {
    let st=checked(FENCE,'link',0777,0);
    require(st.nlink==1 && fs.readlink(FENCE)==BASE+'/fence');
    checked(BASE+'/fence','directory',0700,0);
    require(read(BASE+'/fence/marker',128)==marker && join(',',fs.lsdir(BASE+'/fence'))=='marker');
} else if (fs.lstat(FENCE) != null) {
    require(scope != 'default'); checked(FENCE, 'directory', 0700, 0);
    raw=read(FENCE + '/pid', 16); pid=trim(raw);
    require(match(pid, /^[1-9][0-9]{0,9}$/) && raw == pid + '\n');
    // The receiver owns liveness checking and stale lease cleanup. A symlink
    // migration fence cannot pass this regular directory/regular file check.
}
const PATHS=["etc/init.d/home-gateway-telegram", "usr/bin/gateway", "usr/bin/home-gateway-ci-smoke", "usr/lib/home-gateway/actions.uc", "usr/lib/home-gateway/asata.sh", "usr/lib/home-gateway/common.sh", "usr/lib/home-gateway/dns.sh", "usr/lib/home-gateway/doctor.sh", "usr/lib/home-gateway/health.sh", "usr/lib/home-gateway/incidents.uc", "usr/lib/home-gateway/network.sh", "usr/lib/home-gateway/notifications.uc", "usr/lib/home-gateway/redmi.sh", "usr/lib/home-gateway/selftest.sh", "usr/lib/home-gateway/status.sh", "usr/lib/home-gateway/tailscale.sh", "usr/lib/home-gateway/telegram-poller.uc", "usr/lib/home-gateway/telegram.sh", "usr/lib/home-gateway/torrent.sh", "usr/lib/home-gateway/vpn.sh"];
if(provisional) {
    require(read(BASE+'/service-check',128)=='HG_MIGRATION_SERVICE_CHECK_V1 '+trim(substr(marker,length('HG_MIGRATION_STATE_V1 ')))+' '+identity.inode+'\n');
    require(fs.lstat(BASE+'/service-check.new')==null && fs.lstat(BASE+'/latest.pending')==null);
    let records=split(read(BASE+'/candidate/migration.sha256',8192),'\n');require(pop(records)=='' && length(records)==23);
    let receivers=['usr/libexec/home-gateway-deploy/engine.sh','usr/libexec/home-gateway-deploy/wrapper.sh','etc/init.d/home-gateway-deploy-recover'],seen={};
    for(let row in records) {
        let rel=substr(row,66),digest=substr(row,0,64);
        require(substr(row,64,2)=='  ' && match(digest,/^[0-9a-f]{64}$/) && !seen[rel] && (index(PATHS,rel)>=0 || index(receivers,rel)>=0));seen[rel]=true;
        let mode=index(PATHS,rel)>=0 ? (index(PATHS,rel)<3?0755:0644) : (index(receivers,rel)<2?0700:0755);
        checked(root+'/'+rel,'file',mode,262144);
    }
    let library=fs.lsdir(root+'/usr/lib/home-gateway');
    require(library!=null && length(library)==17 && length(filter(library,n=>index(PATHS,'usr/lib/home-gateway/'+n)>=0))==17);
    let plan=json(read(BASE+'/coordinator.json',1024));
    require(type(plan)=='object' && join(',',sort(keys(plan)))=='commit,format,manifest_sha256,marker,was_running' &&
        plan.format=='HG_NATIVE_COORDINATOR_V1' && plan.marker==marker &&
        match(plan.commit,/^[0-9a-f]{40}$/) && match(plan.manifest_sha256,/^[0-9a-f]{64}$/) &&
        type(plan.was_running)=='int' && plan.was_running==1);
    require(fs.lstat(BASE+'/coordinator.json.new')==null && fs.lstat(BASE+'/coordinator.publish-pending')==null);
    let hash=fs.popen('timeout -k 2 10 sha256sum '+quote(BASE+'/candidate/migration.sha256')+' 2>/dev/null','r');require(hash!=null);
    let pin=hash.read(1025);require(hash.close()==0 && pin==plan.manifest_sha256+'  '+BASE+'/candidate/migration.sha256\n');
    hash=fs.popen('cd '+quote(root||'/')+' && timeout -k 2 10 sha256sum -c '+quote(BASE+'/candidate/migration.sha256')+' >/dev/null 2>&1','r');require(hash!=null && hash.close()==0);
    // Certify the complete published rollback anchor before any worker starts.
    // This gate is read-only: no snapshot_io/fence creation or recovery replay.
    require(fs.lstat(BASE+'/handoff.json.new')==null && fs.lstat(BASE+'/handoff.publish-pending')==null && fs.lstat(BASE+'/handoff')==null);
    let handoff=json(read(BASE+'/handoff.json',16384)),deploy=root+'/etc/home-gateway-deploy',
        id='tx.m'+substr(replace(trim(substr(marker,22)),'-',''),0,24);
    require(type(handoff)=='object' && join(',',sort(keys(handoff)))=='commit,files,format,id,marker,was_running' &&
        handoff.format=='HG_NATIVE_HANDOFF_V1' && handoff.id==id && handoff.marker==marker &&
        handoff.commit==plan.commit && type(handoff.was_running)=='int' && handoff.was_running==plan.was_running && type(handoff.files)=='object');
    checked(deploy,'directory',0700,0);
    require(read(deploy+'/latest',40)==id+'\n' && fs.lstat(deploy+'/active')==null &&
        fs.lstat(deploy+'/active.new')==null && fs.lstat(deploy+'/latest.new')==null);
    let anchor=deploy+'/'+id,required=[...map(PATHS,p=>'backup/'+p),'phase','commit','was-running','inventory-version',
        'new.sha256','backup.sha256','preflight.log','postflight.log','service.log'];
    require(length(keys(handoff.files))==length(required));
    let actual=[];
    function walk(path,prefix) {
        checked(path,'directory',0700,0);let entries=fs.lsdir(path);require(entries!=null && length(entries)<=32);
        for(let name in entries) {
            let rel=prefix?prefix+'/'+name:name;
            require(length(filter(required,p=>p==rel || index(p,rel+'/')==0))>0);
            if(fs.lstat(path+'/'+name)?.type=='directory')walk(path+'/'+name,rel);else push(actual,rel);
        }
    }
    walk(anchor,'');require(length(actual)==length(required));
    let files=map(required,p=>anchor+'/'+p);
    hash=fs.popen('timeout -k 2 10 sha256sum '+join(' ',map(files,quote))+' 2>/dev/null','r');require(hash!=null);
    let hashes=hash.read(16385);require(hash.close()==0 && type(hashes)=='string' && length(hashes)<=16384);
    hashes=split(hashes,'\n');require(pop(hashes)=='' && length(hashes)==length(required));
    let candidate={};for(let row in records)candidate[substr(row,66)]=substr(row,0,64);
    for(let i=0;i<length(required);i++) {
        let rel=required[i],record=handoff.files[rel],backup=index(rel,'backup/')==0,
            perm=backup?(index(PATHS,substr(rel,7))<3?0755:0644):0600;
        require(type(record)=='object' && join(',',sort(keys(record)))=='mode,sha256' && record.mode==perm && match(record.sha256,/^[0-9a-f]{64}$/) &&
            hashes[i]==record.sha256+'  '+files[i] && (!backup || record.sha256==candidate[substr(rel,7)]));
        checked(files[i],'file',perm,262144);
    }
    let manifest=join('',map(sort([...PATHS]),p=>candidate[p]+'  '+p+'\n'));
    require(read(anchor+'/new.sha256',8192)==manifest && read(anchor+'/backup.sha256',8192)==manifest &&
        read(anchor+'/phase',16)=='COMMITTED\n' && read(anchor+'/inventory-version',16)=='HGDEPLOY2\n' &&
        read(anchor+'/commit',41)==plan.commit+'\n' && read(anchor+'/was-running',2)=='1\n');
    print('MIGRATION_ADMISSION=SERVICE_CHECK_ONLY\n');exit(0);
}
if (scope == 'telegram') {
    const DEPLOY=root + '/etc/home-gateway-deploy';
    if (fs.lstat(DEPLOY + '/active') != null) {
        checked(DEPLOY, 'directory', 0700, 0);
        raw=read(DEPLOY + '/active', 40); let id=trim(raw);
        require(match(id, /^tx\.[a-zA-Z0-9]{1,32}$/) && raw == id + '\n');
        let tx=DEPLOY + '/' + id; checked(tx, 'directory', 0700, 0);
        raw=read(tx + '/phase', 16); let stage=trim(raw);
        require(raw == stage + '\n' && index([ 'CHECKING', 'COMMITTED', 'RESTORED' ], stage) >= 0);
        require(read(tx + '/inventory-version', 10) == 'HGDEPLOY2\n');
        let manifest=tx + (stage == 'RESTORED' ? '/backup.sha256' : '/new.sha256');
        let bytes=read(manifest, 8192), rows=split(bytes, '\n');
        require(pop(rows) == '' && length(rows) == 20);
        let seen={};
        for (let row in rows) {
            let digest=substr(row, 0, 64), rel=substr(row, 66);
            require(match(digest, /^[0-9a-f]{64}$/) && substr(row, 64, 2) == '  ' && index(PATHS, rel) >= 0 && !seen[rel]); seen[rel]=true;
        }
        for (let path in PATHS) checked(root + '/' + path, 'file', index(PATHS, path) < 3 ? 0755 : 0644, 262144);
        // One bounded checksum process; avoid hundreds of stat subprocesses
        // within rc.common's startup budget on the actual target.
        let hash=fs.popen('cd ' + quote(root || '/') + ' && timeout -k 2 10 sha256sum -c ' + quote(manifest) + ' >/dev/null 2>&1', 'r');
        require(hash != null && hash.close() == 0);
        if (pid != null) require(command([ '/bin/kill', '-0', pid ]) == 0);
    } else require(pid == null);
}
print('MIGRATION_ADMISSION=ADMITTED\n');
UCODE
)" -- "$@"
