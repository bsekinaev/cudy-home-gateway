// Portable OpenWrt migration journal/fence primitive, not a migration installer.
// No Python, global sync(), pid lookup, service/UCI/nft or runtime writes.
import * as fs from 'fs';

function require(ok, reason) { if (!ok) die('MIGRATION_STATE_' + reason); }
function quote(s) { return "'" + replace(s, "'", "'\\''") + "'"; }
function command(args) {
    let p = fs.popen(join(' ', map(args, quote)) + ' >/dev/null 2>&1', 'r');
    require(p != null, 'EXEC_FAILED');
    return p.close();
}
const TRANSITIONS = {
    PREPARING: [ 'PREPARED' ], PREPARED: [ 'APPLYING', 'RESTORING' ],
    APPLYING: [ 'RESTORING', 'COMMITTED' ], COMMITTED: [ 'RESTORING' ],
    RESTORING: [ 'ROLLED_BACK' ], ROLLED_BACK: [],
};

export function open_state(root, create, test_busybox, rollback_only, boot_only, borrowed_guard) {
    require(borrowed_guard==null || borrowed_guard==true, 'BORROW_MODE');
    require(!borrowed_guard || (!boot_only && !rollback_only), 'BORROW_MODE');
    require(boot_only==null || boot_only==true, 'BOOT_MODE');
    require(!boot_only || (!create && !rollback_only), 'BOOT_MODE');
    require(rollback_only==null || rollback_only==true, 'RECOVERY_MODE');
    require(!rollback_only || (root!=null && root!='' && !create), 'RECOVERY_NOT_ACCEPTED');
    root ??= '';
    require(type(root) == 'string' && (root == '' ||
        (match(root, /^\/[A-Za-z0-9_.\/-]+$/) && root != '/' &&
         !match(root, /(^|\/)\.\.?($|\/)/))), 'ROOT');
    let owner = 0, group = 0, busybox = '/bin/busybox';
    if (root != '') {
        let marker = fs.lstat(root + '/.hg-deploy-test-root');
        require(marker?.type == 'file' && marker.nlink == 1 && marker.size <= 128, 'LAB_MARKER');
        owner = fs.lstat(root).uid; group = fs.lstat(root).gid;
        require(marker.uid == owner && marker.gid == group, 'LAB_MARKER');
        require(type(test_busybox) == 'string' && match(test_busybox, /^\/[A-Za-z0-9_.\/-]+$/), 'TEST_BUSYBOX');
        busybox = test_busybox;
    } else require(test_busybox == null, 'PRODUCTION_OVERRIDE');
    const BASE = root + '/etc/home-gateway-migration';
    const LOCK = root + '/etc/home-gateway-migration.lock';
    const RAM = root + '/tmp/home-gateway-deploy.lock';
    const FENCE = BASE + '/fence';
    let MARKER = null;
    function marker_valid(raw) { return match(raw, /^HG_MIGRATION_STATE_V1 [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\n$/) != null; }

    function ancestry(path) {
        let parts = split(path, '/'), current = '';
        for (let i = 1; i < length(parts) - 1; i++) {
            current += '/' + parts[i]; let st = fs.lstat(current);
            require(st?.type == 'directory' && (st.uid == 0 || st.uid == owner) &&
                (!(st.mode & 022) || st.perm.sticky), 'PARENT');
        }
    }
    function checked(path, kind, mode, limit) {
        ancestry(path);
        let st = fs.lstat(path);
        require(st?.type == kind && st.uid == owner && st.gid == group && st.mode == mode, 'METADATA');
        if (kind == 'file') require(st.nlink == 1 && st.size <= limit, 'FILE_METADATA');
        return st;
    }
    function read(path, limit) {
        let st = checked(path, 'file', 0600, limit), f = fs.open(path, 're');
        require(f != null, 'READ_FAILED');
        let data = f.read(limit + 1); let closed = f.close();
        require(closed != null && type(data) == 'string' && length(data) == st.size &&
            length(data) <= limit && fs.lstat(path).inode == st.inode, 'READ_CHANGED');
        return data;
    }
    function sync(paths) {
        // BusyBox fsync checks fsync(2)'s return value. Stock OpenWrt sync has
        // neither file fsync semantics nor useful failure reporting.
        require(command([ '/usr/bin/env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'timeout', '-k', '2', '30', busybox, 'fsync', ...paths ]) == 0, 'DURABILITY_FAILED');
    }
    function exclusive(path, bytes) {
        require(fs.lstat(path) == null, 'UNKNOWN_TEMPORARY');
        let f = fs.open(path, 'wxe', 0600);
        require(f != null && fs.chmod(path, 0600), 'WRITE_FAILED');
        let ok = f.write(bytes) == length(bytes) && f.flush() != null;
        if (f.close() == null) ok = false;
        require(ok, 'WRITE_FAILED');
        checked(path, 'file', 0600, 128); sync([ path, replace(path, /\/[^/]+$/, '') ]);
    }
    function atomic(name, bytes) {
        let pending = BASE + '/' + name + '.new', final = BASE + '/' + name;
        exclusive(pending, bytes);
        require(fs.rename(pending, final), 'RENAME_FAILED'); sync([ BASE ]);
    }
    // Do not create a lock or adopt an existing unknown directory on refusal.
    if (fs.lstat(BASE) != null) {
        checked(BASE, 'directory', 0700, 0);
        MARKER = read(BASE + '/marker', 128);
        require(marker_valid(MARKER) && fs.lstat(LOCK) != null, 'UNKNOWN_STATE');
    }
    else require(fs.lstat(RAM) == null, 'FOREIGN_FENCE');
    ancestry(LOCK);
    let prior = fs.lstat(LOCK);
    if (prior != null) checked(LOCK, 'file', 0600, 0);
    require(create || prior != null, 'NO_STATE');
    require(!borrowed_guard || prior!=null, 'BORROW_MISSING_GUARD');
    let guard = borrowed_guard ? fs.fdopen(8,'r') : fs.open(LOCK, create ? 'ae' : 're', 0600);
    // FD8 shares the shell coordinator's open file description. Closing this
    // child handle must not release the parent's kernel lease. FIOCLEX sets
    // close-on-exec in this child's fd table, keeping fsync/hash helpers from
    // retaining the lease after a killed native child. Parent FD8 is unchanged.
    if(borrowed_guard)require(guard!=null && guard.ioctl(fs.IOC_DIR_NONE,0x54,0x51)==0,'BORROW_CLOEXEC');
    require(guard != null && (prior != null || fs.chmod(LOCK, 0600)), 'LOCK_FAILED');
    let lock_stat = checked(LOCK, 'file', 0600, 0);
    let held = fs.stat('/proc/self/fd/' + guard.fileno());
    require(held?.inode == lock_stat.inode && held.dev.major == lock_stat.dev.major &&
        held.dev.minor == lock_stat.dev.minor && guard.lock('xn') != null &&
        fs.lstat(LOCK).inode == held.inode, 'BUSY');
    if (prior == null) sync([ LOCK, root + '/etc' ]);
    if (fs.lstat(BASE) == null) {
        require(create, 'NO_STATE');
        let entropy = fs.open('/proc/sys/kernel/random/uuid', 're');
        require(entropy != null, 'ENTROPY');
        let nonce = entropy.read(38); entropy.close();
        MARKER = 'HG_MIGRATION_STATE_V1 ' + nonce;
        require(marker_valid(MARKER), 'ENTROPY');
        // Publish only a complete, fsynced directory. An interrupted private
        // initialization is never adopted or deleted: a retry gets a fresh
        // kernel nonce under the same journal lock. No runtime/fence exists yet.
        let stage=BASE + '.initializing.' + trim(nonce);
        require(fs.lstat(stage) == null && fs.mkdir(stage, 0700), 'CREATE_FAILED');
        sync([ root + '/etc' ]);
        exclusive(stage + '/marker', MARKER);
        exclusive(stage + '/phase', 'PREPARING\n');
        sync([ stage ]);
        require(fs.lstat(BASE) == null && fs.rename(stage, BASE), 'PUBLISH_FAILED');
        sync([ root + '/etc' ]);
    }
    checked(BASE, 'directory', 0700, 0);
    require(read(BASE + '/marker', 128) == MARKER, 'UNKNOWN_STATE');
    function phase() {
        let raw = read(BASE + '/phase', 32), p = trim(raw);
        require(TRANSITIONS[p] != null && raw == p + '\n', 'PHASE');
        return p;
    }
    // Boot must rebuild the volatile fence before inspecting a damaged or
    // interrupted phase. It never advances/replays that phase.
    if(!boot_only)phase();
    require(boot_only || rollback_only || fs.lstat(BASE + '/phase.new') == null, 'INCOMPLETE_PHASE_WRITE');
    function held_guard() {
        let fd=guard.fileno();
        require(fd != null, 'CLOSED_GUARD');
        let current=checked(LOCK, 'file', 0600, 0), held_now=fs.stat('/proc/self/fd/' + fd);
        require(held_now?.inode == lock_stat.inode && current.inode == lock_stat.inode &&
            held_now.dev.major == lock_stat.dev.major && held_now.dev.minor == lock_stat.dev.minor &&
            read(BASE + '/marker', 128) == MARKER, 'GUARD_CHANGED');
    }
    function owned_fence() {
        checked(FENCE, 'directory', 0700, 0);
        require(read(FENCE + '/marker', 128) == MARKER, 'FENCE_MARKER');
        let entries = fs.lsdir(FENCE);
        require(length(entries) == 1 && entries[0] == 'marker', 'UNKNOWN_FENCE');
        let st = fs.lstat(RAM);
        require(st?.type == 'link' && st.nlink == 1 && st.uid == owner && st.gid == group && fs.readlink(RAM) == FENCE, 'FOREIGN_FENCE');
    }
    return {
        close: function() { guard.close(); },
        assert_root: function(expected) { require(expected == root, 'ROOT_MISMATCH'); held_guard(); },
        phase,
        recover_rollback_phase: function() {
            held_guard(); owned_fence();
            if(fs.lstat(BASE+'/phase.new')==null)return;
            require(rollback_only, 'EXPLICIT_RECOVERY_REQUIRED');
            let current=phase();
            require(index(['PREPARING','PREPARED','APPLYING','COMMITTED','RESTORING'],current)>=0, 'RECOVERY_PHASE');
            let raw=read(BASE+'/phase.new',32);
            require(length(filter(TRANSITIONS[current],p=>length(raw)<=length(p+'\n') &&
                raw==substr(p+'\n',0,length(raw))))>0, 'UNKNOWN_PHASE_WRITE');
            // Preserve evidence; never replay the interrupted transition or
            // overwrite an older incident. Caller verifies snapshots/live first.
            let target=null;
            for(let i=0;i<8;i++) {
                let path=BASE+'/phase.interrupted'+(i?'.'+i:'');
                if(fs.lstat(path)==null) { if(target==null)target=path;continue; }
                let prior=read(path,32);
                require(length(filter(['PREPARED','APPLYING','RESTORING','COMMITTED','ROLLED_BACK'],p=>
                    length(prior)<=length(p+'\n') && prior==substr(p+'\n',0,length(prior))))>0,'UNKNOWN_RECOVERY_EVIDENCE');
            }
            require(target!=null, 'RECOVERY_EVIDENCE_LIMIT');
            require(fs.rename(BASE+'/phase.new',target), 'RECOVERY_ARCHIVE');
            sync([BASE]);
        },
        transition: function(next) {
            held_guard(); owned_fence();
            require(!boot_only, 'BOOT_ONLY');
            require(fs.lstat(BASE+'/phase.new')==null, 'INCOMPLETE_PHASE_WRITE');
            require(!rollback_only || (next!='APPLYING' && next!='COMMITTED' && next!='ROLLED_BACK'), 'ROLLBACK_ONLY');
            let current = phase();
            require(index(TRANSITIONS[current], next) >= 0, 'NO_AUTO_REPLAY');
            // Full coordinator must snapshot/verify before PREPARED and must
            // verify runtime/receiver/latest before terminal transitions.
            atomic('phase', next + '\n');
        },
        fence: function() {
            held_guard();
            if (fs.lstat(FENCE) == null) {
                let entropy=fs.open('/proc/sys/kernel/random/uuid', 're');
                require(entropy != null, 'ENTROPY');
                let nonce=entropy.read(38); entropy.close();
                require(marker_valid('HG_MIGRATION_STATE_V1 ' + nonce), 'ENTROPY');
                let stage=FENCE + '.initializing.' + trim(nonce);
                require(fs.lstat(stage) == null && fs.mkdir(stage, 0700), 'FENCE_CREATE');
                sync([ BASE ]);
                exclusive(stage + '/marker', MARKER); sync([ stage ]);
                require(fs.lstat(FENCE) == null && fs.rename(stage, FENCE), 'FENCE_PUBLISH');
                sync([ BASE ]);
            }
            if (fs.lstat(RAM) == null) {
                checked(FENCE, 'directory', 0700, 0);
                require(read(FENCE + '/marker', 128) == MARKER, 'FENCE_MARKER');
                // Atomic symlink publication; never rename flash to tmpfs.
                require(fs.symlink(FENCE, RAM), 'BUSY');
            }
            owned_fence();
        },
        release: function() {
            held_guard();
            let p = phase();
            require(p == 'COMMITTED' || p == 'ROLLED_BACK', 'NONTERMINAL');
            require(fs.lstat(BASE + '/phase.new') == null && fs.lstat(BASE + '/admission.new') == null, 'PENDING_ADMISSION');
            require(read(BASE + '/admission', 128) == 'HG_MIGRATION_ADMITTED_V2 ' + p + ' ' + trim(substr(MARKER, length('HG_MIGRATION_STATE_V1 '))) + ' ' + lock_stat.inode + '\n', 'NOT_VERIFIED');
            if (fs.lstat(RAM) != null) { owned_fence(); require(fs.unlink(RAM), 'UNLINK_FAILED'); }
            sync([ root + '/tmp' ]);
        },
        // No API publishes admission: a complete coordinator must independently
        // validate snapshots, every live byte/uid/gid/mode and legacy pointers.
    };
};

// Explicit disposable recovery entrypoint. Production remains blocked until
// full boot/service recovery acceptance. Normal open_state stays fail-closed.
export function open_rollback_state(root,test_busybox) {
    return open_state(root,false,test_busybox,true);
};

// Early boot only reconstructs admission fencing; it never applies/restores
// runtime or executes services. Unknown phase writes remain blocked evidence.
export function restore_boot_fence(root,test_busybox) {
    root ??= '';
    require(type(root)=='string' && (root=='' || (root!='/' &&
        match(root,/^\/[A-Za-z0-9_.\/-]+$/) && !match(root,/(^|\/)\.\.?($|\/)/))), 'ROOT');
    if(fs.lstat(root+'/etc/home-gateway-migration')==null)return 'NO_MIGRATION';
    let state=open_state(root,false,test_busybox,null,true);
    state.fence();
    let current=state.phase();
    require(fs.lstat(root+'/etc/home-gateway-migration/phase.new')==null, 'INCOMPLETE_PHASE_WRITE');
    if(current=='COMMITTED' || current=='ROLLED_BACK')state.release();
    state.close();return current;
};
