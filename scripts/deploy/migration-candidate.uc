// Native candidate staging ONLY. No runtime publication, phase advancement,
// admission, service execution or automatic adoption of a partial snapshot.
import * as fs from 'fs';
import { snapshot_io, verify_legacy_snapshot } from './migration-snapshot.uc';
const FILES = [ 'etc/init.d/home-gateway-telegram', 'usr/bin/gateway',
    'usr/bin/home-gateway-ci-smoke', 'usr/lib/home-gateway/actions.uc',
    'usr/lib/home-gateway/asata.sh', 'usr/lib/home-gateway/common.sh',
    'usr/lib/home-gateway/dns.sh', 'usr/lib/home-gateway/doctor.sh',
    'usr/lib/home-gateway/health.sh', 'usr/lib/home-gateway/incidents.uc',
    'usr/lib/home-gateway/network.sh', 'usr/lib/home-gateway/notifications.uc',
    'usr/lib/home-gateway/redmi.sh', 'usr/lib/home-gateway/selftest.sh',
    'usr/lib/home-gateway/status.sh', 'usr/lib/home-gateway/tailscale.sh',
    'usr/lib/home-gateway/telegram-poller.uc', 'usr/lib/home-gateway/telegram.sh',
    'usr/lib/home-gateway/torrent.sh', 'usr/lib/home-gateway/vpn.sh',
    'usr/libexec/home-gateway-deploy/engine.sh',
    'usr/libexec/home-gateway-deploy/wrapper.sh', 'etc/init.d/home-gateway-deploy-recover' ];
function require(ok, reason) { if (!ok) die('MIGRATION_CANDIDATE_' + reason); }
function mode(rel) {
    if (index(rel, 'usr/libexec/') == 0) return 0700;
    return index(rel, 'etc/init.d/') == 0 || index(rel, 'usr/bin/') == 0 ? 0755 : 0644;
}
function manifest(raw) {
    let rows=split(raw, '\n'); require(pop(rows) == '' && length(rows) == 23, 'INVENTORY');
    let records={};
    for (let row in rows) {
        let hash=substr(row, 0, 64), rel=substr(row, 66);
        require(match(hash, /^[0-9a-f]{64}$/) && substr(row, 64, 2) == '  ' &&
            index(FILES, rel) >= 0 && records[rel] == null, 'INVENTORY');
        records[rel]={ sha256:hash, mode:mode(rel) };
    }
    return records;
}
function inventory(io, base, records) {
    let dirs=0, leaves=[];
    function walk(path, prefix) {
        io.checked(path, 'directory', 0700, 0); require(++dirs <= 24, 'BOUND');
        let names=fs.lsdir(path); require(names != null && length(names) <= 32, 'BOUND');
        for (let name in names) {
            let rel=prefix ? prefix + '/' + name : name, p=path + '/' + name;
            if (fs.lstat(p)?.type == 'directory') {
                require(length(filter(FILES, file => index(file, rel + '/') == 0)) > 0, 'INVENTORY');
                walk(p, rel);
            } else {
                require(rel == 'migration.sha256' || records[rel] != null, 'INVENTORY');
                io.checked(p, 'file', rel == 'migration.sha256' ? 0600 : mode(rel), 262144);
                push(leaves, rel);
            }
        }
    }
    walk(base, ''); require(length(leaves) == 24, 'INVENTORY');
}
function checked_packet(io, source, pin) {
    require(type(source) == 'string' && match(source, /^\/[A-Za-z0-9_.\/-]+$/) &&
        length(source) <= 256 && !match(source, /(^|\/)\.\.?($|\/)/) &&
        match(pin, /^[0-9a-f]{64}$/), 'INPUT');
    let path=source + '/migration.sha256', raw=io.read(path, 0600, 8192);
    require(io.hashes([ path ])[path] == pin, 'MANIFEST_PIN');
    let records=manifest(raw); inventory(io, source, records);
    let paths=map(FILES, rel => source + '/' + rel), hashes=io.hashes(paths), bytes={}, total=0;
    for (let rel in FILES) {
        let p=source + '/' + rel, data=io.read(p, mode(rel), 262144);
        require(index(data, '\r') < 0 && index(data, '\0') < 0 && hashes[p] == records[rel].sha256, 'BYTES');
        bytes[rel]=data; total += length(data);
    }
    require(total <= 8388608, 'BOUND');
    return { records, bytes, raw, total };
}

export function verify_candidate_snapshot(root, state, test_busybox) {
    let io=snapshot_io(root, state, test_busybox), path=io.BASE + '/candidate.json';
    require(fs.lstat(path + '.new') == null, 'PARTIAL');
    let receipt=json(io.read(path, 0600, 16384));
    require(type(receipt) == 'object' && join(',', sort(keys(receipt))) == 'files,format,manifest_sha256,marker,scope' &&
        receipt.format == 'HG_CANDIDATE_SNAPSHOT_V1' && receipt.scope == 'RUNTIME20_RECEIVER3' &&
        receipt.marker == io.read(io.BASE + '/marker', 0600, 128) &&
        type(receipt.files) == 'object' && length(keys(receipt.files)) == 23, 'RECEIPT');
    let packet=checked_packet(io, io.BASE + '/candidate', receipt.manifest_sha256);
    for (let rel in FILES) require(type(receipt.files[rel]) == 'object' &&
        join(',', sort(keys(receipt.files[rel]))) == 'mode,sha256' &&
        receipt.files[rel].sha256 == packet.records[rel].sha256 && receipt.files[rel].mode == mode(rel), 'RECEIPT');
    return receipt;
};

export function prepare_candidate_snapshot(root, state, test_busybox, source, pin) {
    require(state.phase() == 'PREPARING', 'NO_REPLAY');
    verify_legacy_snapshot(root, state, test_busybox);
    let io=snapshot_io(root, state, test_busybox), base=io.BASE + '/candidate';
    require(fs.lstat(base) == null && fs.lstat(io.BASE + '/candidate.json') == null &&
        fs.lstat(io.BASE + '/candidate.json.new') == null, 'PARTIAL');
    let packet=checked_packet(io, source, pin); io.space(packet.total);
    for (let rel in FILES) io.write(base + '/' + rel, packet.bytes[rel], mode(rel));
    io.write(base + '/migration.sha256', packet.raw, 0600);
    let copy=checked_packet(io, base, pin), fresh=checked_packet(io, source, pin);
    for (let rel in FILES) require(copy.bytes[rel] == packet.bytes[rel] && fresh.bytes[rel] == packet.bytes[rel], 'SOURCE_CHANGED');
    let receipt={ format:'HG_CANDIDATE_SNAPSHOT_V1', scope:'RUNTIME20_RECEIVER3',
        marker:io.read(io.BASE + '/marker', 0600, 128), manifest_sha256:pin, files:packet.records };
    let pending=io.BASE + '/candidate.json.new'; io.write(pending, sprintf('%J\n', receipt), 0600);
    fresh=checked_packet(io, source, pin);
    for (let rel in FILES) require(fresh.bytes[rel] == packet.bytes[rel], 'SOURCE_CHANGED');
    require(fs.rename(pending, io.BASE + '/candidate.json'), 'PUBLISH'); io.sync([ io.BASE ]);
    return verify_candidate_snapshot(root, state, test_busybox);
};
