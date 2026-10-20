// Native verified legacy snapshot. The caller must hold open_state() throughout.
// This module does not apply runtime files, publish admission or run services.
import * as fs from 'fs';

const RUNTIME = [ 'etc/init.d/home-gateway-telegram', 'usr/bin/gateway',
    'usr/bin/home-gateway-ci-smoke', 'usr/lib/home-gateway/asata.sh',
    'usr/lib/home-gateway/common.sh', 'usr/lib/home-gateway/dns.sh',
    'usr/lib/home-gateway/doctor.sh', 'usr/lib/home-gateway/health.sh',
    'usr/lib/home-gateway/incidents.uc', 'usr/lib/home-gateway/network.sh',
    'usr/lib/home-gateway/redmi.sh', 'usr/lib/home-gateway/selftest.sh',
    'usr/lib/home-gateway/status.sh', 'usr/lib/home-gateway/tailscale.sh',
    'usr/lib/home-gateway/telegram-poller.uc', 'usr/lib/home-gateway/telegram.sh',
    'usr/lib/home-gateway/torrent.sh', 'usr/lib/home-gateway/vpn.sh' ];
const PINS = {
    'usr/libexec/home-gateway-deploy/engine.sh': '4b1f9ea568167a67f24470615b31efe4b9fd7a68374e666443ad31945e58922e',
    'usr/libexec/home-gateway-deploy/wrapper.sh': 'd8694eb76c86f16dbae2599e8d68e20dfcf9d8334a488f0f407c84264099946f',
    'etc/init.d/home-gateway-deploy-recover': '5b747dff42649914e4b231de2d5ade0171eedad40d5fb53f43e4d869d08a2630',
};
function require(ok, reason) { if (!ok) die('MIGRATION_SNAPSHOT_' + reason); }
function quote(s) { return "'" + replace(s, "'", "'\\''") + "'"; }
function same(a, b) {
    return a?.type == b?.type && a.inode == b.inode && a.dev.major == b.dev.major &&
        a.dev.minor == b.dev.minor && a.mode == b.mode && a.uid == b.uid &&
        a.gid == b.gid && a.nlink == b.nlink && a.size == b.size && a.mtime == b.mtime;
}
function mode(rel) {
    if (rel == 'usr/libexec/home-gateway-deploy/engine.sh' || rel == 'usr/libexec/home-gateway-deploy/wrapper.sh') return 0700;
    return index(RUNTIME, rel) < 3 && index(RUNTIME, rel) >= 0 || rel == 'etc/init.d/home-gateway-deploy-recover' ? 0755 : 0644;
}

function boundary(root, state, test_busybox) {
    require(type(root) == 'string' && length(root) <= 256 && (root == '' || (root != '/' &&
        match(root, /^\/[A-Za-z0-9_.\/-]+$/) && !match(root, /(^|\/)\.\.?($|\/)/))), 'ROOT');
    let owner=0, group=0, bb='/bin/busybox';
    if (root != '') {
        let s=fs.lstat(root), marker=fs.lstat(root + '/.hg-deploy-test-root');
        require(s?.type == 'directory' && marker?.type == 'file' && marker.nlink == 1 && marker.size <= 128 && marker.uid == s.uid && marker.gid == s.gid, 'LAB_MARKER');
        require(type(test_busybox) == 'string' && match(test_busybox, /^\/[A-Za-z0-9_.\/-]+$/), 'BUSYBOX');
        owner=s.uid; group=s.gid; bb=test_busybox;
    } else require(test_busybox == null, 'OVERRIDE');
    require(type(state) == 'object' && type(state.phase) == 'function' && type(state.assert_root) == 'function', 'GUARD');
    state.assert_root(root);
    state.fence();
    const active_base=root + '/etc/home-gateway-migration';
    const BASE=state.archive_base??active_base;
    // Only an explicitly guarded read-only terminal archive may redirect the
    // existing verifiers. No archive replay or writes through this view.
    require(BASE==active_base || (state.read_only==true && state.phase()=='ROLLED_BACK' &&
        match(BASE, /^\/[A-Za-z0-9_.\/-]+$/) &&
        index(BASE,active_base+'.retired.')==0 &&
        match(substr(BASE,length(active_base+'.retired.')), /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)), 'ARCHIVE_SCOPE');
    function ancestry(path) {
        let prefix='', parts=split(path, '/');
        for (let i=1; i<length(parts)-1; i++) {
            prefix += '/' + parts[i]; let s=fs.lstat(prefix);
            require(s?.type == 'directory' && (s.uid == 0 || s.uid == owner) && (!(s.mode & 022) || s.perm.sticky), 'PARENT');
        }
    }
    function checked(path, kind, permissions, limit) {
        ancestry(path); let s=fs.lstat(path);
        require(s?.type == kind && s.uid == owner && s.gid == group && s.mode == permissions, 'METADATA');
        if (kind == 'file') require(s.nlink == 1 && s.size <= limit, 'FILE_METADATA');
        return s;
    }
    function read(path, permissions, limit) {
        let before=checked(path, 'file', permissions, limit), f=fs.open(path, 're');
        require(f != null, 'READ');
        let held=fs.stat('/proc/self/fd/' + f.fileno());
        require(same(before, held), 'READ_CHANGED');
        let raw=f.read(limit+1), closed=f.close();
        require(closed != null && type(raw) == 'string' && length(raw) == before.size && same(before, fs.lstat(path)), 'READ_CHANGED');
        return raw;
    }
    function sync(paths) {
        let args=[ '/usr/bin/env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'timeout', '-k', '2', '30', bb, 'fsync', ...paths ];
        let p=fs.popen(join(' ', map(args, quote)) + ' >/dev/null 2>&1', 'r');
        require(p != null && p.close() == 0, 'FSYNC');
    }
    function mkdir(path) {
        if (fs.lstat(path) != null) { checked(path, 'directory', 0700, 0); return; }
        let parent=replace(path, /\/[^/]+$/, '');
        if (parent != BASE) mkdir(parent);
        checked(parent, 'directory', 0700, 0);
        require(fs.mkdir(path, 0700), 'MKDIR'); sync([ parent ]);
    }
    function write(path, raw, permissions) {
        require(BASE==active_base, 'ARCHIVE_READ_ONLY');
        require(fs.lstat(path) == null, 'PARTIAL_OR_FOREIGN');
        let parent=replace(path, /\/[^/]+$/, ''); mkdir(parent);
        let f=fs.open(path, 'wxe', permissions); require(f != null && fs.chmod(path, permissions), 'WRITE');
        let ok=f.write(raw) == length(raw) && f.flush() != null;
        if (f.close() == null) ok=false;
        require(ok, 'WRITE'); checked(path, 'file', permissions, 262144); sync([ path, parent ]);
    }
    function hashes(paths) {
        require(length(paths) > 0 && length(paths) <= 128, 'HASH_BUDGET');
        let args=[ '/usr/bin/env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'timeout', '-k', '2', '30', 'sha256sum', ...paths ];
        let p=fs.popen(join(' ', map(args, quote)) + ' 2>/dev/null', 'r'); require(p != null, 'HASH');
        let raw=p.read(65537), rc=p.close();
        require(rc == 0 && type(raw) == 'string' && length(raw) <= 65536, 'HASH');
        let rows=split(raw, '\n'); require(pop(rows) == '' && length(rows) == length(paths), 'HASH');
        let result={};
        for (let i=0; i<length(paths); i++) {
            require(match(substr(rows[i], 0, 64), /^[0-9a-f]{64}$/) && substr(rows[i], 64) == '  ' + paths[i], 'HASH');
            result[paths[i]]=substr(rows[i], 0, 64);
        }
        return result;
    }
    function manifest(raw) {
        let rows=split(raw, '\n'); require(pop(rows) == '' && length(rows) == 18, 'INVENTORY');
        let records={};
        for (let row in rows) {
            let digest=substr(row, 0, 64), path=substr(row, 66);
            require(match(digest, /^[0-9a-f]{64}$/) && substr(row, 64, 2) == '  ' && index(RUNTIME, path) >= 0 && records[path] == null, 'INVENTORY');
            records[path]=digest;
        }
        return records;
    }
    function space(bytes) {
        let args=[ '/usr/bin/env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'timeout', '-k', '2', '10', bb, 'df', '-Pk', BASE ];
        let p=fs.popen(join(' ', map(args, quote)) + ' 2>/dev/null', 'r'); require(p != null, 'SPACE');
        let raw=p.read(4097), rc=p.close();
        require(rc == 0 && type(raw) == 'string' && length(raw) <= 4096, 'SPACE');
        let rows=filter(split(raw, '\n'), row => length(row) > 0);
        require(length(rows) == 2, 'SPACE');
        let columns=split(trim(rows[1]), /\s+/);
        require(length(columns) == 6 && match(columns[3], /^[0-9]{1,12}$/) &&
            +columns[3] * 1024 >= bytes * 2 + 1048576, 'SPACE');
    }
    checked(BASE, 'directory', 0700, 0);
    return { BASE, read, checked, write, hashes, manifest, sync, space };
}

// Internal coordinator I/O; always requires the held root-bound guard/fence.
export function snapshot_io(root, state, test_busybox) {
    return boundary(root, state, test_busybox);
};

export function verify_legacy_snapshot(root, state, test_busybox, abort_only) {
    require(abort_only==null || abort_only==true,'VERIFY_MODE');
    let io=boundary(root, state, test_busybox);
    require(fs.lstat(io.BASE + '/snapshot.json.new') == null, 'PARTIAL_OR_FOREIGN');
    if(abort_only && fs.lstat(io.BASE+'/snapshot.publish-pending')!=null) {
        let raw=io.read(io.BASE+'/snapshot.publish-pending',0600,128),marker=io.read(io.BASE+'/marker',0600,128);
        require(length(raw)<=length(marker) && raw==substr(marker,0,length(raw)),'PARTIAL_OR_FOREIGN');
    } else require(fs.lstat(io.BASE+'/snapshot.publish-pending')==null,'PARTIAL_OR_FOREIGN');
    let receipt=json(io.read(io.BASE + '/snapshot.json', 0600, 65536));
    require(type(receipt) == 'object' && join(',', sort(keys(receipt))) == 'files,format,latest,marker' &&
        receipt.format == 'HG_LEGACY_SNAPSHOT_V1' && match(receipt.latest, /^tx\.[a-zA-Z0-9]{1,32}\n$/) &&
        receipt.marker == io.read(io.BASE + '/marker', 0600, 128) && type(receipt.files) == 'object', 'RECEIPT');
    let required=[ 'latest', ...map([ ...RUNTIME, ...keys(PINS) ], rel => 'runtime/' + rel),
        ...map(RUNTIME, rel => 'journal/backup/' + rel), 'journal/phase', 'journal/commit',
        'journal/was-running', 'journal/new.sha256', 'journal/backup.sha256',
        'journal/preflight.log', 'journal/postflight.log', 'journal/service.log' ];
    let names=keys(receipt.files);
    require(length(names) == length(required) &&
        length(filter(required, name => receipt.files[name] != null)) == length(required), 'INVENTORY');
    let paths=[], actual=[], total=0, dirs=0;
    for (let rel in names) {
        require(index(required, rel) >= 0, 'INVENTORY');
        let record=receipt.files[rel], runtime=index(rel, 'runtime/') == 0,
            backup=index(rel, 'journal/backup/') == 0;
        let perm=runtime ? mode(substr(rel, 8)) : backup ? mode(substr(rel, 15)) : 0600;
        require(type(record) == 'object' && join(',', sort(keys(record))) == 'mode,sha256' &&
            record.mode == perm && match(record.sha256, /^[0-9a-f]{64}$/), 'RECEIPT');
        let path=io.BASE + '/old/' + rel;
        total += io.checked(path, 'file', perm, 262144).size; paths[length(paths)]=path;
    }
    require(total <= 8388608, 'BUDGET');
    function walk(path, prefix) {
        io.checked(path, 'directory', 0700, 0); require(++dirs <= 48, 'BUDGET');
        let entries=fs.lsdir(path); require(entries != null && length(entries) <= 32, 'INVENTORY');
        for (let name in entries) {
            let rel=prefix ? prefix + '/' + name : name, p=path + '/' + name;
            if (fs.lstat(p)?.type == 'directory') {
                require(length(filter(names, file => index(file, rel + '/') == 0)) > 0, 'INVENTORY');
                walk(p, rel);
            } else { require(index(names, rel) >= 0, 'INVENTORY'); actual[length(actual)]=rel; }
        }
    }
    walk(io.BASE + '/old', '');
    require(length(actual) == length(names), 'INVENTORY');
    let hashes=io.hashes(paths);
    for (let rel in names) require(hashes[io.BASE + '/old/' + rel] == receipt.files[rel].sha256, 'SNAPSHOT_CHANGED');
    for (let rel, pin in PINS) require(receipt.files['runtime/' + rel].sha256 == pin, 'LEGACY_IDENTITY');
    let old=io.BASE + '/old/';
    require(io.read(old + 'latest', 0600, 40) == receipt.latest &&
        io.read(old + 'journal/phase', 0600, 32) == 'COMMITTED\n' &&
        match(io.read(old + 'journal/commit', 0600, 41), /^[0-9a-f]{40}\n$/) &&
        match(io.read(old + 'journal/was-running', 0600, 2), /^[01]\n$/), 'JOURNAL');
    let live=io.manifest(io.read(old + 'journal/new.sha256', 0600, 8192));
    let backup=io.manifest(io.read(old + 'journal/backup.sha256', 0600, 8192));
    for (let rel in RUNTIME) require(live[rel] == receipt.files['runtime/' + rel].sha256 &&
        backup[rel] == receipt.files['journal/backup/' + rel].sha256, 'HASH_MISMATCH');
    return receipt;
};

export function prepare_legacy_snapshot(root, state, test_busybox, verify_only) {
    require(verify_only==null || verify_only==true,'VERIFY_MODE');
    require(verify_only || state.phase() == 'PREPARING', 'NO_REPLAY');
    let io=boundary(root, state, test_busybox), deploy=root + '/etc/home-gateway-deploy';
    io.checked(deploy, 'directory', 0700, 0);
    require(fs.lstat(deploy + '/active') == null && fs.lstat(deploy + '/active.new') == null &&
        fs.lstat(deploy + '/latest.new') == null, 'ACTIVE_OR_PENDING_POINTER');
    let latest=io.read(deploy + '/latest', 0600, 40);
    require(match(latest, /^tx\.[a-zA-Z0-9]{1,32}\n$/), 'LATEST');
    let tx=deploy + '/' + trim(latest);
    io.checked(tx, 'directory', 0700, 0);
    require(fs.lstat(tx + '/inventory-version') == null && io.read(tx + '/phase', 0600, 32) == 'COMMITTED\n', 'FORMAT');
    require(match(io.read(tx + '/commit', 0600, 41), /^[0-9a-f]{40}\n$/) &&
        match(io.read(tx + '/was-running', 0600, 2), /^[01]\n$/), 'JOURNAL');
    let live=io.manifest(io.read(tx + '/new.sha256', 0600, 8192));
    let backup=io.manifest(io.read(tx + '/backup.sha256', 0600, 8192));
    for (let added in [ 'actions.uc', 'notifications.uc' ]) require(fs.lstat(root + '/usr/lib/home-gateway/' + added) == null, 'INVENTORY');
    let library=fs.lsdir(root + '/usr/lib/home-gateway');
    require(library != null && length(library) == 15 &&
        length(filter(library, name => index(RUNTIME, 'usr/lib/home-gateway/' + name) >= 0)) == 15, 'INVENTORY');
    require(verify_only || (fs.lstat(io.BASE + '/old') == null && fs.lstat(io.BASE + '/snapshot.json') == null && fs.lstat(io.BASE + '/snapshot.json.new') == null &&
        fs.lstat(io.BASE + '/snapshot.publish-pending') == null), 'PARTIAL_OR_FOREIGN');
    let sources={}, metadata={}, permissions={}, total=0;
    function add(path, rel, perm) {
        metadata[path]=io.checked(path, 'file', perm, 262144);
        sources[rel]=io.read(path, perm, 262144); permissions[rel]=perm;
        total += length(sources[rel]); require(total <= 8388608 && length(keys(sources)) <= 128, 'BUDGET');
    }
    for (let rel in [ ...RUNTIME, ...keys(PINS) ]) add(root + '/' + rel, 'runtime/' + rel, mode(rel));
    add(deploy + '/latest', 'latest', 0600);
    let dirs=0, rechecked={};
    function walk(path, prefix, recheck) {
        io.checked(path, 'directory', 0700, 0); require(++dirs <= 32, 'BUDGET');
        let entries=fs.lsdir(path); require(entries != null && length(entries) <= 32, 'JOURNAL');
        for (let name in entries) {
            require(match(name, /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$/) && name != '.' && name != '..', 'JOURNAL_PATH');
            let p=path + '/' + name, rel=prefix + '/' + name, s=fs.lstat(p);
            if (s?.type == 'directory') {
                let prefix_path=substr(rel, length('journal/backup/'));
                require(rel == 'journal/backup' || (index(rel, 'journal/backup/') == 0 &&
                    length(filter(RUNTIME, item => index(item, prefix_path + '/') == 0)) > 0), 'JOURNAL_PATH');
                walk(p, rel, recheck);
            }
            else {
                let suffix=substr(rel, length('journal/backup/'));
                if (index(rel, 'journal/backup/') == 0) require(index(RUNTIME, suffix) >= 0, 'INVENTORY');
                else require(index([ 'phase', 'commit', 'was-running', 'new.sha256', 'backup.sha256', 'preflight.log', 'postflight.log', 'service.log' ], name) >= 0 && prefix == 'journal', 'JOURNAL_PATH');
                if (recheck) { require(metadata[p] != null && same(metadata[p], fs.lstat(p)), 'SOURCE_CHANGED'); rechecked[p]=true; }
                else add(p, rel, index(rel, 'journal/backup/') == 0 ? mode(suffix) : 0600);
            }
        }
    }
    for (let name in [ 'preflight.log', 'postflight.log', 'service.log' ]) io.checked(tx + '/' + name, 'file', 0600, 262144);
    walk(tx, 'journal', false);
    let paths=keys(metadata), digests=io.hashes(paths);
    for (let p in paths) require(same(metadata[p], fs.lstat(p)), 'SOURCE_CHANGED');
    for (let rel in RUNTIME) require(digests[root + '/' + rel] == live[rel] && digests[tx + '/backup/' + rel] == backup[rel], 'HASH_MISMATCH');
    for (let rel, pin in PINS) require(digests[root + '/' + rel] == pin, 'LEGACY_IDENTITY');
    function revalidate_source() {
        let again=io.hashes(paths);
        for (let p in paths) require(same(metadata[p], fs.lstat(p)) && again[p] == digests[p], 'SOURCE_CHANGED');
        library=fs.lsdir(root + '/usr/lib/home-gateway');
        require(library != null && length(library) == 15 &&
            length(filter(library, name => index(RUNTIME, 'usr/lib/home-gateway/' + name) >= 0)) == 15, 'INVENTORY');
        dirs=0; rechecked={}; walk(tx, 'journal', true);
        require(length(keys(rechecked)) == length(filter(paths, path => index(path, tx + '/') == 0)), 'SOURCE_CHANGED');
        require(fs.lstat(tx + '/inventory-version') == null && fs.lstat(deploy + '/active') == null &&
            fs.lstat(deploy + '/active.new') == null && fs.lstat(deploy + '/latest.new') == null &&
            io.read(deploy + '/latest', 0600, 40) == latest, 'SOURCE_CHANGED');
    }
    if(!verify_only)io.space(total);
    let snapshot_records={};
    for (let path in paths) {
        let rel=path == deploy + '/latest' ? 'latest' : index(path, tx + '/') == 0 ? 'journal/' + substr(path, length(tx)+1) : 'runtime/' + substr(path, length(root)+1);
        snapshot_records[rel]={ sha256:digests[path], mode:permissions[rel] };
    }
    if(verify_only) {revalidate_source();return {format:'HG_LEGACY_CURRENT_V1',marker:io.read(io.BASE+'/marker',0600,128),latest,files:snapshot_records};}
    // No source mutation occurs before complete metadata/identity validation.
    // Partial private snapshots are retained on failure, never auto-adopted.
    for (let rel, raw in sources) io.write(io.BASE + '/old/' + rel, raw, permissions[rel]);
    let copy_paths=map(keys(sources), rel => io.BASE + '/old/' + rel), copies=io.hashes(copy_paths);
    for (let rel in keys(sources)) require(copies[io.BASE + '/old/' + rel] == snapshot_records[rel].sha256, 'SNAPSHOT_CHANGED');
    revalidate_source();
    let receipt={ format:'HG_LEGACY_SNAPSHOT_V1', marker:io.read(io.BASE + '/marker', 0600, 128), latest, files:snapshot_records };
    let pending=io.BASE + '/snapshot.json.new'; io.write(pending, sprintf('%J\n', receipt), 0600);
    io.write(io.BASE + '/snapshot.publish-pending', receipt.marker, 0600);
    // The pending-receipt/marker fsync may block; certify sources afterward.
    revalidate_source();
    require(fs.rename(pending, io.BASE + '/snapshot.json'), 'PUBLISH'); io.sync([ io.BASE ]);
    require(fs.unlink(io.BASE + '/snapshot.publish-pending'), 'PUBLISH'); io.sync([ io.BASE ]);
    return verify_legacy_snapshot(root, state, test_busybox);
};

// No snapshot adoption, creation, cleanup or runtime writes. A caller must hold
// the same root-bound guard; use only to abort PREPARING with no live controls.
export function verify_current_legacy(root,state,test_busybox) {
    return prepare_legacy_snapshot(root,state,test_busybox,true);
};
