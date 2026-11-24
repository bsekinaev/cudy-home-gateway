// Owner-run WAN topology inspection. No configuration writes or traffic probes.
import * as fs from 'fs';
let source=ARGV[0];
if(type(source)!='string' || !match(source,/^[a-f0-9]{40}$/)) exit(64);
function read_command(command) {
    let proc=fs.popen(command+' 2>/dev/null','r');
    if(!proc) return null;
    let raw=proc.read(32769),code=proc.close();
    if(code!=0 || type(raw)!='string' || length(raw)>32768) return null;
    return raw;
}
function read_status(name) {
    // name is selected by this program; never interpolated from router data.
    let raw=read_command('timeout -k 1 4 ubus call network.interface.'+name+' status');
    if(raw==null) return null;
    try {let value=json(raw);return type(value)=='object'?value:null;}
    catch(error) {return null;}
}
function ipv4(value) {
    if(type(value)!='string') return null;
    let octets=split(value,'.');
    if(length(octets)!=4) return null;
    let n=0;
    for(let part in octets) {
        if(!match(part,/^(0|[1-9][0-9]{0,2})$/) || int(part)>255) return null;
        n=n*256+int(part);
    }
    return n;
}
function addresses(status) {
    let result={ranges:[],complete:true};
    if(type(status)=='object' && status['ipv4-address']==null) return result;
    if(type(status)!='object' || type(status['ipv4-address'])!='array') {
        result.complete=false;return result;
    }
    for(let item in status['ipv4-address']) {
        let address=type(item)=='object'?ipv4(item.address):null;
        let prefix=type(item)=='object'?item.mask:null;
        if(address==null || type(prefix)!='int' || prefix<0 || prefix>32) {
            result.complete=false;continue;
        }
        let size=1;for(let bit=prefix;bit<32;bit++) size*=2;
        let start=int(address/size)*size;
        push(result.ranges,{address,prefix,start,end:start+size-1});
    }
    return result;
}
function scope(address) {
    if(address>=167772160 && address<=184549375 ||
       address>=2886729728 && address<=2887778303 ||
       address>=3232235520 && address<=3232301055) return 'PRIVATE';
    if(address>=1681915904 && address<=1686110207) return 'CGNAT';
    if(address>=2851995648 && address<=2852061183) return 'LINK_LOCAL';
    if(address<16777216 || address>=2130706432 && address<=2147483647 ||
       address>=3758096384) return 'SPECIAL';
    // Includes documentation/reserved ranges: do not claim public reachability.
    return 'OTHER';
}
function valid_device(value) {
    return type(value)=='string' && length(value)<=64 && match(value,/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/);
}
let wan=read_status('wan'),lan=read_status('lan');
let wa=addresses(wan),la=addresses(lan);
let protocol=wan && index(['dhcp','static','pppoe'],wan.proto)>=0?wan.proto:wan && type(wan.proto)=='string'?'OTHER':'UNKNOWN';
let up=wan && wan.up===true?'UP':wan && wan.up===false?'DOWN':'UNKNOWN';
let device=wan?wan.l3_device:null;
let route='UNKNOWN',gateway='UNKNOWN';
if(valid_device(device)) {
    // iproute2 omits dev from its display when a device filter is supplied.
    // Read main-table defaults without that filter, then match the device here.
    let raw=read_command('timeout -k 1 3 ip -4 route show default');
    if(raw!=null) {
        route='MISSING';
        for(let line in split(trim(raw),'\n')) {
            let tokens=split(trim(line),/\s+/),dev_index=index(tokens,'dev');
            if(index(['default','0.0.0.0/0'],tokens[0])<0) continue;
            if(dev_index<0 || !valid_device(tokens[dev_index+1])) {
                if(route!='PRESENT') route='UNKNOWN';continue;
            }
            if(tokens[dev_index+1]!=device) continue;
            if(index(tokens,'linkdown')>=0 || index(tokens,'unreachable')>=0) continue;
            let via_index=index(tokens,'via');
            if(via_index>=0 && ipv4(tokens[via_index+1])==null) {
                if(route!='PRESENT') route='UNKNOWN';continue;
            }
            route='PRESENT';gateway=via_index>=0?'PRESENT':'NOT_REQUIRED';
        }
    }
}
let overlap='UNKNOWN';
if(length(wa.ranges) && length(la.ranges)) {
    if(wa.complete && la.complete) overlap='NO';
    for(let a in wa.ranges) for(let b in la.ranges)
        if(a.start<=b.end && b.start<=a.end) overlap='YES';
}
let v6=false;
if(wan && type(wan['ipv6-address'])=='array')
    for(let item in wan['ipv6-address'])
        if(type(item)=='object' && type(item.address)=='string' &&
           match(item.address,/^[a-fA-F0-9:]+$/) && index(item.address,':')>=0) v6=true;
let local_state='INCOMPLETE';
if(protocol=='OTHER') local_state='UNSUPPORTED';
else if(overlap=='YES') local_state='CONFLICT';
else if(up=='UP' && index(['dhcp','static','pppoe'],protocol)>=0 &&
        valid_device(device) && length(wa.ranges) && wa.complete &&
        route=='PRESENT' && overlap=='NO') {
    let ordinary=true;
    for(let item in wa.ranges) {
        if(index(['LINK_LOCAL','SPECIAL'],scope(item.address))>=0) ordinary=false;
        if(index(['dhcp','static'],protocol)>=0 && item.prefix<=30 &&
           (item.address==item.start || item.address==item.end)) ordinary=false;
    }
    if(ordinary) local_state='READY';
}
let report={schema_version:1,source_commit:source,protocol,
    interface_state:up,wan_device_state:valid_device(device)?'PRESENT':'UNKNOWN',
    ipv4_address_state:length(wa.ranges)?'PRESENT':wa.complete?'MISSING':'UNKNOWN',
    ipv4_address_scope:length(wa.ranges)?scope(wa.ranges[0].address):'UNKNOWN',
    ipv6_address_state:v6?'PRESENT':'UNVERIFIED',ipv4_route_state:route,
    gateway_state:gateway,subnet_overlap:overlap,ipv4_local_path_state:local_state,
    physical_link_state:'UNVERIFIED',dns_state:'UNVERIFIED',internet_state:'UNVERIFIED'};
print('HG_WAN_READINESS_V1\n'+sprintf('%J',report)+'\n');
