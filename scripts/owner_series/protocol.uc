// Read-only target primitives. No service, state recovery or filesystem writes.
import * as fs from 'fs';

const PATHS=['etc/init.d/home-gateway-telegram','usr/bin/gateway','usr/bin/home-gateway-ci-smoke',
    ...map(['actions.uc','asata.sh','common.sh','dns.sh','doctor.sh','health.sh','incidents.uc','network.sh',
    'notifications.uc','redmi.sh','selftest.sh','status.sh','tailscale.sh','telegram-poller.uc','telegram.sh','torrent.sh','vpn.sh'],n=>'usr/lib/home-gateway/'+n)];
const PHASES=['PENDING','EXECUTING','DONE','FAILED','UNKNOWN','EXPIRED','CANCELLED','ACKNOWLEDGED'];
const CLEAN_EXEC='/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -k 1 10 ';
const CONTROL_PINS={
    'etc/init.d/home-gateway-deploy-recover':'5b747dff42649914e4b231de2d5ade0171eedad40d5fb53f43e4d869d08a2630',
    'etc/init.d/home-gateway-migration':'76587a5b48ec1d3ff913fc8df666ad17132e500fed00f0d255528017452ecb69',
    'usr/libexec/home-gateway-deploy/engine.sh':'305d70f8778da506932e4397efbe77999e1ea787dad3633da141c6d11c225b1b',
    'usr/libexec/home-gateway-deploy/wrapper.sh':'d8694eb76c86f16dbae2599e8d68e20dfcf9d8334a488f0f407c84264099946f',
    'usr/libexec/home-gateway-deploy/migration-admission.sh':'01e67e520fe0b9333002a5ac3395c6cdb975501546b0fc6ed3631eb4f61f7bfc',
    'usr/libexec/home-gateway-deploy/migration-candidate.uc':'12c258740dd28fb53921e1ed30d610ed11812809fd548c6b883213ca606feaae',
    'usr/libexec/home-gateway-deploy/migration-controls.uc':'4a4b90cd39bdd83622598a34b54c9ca5da27d5b5739b7e0878428c47c97f4c2b',
    'usr/libexec/home-gateway-deploy/migration-coordinator.uc':'d32b234851d23c114805c836383a16d5c142d7eb9266cfccb0c03f37758dc371',
    'usr/libexec/home-gateway-deploy/migration-handoff.uc':'47a7ce0926e1a1f3718f3bb05f80046f745ebef06fd043677e46926f43f2e195',
    'usr/libexec/home-gateway-deploy/migration-runtime.uc':'9b3a145d870af8155c8c70fe19afa3d6ac3b2da4b258c1ba7fc4b9eaf2b1d589',
    'usr/libexec/home-gateway-deploy/migration-service.uc':'e0706bfcf49ddae62546f805df012d12cb0fa364dc44cad5dbe713f3ba4d748d',
    'usr/libexec/home-gateway-deploy/migration-snapshot.uc':'85a507ca9627e7f7efefe9070ee9e22f6e5d700349273b72cd1b32726788bfa7',
    'usr/libexec/home-gateway-deploy/migration-state.uc':'aaf35ec039d0ef21a7e03a9affd1c1fd3aab9be2ec5764c616e047776eff9d70',
    'usr/libexec/home-gateway-deploy/migration-terminal.uc':'760c15fe60d2e79079d55b7c8642817a29e2c1973a399095f50e5dfe7dd83c48'
};
function need(ok,why) { if(!ok)die('OWNER_SERIES_'+why); }
function quote(s) { return "'"+replace(s,"'","'\\''")+"'"; }
function same_keys(value,names) {
    return type(value)=='object' && join('\n',sort(keys(value)))==join('\n',sort([...names]));
}
function hash(value) { return type(value)=='string' && match(value,/^[0-9a-f]{64}$/)!=null; }
function same_device(a,b) { return a?.dev?.major==b?.dev?.major && a?.dev?.minor==b?.dev?.minor; }
function canonical(path) {
    return type(path)=='string' && length(path)<=512 && match(path,/^\/[A-Za-z0-9_./-]+$/)!=null &&
        index(path,'//')<0 && !match(path,/(^|\/)\.\.?($|\/)/) && substr(path,-1)!='/';
}

// json() intentionally accepts duplicate object keys. Scan the grammar first,
// comparing decoded key strings so escaped duplicates are refused as well.
function strict_json(raw,why) {
    let position=0,nodes=0;
    function whitespace() { while(position<length(raw) && match(substr(raw,position,1),/^[ \t\r\n]$/))position++; }
    function string_value() {
        let start=position++;
        while(position<length(raw)) {
            let c=substr(raw,position++,1);
            if(c=='\\')position++;
            else if(c=='"') {
                try {return json(substr(raw,start,position-start));}catch(e){need(false,why);}
            }
        }
        need(false,why);
    }
    function value(depth) {
        need(depth<=16 && ++nodes<=32768,why);whitespace();
        let c=substr(raw,position,1);
        if(c=='{') {
            position++;whitespace();let seen={};
            if(substr(raw,position,1)=='}'){position++;return;}
            while(true) {
                need(substr(raw,position,1)=='"',why);let key=string_value();
                need(!seen[key],why);seen[key]=true;whitespace();
                need(substr(raw,position++,1)==':',why);value(depth+1);whitespace();
                c=substr(raw,position++,1);if(c=='}')return;need(c==',',why);whitespace();
            }
        }
        if(c=='[') {
            position++;whitespace();if(substr(raw,position,1)==']'){position++;return;}
            while(true){value(depth+1);whitespace();c=substr(raw,position++,1);if(c==']')return;need(c==',',why);}
        }
        if(c=='"'){string_value();return;}
        let start=position;
        while(position<length(raw) && index(' \t\r\n,}]',substr(raw,position,1))<0)position++;
        need(position>start,why);
    }
    need(type(raw)=='string',why);value(0);whitespace();need(position==length(raw),why);
    try { return json(raw); }catch(e){need(false,why);}
}

export function decode_record(raw,why) { return strict_json(raw,why??'RECORD_JSON'); };

export function open_protocol(root) {
    root??='';
    need(root=='' || canonical(root),'ROOT');
    let owner=0,group=0;
    if(root!='') {
        let st=fs.lstat(root);
        need(st?.type=='directory' && st.mode==0700,'TEST_ROOT');owner=st.uid;group=st.gid;
    }
    function ancestry(path,optional) {
        need(canonical(path),'PATH');let current='';
        let parts=split(path,'/');
        for(let i=1;i<length(parts)-1;i++) {
            current+='/'+parts[i];let st=fs.lstat(current);
            if(st==null && optional)return;
            need(st?.type=='directory' && (st.uid==0 || st.uid==owner) &&
                (!(st.mode&022) || st.perm.sticky),'PARENT_METADATA');
        }
    }
    function checked(path,kind,mode,limit) {
        ancestry(path,false);let st=fs.lstat(path);
        need(st?.type==kind && st.uid==owner && st.gid==group && st.mode==mode,'METADATA');
        if(kind=='file')need(st.nlink==1,'LINK');
        if(kind=='file')need(st.size<=limit,'SIZE');
        return st;
    }
    function read(path,mode,limit) {
        let before=checked(path,'file',mode,limit),fd=fs.open(path,'re');need(fd!=null,'READ');
        let held=fs.stat('/proc/self/fd/'+fd.fileno());
        need(held?.inode==before.inode && same_device(held,before) && held.type=='file','READ_CHANGED');
        let raw=fd.read(limit+1),closed=fd.close(),after=fs.lstat(path);
        need(closed!=null && type(raw)=='string' && length(raw)==before.size &&
            after?.inode==before.inode && same_device(after,before) && after.size==before.size &&
            after.mtime==before.mtime && after.mode==before.mode,'READ_CHANGED');
        return raw;
    }
    function maybe(path,mode,limit) {
        ancestry(path,true);if(fs.lstat(path)==null)return null;return read(path,mode,limit);
    }
    function digest(path,mode,limit) {
        let before=checked(path,'file',mode,limit);
        let process=fs.popen(CLEAN_EXEC+'sha256sum '+quote(path)+' 2>/dev/null','r');need(process!=null,'HASH_PROCESS');
        let raw=process.read(1025),rc=process.close(),after=fs.lstat(path);
        need(rc==0 && type(raw)=='string' && length(raw)<=1024 &&
            after?.inode==before.inode && same_device(after,before) && after.size==before.size &&
            after.mtime==before.mtime && after.mode==before.mode,'HASH_CHANGED');
        let match_hash=match(raw,/^([0-9a-f]{64})  /);
        need(match_hash!=null && raw==match_hash[1]+'  '+path+'\n','HASH_OUTPUT');return match_hash[1];
    }
    function probe(path,limit) {
        ancestry(path,false);let before=fs.lstat(path);
        need(before?.type=='file' && before.uid==owner && before.gid==group &&
            before.nlink==1 && index([0444,0644],before.mode)>=0,'PROBE_METADATA');
        let fd=fs.open(path,'re');need(fd!=null,'PROBE_READ');
        let held=fs.stat('/proc/self/fd/'+fd.fileno()),raw=fd.read(limit+1),closed=fd.close(),after=fs.lstat(path);
        need(held?.inode==before.inode && same_device(held,before) && closed!=null &&
            after?.inode==before.inode && same_device(after,before) &&
            type(raw)=='string' && length(raw)<=limit,'PROBE_CHANGED');return raw;
    }
    function capture(command,limit) {
        let process=fs.popen(CLEAN_EXEC+command,'r');need(process!=null,'PROBE_PROCESS');
        let raw=process.read(limit+1),rc=process.close();
        need(rc==0 && type(raw)=='string' && length(raw)<=limit,'PROBE_PROCESS');return raw;
    }
    if(root!='')need(read(root+'/.hg-owner-series-test-root',0600,64)=='HG_OWNER_SERIES_TEST_ROOT_V1\n','TEST_MARKER');
    function platform(profile) {
        need(index(['VM_ONLY','OWNER_MANUAL'],profile)>=0,'PROFILE');
        need(trim(probe(root+'/proc/1/comm',64))=='procd','PROCD');
        let release=probe(root+'/etc/openwrt_release',4096);
        need(match('\n'+release,/\nDISTRIB_RELEASE='25\.12\.5'\n/),'OPENWRT');
        let boot=trim(probe(root+'/proc/sys/kernel/random/boot_id',64));
        need(match(boot,/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),'BOOT_ID');
        let description;
        if(root!='') {
            description=strict_json(read(root+'/.hg-owner-series-test-platform.json',0600,8192),'TEST_PLATFORM');
            need(same_keys(description,['architecture','busybox_version','board']),'TEST_PLATFORM');
        } else {
            description={architecture:trim(capture('uname -m',64)),
                busybox_version:capture('busybox ash --help 2>&1',4096),board:null};
            if(profile=='OWNER_MANUAL')description.board=strict_json(capture('ubus -S call system board',8192),'BOARD');
        }
        need(type(description.architecture)=='string' && type(description.busybox_version)=='string','PLATFORM');
        need(match(description.busybox_version,/BusyBox v1\.37\.0([^0-9.]|$)/),'BUSYBOX');
        let memory=probe(root+'/proc/meminfo',8192);
        let total=match('\n'+memory,/\nMemTotal:[ \t]+([0-9]+) kB\n/),available=match('\n'+memory,/\nMemAvailable:[ \t]+([0-9]+) kB\n/);
        need(total!=null && available!=null && +total[1]>=65536 && +available[1]>=65536 &&
            +available[1]<=+total[1],'MEMORY');
        if(profile=='VM_ONLY') {
            need(description.architecture=='x86_64','VM_ONLY');
            need(read(root+'/etc/hg-disposable-vm',0600,64)=='HG_NETWORKLESS_OPENWRT_VM_V1\n','VM_ONLY');
        } else {
            let board=description.board;
            need(description.architecture=='aarch64' && type(board)=='object' && type(board.model)=='string' &&
                match(board.model,/^Cudy TR3000( 256MB)? v1$/) && type(board.release)=='object' &&
                board.release.target=='mediatek/filogic' && +total[1]>=450000 && +total[1]<=524288,'OWNER_HARDWARE');
        }
        return {status:'VERIFIED',scope:root==''?'TARGET':'TEST_FS_ONLY',profile,boot_id:boot,
            total_kib:+total[1],available_kib:+available[1]};
    }
    function package(input) {
        need(same_keys(input,['kit','manifest_sha256']) && canonical(input.kit) && hash(input.manifest_sha256),'PACKAGE_ARGUMENTS');
        let kit=root+input.kit;checked(kit,'directory',0700,0);
        need(digest(kit+'/manifest.json',0600,65536)==input.manifest_sha256,'PACKAGE_MANIFEST_PIN');
        let m=strict_json(read(kit+'/manifest.json',0600,65536),'PACKAGE_JSON');
        need(same_keys(m,['format','profile','production_apply','source_commit','baseline_commit','source_fixture',
            'parent','bootstrap','inventories','changed','controls','files']) && m.format=='HG_OWNER_UPDATE_V2' &&
            type(m.source_commit)=='string' && match(m.source_commit,/^[0-9a-f]{40}$/) &&
            type(m.baseline_commit)=='string' && match(m.baseline_commit,/^[0-9a-f]{40}$/) &&
            type(m.source_fixture)=='bool','PACKAGE_FORMAT');
        let owner=m.profile=='OWNER_MANUAL' && m.production_apply==true && m.source_fixture==false;
        need(owner || (m.profile=='VM_ONLY' && m.production_apply==false),'PACKAGE_PROFILE');
        let expected={'protocol.uc':0600,'state.uc':0600,'engine.uc':0600,'watch.uc':0600,'boot.init':0755,'owner.ps1':0600,
            'baseline.sha256':0600,'candidate.sha256':0600,'parent.json':0600,'bootstrap.tar.gz':0600};
        if(owner)expected['acceptance.json']=0600;
        need(same_keys(m.inventories,['baseline','candidate']),'PACKAGE_INVENTORY');
        for(let name in ['baseline','candidate']) {
            need(same_keys(m.inventories[name],PATHS),'PACKAGE_INVENTORY');
            for(let path in PATHS) {
                need(hash(m.inventories[name][path]),'PACKAGE_INVENTORY');
                expected[name+'/'+path]=index(PATHS,path)<3?0755:0644;
            }
        }
        need(type(m.files)=='array' && length(m.files)==length(keys(expected)),'PACKAGE_INVENTORY');
        let seen={};
        for(let f in m.files) {
            need(same_keys(f,['path','mode','size','sha256']) && type(f.path)=='string' && expected[f.path]!=null &&
                !seen[f.path] && type(f.mode)=='int' && f.mode==expected[f.path] && type(f.size)=='int' &&
                f.size>=0 && f.size<=262144 && hash(f.sha256),'PACKAGE_INVENTORY');seen[f.path]=true;
            let st=checked(kit+'/'+f.path,'file',f.mode,262144);
            need(st.size==f.size && digest(kit+'/'+f.path,f.mode,262144)==f.sha256,'PACKAGE_FILE_PIN');
        }
        function walk(path,prefix) {
            checked(path,'directory',0700,0);let names=fs.lsdir(path);need(names!=null && length(names)<=64,'PACKAGE_DIRECTORY');
            for(let name in names) {
                let rel=prefix?prefix+'/'+name:name;
                need(rel=='manifest.json' || expected[rel]!=null || length(filter(keys(expected),n=>index(n,rel+'/')==0))>0,'PACKAGE_UNKNOWN');
                if(fs.lstat(path+'/'+name)?.type=='directory')walk(path+'/'+name,rel);
                else need(rel=='manifest.json' || seen[rel],'PACKAGE_UNKNOWN');
            }
        }
        walk(kit,'');
        let changed=[];
        for(let path in PATHS) {
            if(m.inventories.baseline[path]!=m.inventories.candidate[path])push(changed,path);
            for(let name in ['baseline','candidate'])need(digest(kit+'/'+name+'/'+path,expected[name+'/'+path],262144)==m.inventories[name][path],'PACKAGE_RUNTIME_PIN');
        }
        let allowed=map(['telegram-poller.uc','dns.sh','health.sh','redmi.sh','status.sh'],n=>'usr/lib/home-gateway/'+n);
        need(type(m.changed)=='array' && length(changed)>0 && join('\n',m.changed)==join('\n',changed) &&
            length(filter(changed,p=>index(allowed,p)>=0))==length(changed),'PACKAGE_DELTA');
        for(let name in ['baseline','candidate']) {
            let sums=join('',map(PATHS,p=>m.inventories[name][p]+'  '+p+'\n'));
            need(read(kit+'/'+name+'.sha256',0600,8192)==sums,'PACKAGE_SUMS');
        }
        need(same_keys(m.controls,keys(CONTROL_PINS)),'PACKAGE_CONTROLS');
        for(let path in keys(CONTROL_PINS))need(m.controls[path]==CONTROL_PINS[path],'PACKAGE_CONTROLS');
        need(same_keys(m.bootstrap,['archive_sha256','manifest_sha256']) && hash(m.bootstrap.archive_sha256) &&
            hash(m.bootstrap.manifest_sha256) && digest(kit+'/bootstrap.tar.gz',0600,262144)==m.bootstrap.archive_sha256,'PACKAGE_BOOTSTRAP');
        let previous=strict_json(read(kit+'/parent.json',0600,65536),'PACKAGE_PARENT');
        need(same_keys(m.parent,['format','source_commit','manifest_sha256','archive_sha256']) &&
            hash(m.parent.archive_sha256) && hash(m.parent.manifest_sha256) &&
            digest(kit+'/parent.json',0600,65536)==m.parent.manifest_sha256 && type(previous)=='object' &&
            m.parent.source_commit==m.baseline_commit && previous.source_commit==m.baseline_commit &&
            m.parent.format==previous.format && index(['HG_OWNER_UPDATE_V1','HG_OWNER_UPDATE_V2'],previous.format)>=0 &&
            same_keys(previous.inventories?.candidate,PATHS) && same_keys(previous.controls,keys(CONTROL_PINS)),'PACKAGE_PARENT');
        for(let path in PATHS)need(previous.inventories.candidate[path]==m.inventories.baseline[path],'PACKAGE_PARENT');
        for(let path in keys(CONTROL_PINS))need(previous.controls[path]==CONTROL_PINS[path],'PACKAGE_PARENT');
        if(previous.format=='HG_OWNER_UPDATE_V1') {
            need(m.baseline_commit=='d2039b6c62da3aa458f720af1c46fb619aee48dd' &&
                m.parent.archive_sha256==m.bootstrap.archive_sha256 && m.parent.manifest_sha256==m.bootstrap.manifest_sha256,'PACKAGE_PARENT');
            if(owner)need(m.bootstrap.archive_sha256=='a39fb710909661d6c03c4f2f73f3b7645017b14a07999c80666de6735b926eed' &&
                m.bootstrap.manifest_sha256=='430383e3b0bfff46fbee688068cfea4e1446ca4491d6ded83d67ef1179e6b0df','PACKAGE_OWNER_BOOTSTRAP');
        } else {
            need(previous.profile==m.profile && previous.production_apply==m.production_apply &&
                (!previous.source_fixture || m.source_fixture) &&
                same_keys(previous.bootstrap,['archive_sha256','manifest_sha256']) &&
                previous.bootstrap.archive_sha256==m.bootstrap.archive_sha256 &&
                previous.bootstrap.manifest_sha256==m.bootstrap.manifest_sha256,'PACKAGE_PARENT');
        }
        if(owner) {
            need(m.bootstrap.archive_sha256=='a39fb710909661d6c03c4f2f73f3b7645017b14a07999c80666de6735b926eed','PACKAGE_OWNER_BOOTSTRAP');
            let approval=strict_json(read(kit+'/acceptance.json',0600,262144),'PACKAGE_APPROVAL');
            need(approval.format=='HG_OWNER_SERIES_ACCEPTANCE_V1' && approval.commit==m.source_commit &&
                approval.ci_head==m.source_commit && approval.ci_conclusion=='success' &&
                approval.review_head==m.source_commit && type(approval.review_blockers)=='int' && approval.review_blockers==0 &&
                approval.report?.commit==m.source_commit && approval.report.scenario=='owner-series' &&
                approval.report.status=='PASS' && approval.report.failed==0,'PACKAGE_APPROVAL');
        }
        return m;
    }
    function runtime(inventory) {
        need(same_keys(inventory,PATHS) && length(filter(values(inventory),hash))==20,'RUNTIME_INVENTORY');
        for(let path in PATHS) {
            let mode=index(PATHS,path)<3?0755:0644;
            need(digest(root+'/'+path,mode,262144)==inventory[path],'LIVE_DRIFT');
        }
        let library=fs.lsdir(root+'/usr/lib/home-gateway');
        need(library!=null && length(library)==17 && length(filter(library,n=>index(PATHS,'usr/lib/home-gateway/'+n)>=0))==17,'UNKNOWN_RUNTIME');
        return {files:20,status:'VERIFIED'};
    }
    function controls(inventory) {
        need(same_keys(inventory,keys(CONTROL_PINS)),'CONTROL_INVENTORY');
        for(let path in keys(CONTROL_PINS))need(inventory[path]==CONTROL_PINS[path],'CONTROL_INVENTORY');
        for(let path in keys(CONTROL_PINS)) {
            let mode=index(path,'etc/init.d/')==0?0755:substr(path,-3)=='.uc'?0600:0700;
            need(digest(root+'/'+path,mode,262144)==CONTROL_PINS[path],'CONTROL_DRIFT');
        }
        return {files:14,status:'VERIFIED'};
    }
    function inspect_actions() {
        for(let name in ['HG_ACTION_POLICY_FILE','HG_ACTION_STATE_DIR','HG_ACTION_RUNTIME_DIR',
                         'HG_ACTION_SECRETS_DIR','HG_ACTION_INIT_DIR'])
            need(getenv(name)==null || getenv(name)=='','ACTION_ENVIRONMENT');
        let policy=root+'/etc/home-gateway/actions.enabled',state=root+'/etc/home-gateway/state/actions.json';
        need(fs.lstat(policy+'.new')==null && fs.lstat(state+'.new')==null,'ACTION_PENDING');
        let raw=maybe(policy,0600,16);
        if(raw!=null)need(index(['','0','0\n','1','1\n'],raw)>=0,'ACTION_POLICY');
        need(getenv('HG_ACTION_EXECUTION_ENABLED')!='1' && raw!='1' && raw!='1\n','ACTIONS_ENABLED');
        let directory=fs.lstat(root+'/etc/home-gateway/state');
        if(directory!=null)checked(root+'/etc/home-gateway/state','directory',0700,0);
        raw=maybe(state,0600,131072);if(raw==null)return {records:0,status:'DISABLED'};
        let data=strict_json(raw,'ACTION_STATE');
        need(type(data)=='object' && type(data.schema_version)=='int' && data.schema_version==1 &&
            type(data.records)=='array' && length(data.records)<=128,'ACTION_STATE');
        let tokens={};
        for(let record in data.records) {
            need(type(record)=='object' && index(['restart-tailscale','restart-uhttpd'],record.action)>=0 &&
                index(PHASES,record.phase)>=0 && type(record.token)=='string' &&
                match(record.token,/^[0-9a-f]{32}$/) && !tokens[record.token] &&
                type(record.user)=='string' && match(record.user,/^[1-9][0-9]{0,18}$/) &&
                type(record.chat)=='string' && match(record.chat,/^-?[1-9][0-9]{0,18}$/) &&
                type(record.message)=='string' && match(record.message,/^[1-9][0-9]{0,18}$/) &&
                type(record.created)=='int' && type(record.expires)=='int' && record.expires==record.created+120 &&
                type(record.boot)=='string' && match(record.boot,/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) &&
                type(record.started)=='int' && type(record.finished)=='int' && type(record.maintenance_until)=='int','ACTION_STATE');
            tokens[record.token]=true;
            need(index(['EXECUTING','UNKNOWN'],record.phase)<0,'ACTION_UNRESOLVED');
        }
        return {records:length(data.records),status:'DISABLED'};
    }
    function actions(borrowed) {
        need(borrowed==null || type(borrowed)=='resource','ACTION_LOCK_RESOURCE');
        let path=root+'/tmp/home-gateway/actions.lock',guard=borrowed,owned=borrowed==null;
        ancestry(path,true);
        if(!owned)need(fs.lstat(path)!=null,'ACTION_LOCK');
        if(fs.lstat(path)!=null) {
            let before=checked(path,'file',0600,0);
            if(owned)guard=fs.open(path,'re');need(guard!=null,'ACTION_LOCK');
            let held=fs.stat('/proc/self/fd/'+guard.fileno()),after=fs.lstat(path);
            need(held?.inode==before.inode && same_device(held,before) &&
                after?.inode==before.inode && same_device(after,before),'ACTION_LOCK_CHANGED');
            need(guard.lock('xn')!=null,'ACTIONS_BUSY');
        }
        // Absent lock is not created by preflight. The future writer must acquire
        // or create it and recheck this state before preparing any transaction.
        let result;
        try {result=inspect_actions();}catch(e){if(owned && guard!=null)guard.close();die(e);}
        if(owned && guard!=null)need(guard.close()!=null,'ACTION_LOCK_CLOSE');return result;
    }
    function history(roots) {
        need(type(roots)=='array' && length(roots)>0 && length(roots)<=66,'HISTORY_ROOT');
        let allowed=/^\/etc\/(home-gateway-migration|home-gateway-owner-update|home-gateway-deploy\/tx\.[a-zA-Z0-9]{1,32}|home-gateway-owner-series\/generations\/tx\.[0-9a-f]{32})$/;
        let unique={};
        for(let path in roots) {
            need(canonical(path) && match(path,allowed) && !unique[path],'HISTORY_ROOT');unique[path]=true;
        }
        let entries=[],count=0,jobs=[];
        function walk(path,depth) {
            need(depth<=20 && length(entries)<4096,'HISTORY_LIMIT');
            let full=root+path;ancestry(full,false);let st=fs.lstat(full);
            need(st!=null && st.uid==owner && st.gid==group,'HISTORY_METADATA');
            if(st.type=='directory') {
                checked(full,'directory',0700,0);push(entries,{path,type:'directory',mode:0700});
                let names=fs.lsdir(full);need(names!=null && length(names)<=128,'HISTORY_LIMIT');
                for(let name in sort(names)) {
                    need(match(name,/^[A-Za-z0-9_.-]+$/) && name!='.' && name!='..','HISTORY_PATH');walk(path+'/'+name,depth+1);
                }
            } else {
                need(st.type=='file' && index([0600,0644,0700,0755],st.mode)>=0,'HISTORY_METADATA');
                let inventory=match(path,/^\/etc\/home-gateway-owner-series\/generations\/tx\.[0-9a-f]{32}\/history\.json$/)!=null;
                if(inventory)need(st.mode==0600,'HISTORY_METADATA');
                checked(full,'file',st.mode,inventory?2097152:262144);
                push(entries,{path,type:'file',mode:st.mode,size:st.size,sha256:null});
                push(jobs,{full,stat:st,index:length(entries)-1,limit:inventory?2097152:262144});count++;
            }
        }
        for(let path in sort([...roots]))walk(path,0);
        // Bounded path-only batches avoid both an ARG_MAX-sized evidence string
        // and thousands of process launches for retained immutable receipts.
        for(let start=0;start<length(jobs);start+=64) {
            let batch=slice(jobs,start,start+64);
            let command=CLEAN_EXEC+'sha256sum '+join(' ',map(batch,j=>quote(j.full)))+' 2>/dev/null';
            need(length(command)<40000,'HISTORY_LIMIT');let child=fs.popen(command,'r');need(child!=null,'HASH_PROCESS');
            let raw=child.read(65537),rc=child.close();need(rc==0 && type(raw)=='string' && length(raw)<=65536,'HASH_OUTPUT');
            let lines=split(raw,'\n');need(pop(lines)=='' && length(lines)==length(batch),'HASH_OUTPUT');
            for(let i=0;i<length(batch);i++) {
                let job=batch[i],pin=substr(lines[i],0,64),after=checked(job.full,'file',job.stat.mode,job.limit);
                need(hash(pin) && lines[i]==pin+'  '+job.full && after.inode==job.stat.inode && same_device(after,job.stat) &&
                    after.size==job.stat.size && after.mtime==job.stat.mtime,'HASH_CHANGED');entries[job.index].sha256=pin;
            }
        }
        let result={schema_version:1,roots:sort([...roots]),entries,files:count};
        need(length(sprintf('%J',result))<=2097152,'HISTORY_LIMIT');return result;
    }
    function verify_history(evidence) {
        need(same_keys(evidence,['schema_version','roots','entries','files']) &&
            type(evidence.schema_version)=='int' && evidence.schema_version==1 && type(evidence.files)=='int' &&
            type(evidence.entries)=='array' && length(evidence.entries)<=4096,'HISTORY_FORMAT');
        let actual=history(evidence.roots);
        need(length(actual.entries)==length(evidence.entries) && actual.files==evidence.files,'HISTORY_DRIFT');
        for(let i=0;i<length(actual.entries);i++) {
            let entry=evidence.entries[i],expected=actual.entries[i];
            need(type(entry)=='object' && same_keys(entry,keys(expected)),'HISTORY_FORMAT');
            for(let name in keys(expected))need(type(entry[name])==type(expected[name]) && entry[name]==expected[name],'HISTORY_DRIFT');
        }
        return {files:actual.files,status:'VERIFIED'};
    }
    return {platform,package,runtime,controls,actions,history,verify_history};
};
