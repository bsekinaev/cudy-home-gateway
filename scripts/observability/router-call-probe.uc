// Read-only projection for Telegram call troubleshooting; no active traffic tests.
import * as fs from 'fs';
let source=ARGV[0];
if(type(source)!='string' || !match(source,/^[a-f0-9]{40}$/)) exit(64);
function run(command,limit) {
    let proc=fs.popen(command+' 2>/dev/null','r');if(!proc)return null;
    let raw=proc.read(limit+1),code=proc.close();
    return code==0 && type(raw)=='string' && length(raw)<=limit?raw:null;
}
function uci(key) {
    // Only fixed keys or validated profile IDs may reach this function.
    let raw=run("timeout -k 1 2 uci -q get '"+key+"'",2048);
    return raw==null?null:trim(raw);
}
function state(value) {return value=='1'?'ENABLED':value=='0'?'DISABLED':'UNKNOWN';}
function ports(value) {
    if(value==null)return 'UNKNOWN';
    if(value=='')return 'EMPTY';if(value=='disable')return 'DISABLED';
    if(length(value)>1024 || !match(value,/^[0-9,: -]+$/))return 'UNKNOWN';
    let all=false;
    for(let part in split(replace(value,' ',''),',')) {
        let bounds=split(replace(part,'-',':'),':');
        if(length(bounds)<1 || length(bounds)>2)return 'UNKNOWN';
        for(let n in bounds)if(!match(n,/^[0-9]{1,5}$/) || int(n)<1 || int(n)>65535)return 'UNKNOWN';
        if(length(bounds)==2 && int(bounds[0])>int(bounds[1]))return 'UNKNOWN';
        if(length(bounds)==2 && int(bounds[0])==1 && int(bounds[1])==65535)all=true;
    }
    return all?'ALL':'PARTIAL';
}
function object(value) {return type(value)=='object';}
function array(value) {return type(value)=='array'?value:[];}
function has(value,key) {return object(value) && index(keys(value),key)>=0;}
function parsed(raw) {try {let data=raw==null?null:json(raw);return object(data)?data:null;}catch(error){return null;}}
function unique(items,value) {if(index(items,value)<0)push(items,value);}
function udp_network(value) {return type(value)=='string' && index(map(split(value,','),part=>trim(part)),'udp')>=0;}
let main=uci('passwall2.rulenode.default_node');
if(type(main)!='string' || !match(main,/^[A-Za-z0-9_]{1,64}$/))main=null;
let report={schema_version:1,source_commit:source,
    passwall_enabled_state:state(uci('passwall2.@global[0].enabled')),
    client_proxy_state:state(uci('passwall2.@global[0].client_proxy')),
    udp_exclusion_mode:ports(uci('passwall2.@global_forwarding[0].udp_no_redir_ports')),
    udp_redirect_mode:ports(uci('passwall2.@global_forwarding[0].udp_redir_ports')),
    udp_drop_mode:ports(uci('passwall2.@global_forwarding[0].udp_drop_ports')),
    udp_proxy_drop_mode:ports(uci('passwall2.@global_forwarding[0].udp_proxy_drop_ports')),
    redmi_enabled_state:state(uci('passwall2.acl_A2dNs.enabled')),
    redmi_udp_exclusion_mode:ports(uci('passwall2.acl_A2dNs.udp_no_redir_ports')),
    redmi_udp_redirect_mode:ports(uci('passwall2.acl_A2dNs.udp_redir_ports')),
    configs:[],configs_truncated:false,firewall_state:'UNKNOWN',
    udp_match_rules:null,tproxy_rules:null,asata_udp_direct_rule:'UNKNOWN',call_connectivity:'UNVERIFIED'};
let dir=getenv('HG_CALL_CONFIG_DIR') || '/tmp/etc/passwall2';
let identity=fs.stat('/proc/self'),owner=identity?identity.uid:null;
let names=filter(fs.lsdir(dir) || [],name=>match(name,/^[A-Za-z0-9_-]{1,80}\.json$/));
report.configs_truncated=length(names)>8;
for(let name in sort(names)) {
    if(length(report.configs)>=8)break;
    let role=name=='acl_A2dNs.json'?'REDMI':main && name==main+'.json'?'MAIN_SOCKS':
        index(['global.json','default.json','acl_default.json'],name)>=0?'GLOBAL':'OTHER';
    let item={role,config_state:'UNREADABLE',udp_transparent_inbounds:null,
        udp_enabled_socks_inbounds:null,proxy_protocols:[],proxy_transports:[],
        broad_udp_direct_rule:'UNKNOWN',outbound_count:null};
    push(report.configs,item);
    let path=dir+'/'+name,meta=fs.lstat(path);
    if(!meta || meta.type!='file' || meta.uid!=owner || meta.perm.group_write || meta.perm.other_write) {item.config_state='UNSAFE';continue;}
    let file=fs.open(path,'r');if(!file)continue;
    let raw=file.read(262145);file.close();
    let cfg=type(raw)=='string' && length(raw)<=262144?parsed(raw):null;
    if(!cfg)continue;
    item.config_state='READABLE';item.udp_transparent_inbounds=0;item.udp_enabled_socks_inbounds=0;
    item.broad_udp_direct_rule='ABSENT';item.outbound_count=length(array(cfg.outbounds));
    for(let inbound in array(cfg.inbounds)) {
        if(!object(inbound) || !object(inbound.settings))continue;
        let settings=inbound.settings;
        if(inbound.protocol=='socks' && settings.udp===true)item.udp_enabled_socks_inbounds++;
        if(inbound.protocol=='dokodemo-door' && udp_network(settings.network) && object(inbound.streamSettings) &&
            object(inbound.streamSettings.sockopt) && inbound.streamSettings.sockopt.tproxy=='tproxy')item.udp_transparent_inbounds++;
    }
    let direct_tags=[];
    for(let outbound in array(cfg.outbounds)) {
        if(!object(outbound))continue;
        let proto=index(['vless','vmess','trojan','socks','freedom','blackhole','dns','shadowsocks','wireguard'],outbound.protocol)>=0?outbound.protocol:'OTHER';
        unique(item.proxy_protocols,proto);
        if(proto=='freedom' && type(outbound.tag)=='string')push(direct_tags,outbound.tag);
        if(index(['freedom','blackhole','dns'],proto)>=0)continue;
        let transport=object(outbound.streamSettings)?outbound.streamSettings.network:null;
        transport=transport==null?'UNSPECIFIED':index(['tcp','raw','grpc','ws','xhttp','splithttp','httpupgrade','http','h2','quic','kcp'],transport)>=0?transport:'OTHER';
        unique(item.proxy_transports,transport);
    }
    for(let rule in array(object(cfg.routing)?cfg.routing.rules:null)) {
        if(!object(rule) || !udp_network(rule.network) || index(direct_tags,rule.outboundTag)<0)continue;
        if(length(filter(keys(rule),key=>index(['type','network','outboundTag','ruleTag'],key)<0))==0)item.broad_udp_direct_rule='PRESENT';
    }
}
let nft=parsed(run('timeout -k 1 4 nft -j list chain inet passwall2 PSW2_MANGLE',262144));
if(nft && type(nft.nftables)=='array') {
    report.firewall_state='READABLE';report.udp_match_rules=0;report.tproxy_rules=0;report.asata_udp_direct_rule='ABSENT';
    for(let entry in nft.nftables) {
        if(!object(entry) || !object(entry.rule))continue;
        let rule=entry.rule,udp=false,ret=false,tproxy=false;
        for(let expr in array(rule.expr)) {
            if(has(expr,'return'))ret=true;if(has(expr,'tproxy'))tproxy=true;
            if(!object(expr) || !object(expr.match))continue;
            let m=expr.match,left=m.left;
            if(m.op!='==' || !object(left) || index(['udp',17],m.right)<0)continue;
            if(object(left.meta) && left.meta.key=='l4proto')udp=true;
            if(object(left.payload) && left.payload.protocol=='ip' && left.payload.field=='protocol')udp=true;
        }
        if(udp)report.udp_match_rules++;if(tproxy)report.tproxy_rules++;
        if(rule.comment=='ASATA-UDP-DIRECT' && udp && ret)report.asata_udp_direct_rule='PRESENT';
    }
}
print('HG_CALL_READINESS_V1\n'+sprintf('%J',report)+'\n');
