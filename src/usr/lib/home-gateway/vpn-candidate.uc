'use strict';

import { stdin } from 'fs';

function reject() {
    warn('vpn-candidate: unsupported or invalid candidate configuration\n');
    exit(2);
}

function matches(value, pattern) {
    return type(value) == 'string' && match(value, pattern) != null;
}

function valid_host(value) {
    return matches(value, /^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$/);
}

function valid_path(value) {
    return matches(value, /^\/[[:graph:]]*$/) && length(value) <= 1024;
}

function render(node, listen_port) {
    if (type(node) != 'object' || node.type != 'Xray' || node.protocol != 'vless' ||
        node.tls != '1' || (node.tls_allowInsecure ?? '0') != '0' ||
        !valid_host(node.address) || !valid_host(node.tls_serverName) ||
        !matches(node.port, /^[1-9][0-9]{0,4}$/) || int(node.port) > 65535 ||
        !matches(node.uuid, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) ||
        (node.encryption ?? 'none') != 'none')
        reject();

    let supported = [
        'type', 'protocol', 'transport', 'address', 'port', 'uuid', 'tls',
        'tls_allowInsecure', 'tls_serverName', 'encryption', 'alpn', 'utls',
        'fingerprint', 'reality', 'reality_publicKey', 'reality_shortId',
        'reality_spiderX', 'flow', 'xhttp_path', 'xhttp_host', 'xhttp_mode',
        'grpc_serviceName', 'grpc_mode', 'tcp_guise', 'remarks', 'group', 'add_mode', 'timeout'
    ];
    for (let key in keys(node))
        if (index(supported, key) < 0 || type(node[key]) != 'string')
            reject();

    let network = node.transport;
    let stream = { network };
    switch (network) {
    case 'raw':
        if ((node.tcp_guise ?? 'none') != 'none')
            reject();
        break;
    case 'xhttp':
        let mode = node.xhttp_mode ?? 'auto';
        let path = node.xhttp_path ?? '/';
        if (index([ 'auto', 'packet-up', 'stream-up', 'stream-one' ], mode) < 0 ||
            !valid_path(path) ||
            (length(node.xhttp_host ?? '') && !valid_host(node.xhttp_host)))
            reject();
        stream.xhttpSettings = { mode, path, host: node.xhttp_host ?? '' };
        break;
    case 'grpc':
        if (!matches(node.grpc_serviceName, /^[-a-zA-Z0-9_.\/]{1,255}$/) ||
            index([ 'gun', 'multi' ], node.grpc_mode ?? 'gun') < 0)
            reject();
        stream.grpcSettings = {
            serviceName: node.grpc_serviceName,
            multiMode: node.grpc_mode == 'multi'
        };
        break;
    default:
        reject();
    }

    let fingerprint = node.fingerprint;
    if (fingerprint && index([ 'chrome', 'firefox', 'safari', 'ios', 'android', 'edge' ], fingerprint) < 0)
        reject();
    if (node.reality == '1') {
        if (!fingerprint || !matches(node.reality_publicKey, /^[A-Za-z0-9_-]{43}$/) ||
            !matches(node.reality_shortId ?? '', /^([a-fA-F0-9]{2}){0,8}$/) ||
            !valid_path(node.reality_spiderX ?? '/'))
            reject();
        stream.security = 'reality';
        stream.realitySettings = {
            serverName: node.tls_serverName,
            fingerprint,
            password: node.reality_publicKey,
            shortId: node.reality_shortId ?? '',
            spiderX: node.reality_spiderX ?? '/'
        };
    }
    else {
        if ((node.reality ?? '0') != '0' || node.reality_publicKey || node.reality_shortId || node.reality_spiderX)
            reject();
        stream.security = 'tls';
        stream.tlsSettings = { serverName: node.tls_serverName, allowInsecure: false };
        if (node.utls == '1' && fingerprint)
            stream.tlsSettings.fingerprint = fingerprint;
        if (node.alpn) {
            let alpn = split(node.alpn, ',');
            for (let name in alpn)
                if (index([ 'h2', 'http/1.1' ], name) < 0)
                    reject();
            stream.tlsSettings.alpn = alpn;
        }
    }

    let user = { id: node.uuid, encryption: 'none' };
    if (node.flow) {
        if (node.flow != 'xtls-rprx-vision' || network != 'raw')
            reject();
        user.flow = node.flow;
    }
    return {
        log: { loglevel: 'none' },
        inbounds: [{
            listen: '127.0.0.1', port: listen_port, protocol: 'socks',
            settings: { auth: 'noauth', udp: false }
        }],
        outbounds: [{
            protocol: 'vless',
            settings: { vnext: [{ address: node.address, port: int(node.port), users: [ user ] }] },
            streamSettings: stream
        }]
    };
}

// The caller must own the temporary port and keep stdin/stdout private.
if (length(ARGV) != 1 || !matches(ARGV[0], /^[0-9]{5}$/) ||
    int(ARGV[0]) < 49152 || int(ARGV[0]) > 65535)
    reject();
let input = stdin.read(16385);
if (!input || length(input) > 16384)
    reject();
let node;
try { node = json(input); }
catch (e) { reject(); }
printf('%J\n', render(node, int(ARGV[0])));
