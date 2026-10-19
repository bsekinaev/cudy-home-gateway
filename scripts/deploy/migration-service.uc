// Read-only procd/process certification. No PID signalling or network writes.
import * as fs from 'fs';
import { snapshot_io } from './migration-snapshot.uc';
function require(ok,why) { if(!ok)die('MIGRATION_SERVICE_'+why); }
function quote(s) { return "'"+replace(s,"'","'\\''")+"'"; }
function read(path,limit) {
    let f=fs.open(path,'re');require(f!=null,'PROC_READ');let raw=f.read(limit+1),closed=f.close();
    require(closed!=null && type(raw)=='string' && length(raw)<=limit,'PROC_READ');return raw;
}
export function inspect_telegram(root,state,expected) {
    require(type(root)=='string' && type(state.assert_root)=='function' && index(['stopped','legacy','candidate','quiesce','initial'],expected)>=0,'INPUT');
    state.assert_root(root);
    let prefix='',owner=0,ubus='ubus';
    if(root!='') {
        require(match(root,/^\/[A-Za-z0-9_.\/-]+$/) && root!='/' && !match(root,/(^|\/)\.\.?($|\/)/),'ROOT');
        let st=fs.lstat(root),mark=fs.lstat(root+'/.hg-deploy-test-root');
        require(st?.type=='directory' && mark?.type=='file' && mark.uid==st.uid && mark.gid==st.gid && mark.nlink==1,'LAB');
        owner=st.uid;prefix=root;ubus=root+'/usr/bin/ubus';
    }
    function query() {
        let args=['/usr/bin/env','-i','PATH=/usr/sbin:/usr/bin:/sbin:/bin','timeout','-k','2','10',ubus,'-S','call','service','list','{"name":"home-gateway-telegram","verbose":true}'];
        let p=fs.popen(join(' ',map(args,quote))+' 2>/dev/null','r');require(p!=null,'UBUS');
        let raw=p.read(32769),rc=p.close();require(rc==0 && type(raw)=='string' && length(raw)<=32768,'UBUS');
        let all=json(raw);require(type(all)=='object','UBUS');
        let service=all['home-gateway-telegram'];
        if(service==null)return {};
        require(type(service)=='object' && (service.instances==null || type(service.instances)=='object'),'UBUS');
        require(service.triggers==null || (type(service.triggers)=='array' && length(service.triggers)==0),'SERVICE_TRIGGERS');
        return service.instances??{};
    }
    let instances=query(),names=sort(keys(instances)),wanted=expected=='stopped'?0:expected=='legacy'?1:2;
    require(expected=='quiesce'?length(names)<=2:expected=='initial'?length(names)<=1:length(names)==wanted,'INSTANCE_COUNT');
    let allowed=[prefix+'/usr/lib/home-gateway/telegram-poller.uc'];
    if(expected=='candidate' || expected=='quiesce')push(allowed,prefix+'/usr/lib/home-gateway/notifications.uc');
    let seen={},proof=[];
    for(let name in names) {
        let instance=instances[name],pid=instance?.pid,cmd=instance?.command,env=instance?.env??{};
        require(type(env)=='object','SERVICE_ENV');
        let allowed_env={HG_LIBDIR:prefix+'/usr/lib/home-gateway',HG_TELEGRAM_SECRETS_DIR:prefix+'/etc/home-gateway/secrets',
            HG_TELEGRAM_RUNTIME_DIR:prefix+'/tmp/home-gateway',HG_TELEGRAM_TOKEN_FILE:prefix+'/etc/home-gateway/secrets/telegram.token',
            HG_NOTIFICATION_STATE_DIR:prefix+'/etc/home-gateway/state',HG_NOTIFICATION_RUNTIME_DIR:prefix+'/tmp/home-gateway',
            HG_NOTIFICATION_SECRETS_DIR:prefix+'/etc/home-gateway/secrets',HG_INCIDENT_STATE_DIR:prefix+'/etc/home-gateway/state',
            HG_INCIDENT_RUNTIME_DIR:prefix+'/tmp/home-gateway'};
        require(root!='' || length(keys(env))==0,'SERVICE_ENV');
        for(let key in keys(env))require(allowed_env[key]!=null && env[key]==allowed_env[key],'SERVICE_ENV');
        let respawn=instance?.respawn;
        if(root=='' || respawn!=null)require(type(respawn)=='object' && respawn.threshold==3600 && respawn.timeout==5 && respawn.retry==5,'RESPAWN');
        require(match(name,/^[A-Za-z0-9_-]{1,64}$/) && (instance.running==true || expected=='quiesce') && type(cmd)=='array' && length(cmd)==4 &&
            cmd[0]==prefix+'/usr/bin/ucode' && index(allowed,cmd[1])>=0 && !seen[cmd[1]] && cmd[2]==prefix+'/usr/bin/gateway' && cmd[3]=='loop','COMMAND');
        seen[cmd[1]]=true;
        if(instance.running!=true) { require(pid==null || pid==0,'STOPPED_PID');push(proof,{name,running:false,command:cmd});continue; }
        require(type(pid)=='int' && pid>1 && pid<=2147483647,'PID');
        require(read('/proc/'+pid+'/cmdline',4096)==join('\u0000',cmd)+'\u0000','PID_COMMAND');
        let status=read('/proc/'+pid+'/status',8192),uid=match(status,/\nUid:\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\n/);
        require(uid!=null && +uid[1]==owner && +uid[2]==owner && +uid[3]==owner && +uid[4]==owner,'PID_UID');
        let raw=read('/proc/'+pid+'/stat',8192),end=rindex(raw,') ');
        require(end>=0,'PID_STAT');let fields=split(trim(substr(raw,end+2)),/\s+/);
        require(length(fields)>=20 && match(fields[19],/^[0-9]+$/) && fields[0]!='Z','PID_STAT');
        push(proof,{name,running:true,pid,starttime:fields[19],command:cmd,pgroup:fields[2],session:fields[3]});
    }
    let again=query();require(join(',',sort(keys(again)))==join(',',names),'SERVICE_CHANGED');
    for(let r in proof) {
        if(!r.running) {require(again[r.name]?.running!=true && sprintf('%J',again[r.name]?.command)==sprintf('%J',r.command),'SERVICE_CHANGED');continue;}
        require(again[r.name]?.running==true && again[r.name].pid==r.pid && sprintf('%J',again[r.name].command)==sprintf('%J',r.command),'SERVICE_CHANGED');
        let raw=read('/proc/'+r.pid+'/stat',8192),end=rindex(raw,') '),fields=split(trim(substr(raw,end+2)),/\s+/);
        require(end>=0 && fields[19]==r.starttime && fields[0]!='Z','PID_REUSED');
    }
    state.assert_root(root);return {format:'HG_TELEGRAM_PROCESS_PROOF_V1',expected,instances:proof};
};

// Preserve the existing CLOEXEC transport-child contract. Quiescence here
// certifies the named procd instances and their previously validated main PIDs;
// it is not a generic descendant killer. Private state is never rewound.
export function quiesce_telegram(root,state) {
    let proof=inspect_telegram(root,state,'quiesce');
    if(length(proof.instances)>0) {
        let args=['/usr/bin/env','-i','PATH=/usr/sbin:/usr/bin:/sbin:/bin','timeout','-k','2','30',root+'/etc/init.d/home-gateway-telegram','stop'];
        let p=fs.popen(join(' ',map(args,quote))+' >/dev/null 2>&1','r');require(p!=null && p.close()==0,'STOP');
    }
    for(let attempt=0;attempt<=15;attempt++) {
        state.assert_root(root);let stopped=false,alive=false;
        try {inspect_telegram(root,state,'stopped');stopped=true;}catch(e) {stopped=false;}
        for(let r in proof.instances) {
            if(!r.running)continue;
            let path='/proc/'+r.pid+'/stat',f=fs.open(path,'re');
            if(f==null) { if(fs.lstat('/proc/'+r.pid)!=null)alive=true;continue; }
            let raw=f.read(8193),closed=f.close();
            require(closed!=null && type(raw)=='string' && length(raw)<=8192,'PID_STAT');
            let end=rindex(raw,') '),fields=split(trim(substr(raw,end+2)),/\s+/);
            require(end>=0 && length(fields)>=20,'PID_STAT');
            if(fields[19]==r.starttime && fields[0]!='Z')alive=true;
        }
        if(stopped && !alive)return {format:'HG_TELEGRAM_PROCD_STOPPED_V1',instances:proof.instances};
        if(attempt<15) {let p=fs.popen('/bin/sleep 1','r');require(p!=null && p.close()==0,'WAIT');}
    }
    die('MIGRATION_SERVICE_NOT_STOPPED');
};

// Private checkpoints remain on the target's 0700 migration state. These are
// verification checkpoints, never replayed over a newer cursor/callback state.
const PRIVATE=['etc/home-gateway/secrets/telegram.token','etc/home-gateway/secrets/telegram.user_id',
    'etc/home-gateway/secrets/telegram.chat_id','tmp/home-gateway/telegram.offset','tmp/home-gateway/telegram.callback'];
function private_context(root,state,bb,label) {
    require(index(['prepare','apply','rollback'],label)>=0,'PRIVATE_LABEL');
    let io=snapshot_io(root,state,bb),name='private-'+label;
    io.checked(root+'/etc/home-gateway','directory',0700,0);io.checked(root+'/etc/home-gateway/secrets','directory',0700,0);
    return {io,base:io.BASE+'/'+name,record:io.BASE+'/'+name+'.json',name};
}
function private_inventory(c,root,records,partial) {
    let actual=[],dirs=0;
    function walk(path,prefix) {
        require(++dirs<=8,'PRIVATE_BUDGET');c.io.checked(path,'directory',0700,0);
        let names=fs.lsdir(path);require(names!=null && length(names)<=5,'PRIVATE_INVENTORY');
        for(let name in names) {
            let rel=prefix?prefix+'/'+name:name;
            require(length(filter(PRIVATE,p=>p==rel || index(p,rel+'/')==0))>0,'PRIVATE_INVENTORY');
            if(!partial)require(length(filter(keys(records),p=>records[p]!=null && (p==rel || index(p,rel+'/')==0)))>0,'PRIVATE_INVENTORY');
            if(fs.lstat(path+'/'+name)?.type=='directory')walk(path+'/'+name,rel);
            else {
                require(index(PRIVATE,rel)>=0,'PRIVATE_INVENTORY');let raw=c.io.read(path+'/'+name,0600,8192);
                if(partial && index(rel,'etc/')==0) {
                    let live=c.io.read(root+'/'+rel,0600,8192);
                    require(length(raw)<=length(live) && raw==substr(live,0,length(raw)),'PRIVATE_UNKNOWN_PENDING');
                }
                // Abandoned volatile copies are bounded opaque evidence only.
                // They are NEVER adopted, restored, deleted or used to grant
                // admission. A retry captures current live data in a fresh slot.
                push(actual,rel);
            }
        }
    }
    if(fs.lstat(c.base)!=null)walk(c.base,'');
    if(!partial)require(length(actual)==length(filter(keys(records),p=>records[p]!=null)),'PRIVATE_INVENTORY');
}
export function private_live_state(root,state,bb) {
    let c=private_context(root,state,bb,'rollback'),files={},paths=[];
    for(let rel in PRIVATE) {
        let st=fs.lstat(root+'/'+rel),secret=index(rel,'etc/')==0;
        if(st==null) {require(!secret,'PRIVATE_MISSING');files[rel]=null;continue;}
        require(st.mode==0600 || (!secret && st.mode==0644),'PRIVATE_MODE');c.io.read(root+'/'+rel,st.mode,8192);
        files[rel]={mode:st.mode};push(paths,root+'/'+rel);
    }
    let hashes=c.io.hashes(paths);for(let rel in PRIVATE)if(files[rel]!=null)files[rel].sha256=hashes[root+'/'+rel];
    return files;
};
export function verify_private_state(root,state,bb,label,after_start) {
    require(type(after_start)=='bool','PRIVATE_SCOPE');let c=private_context(root,state,bb,label),r=json(c.io.read(c.record,0600,4096));
    require(type(r)=='object' && join(',',sort(keys(r)))=='files,format,marker,storage' && r.format=='HG_PRIVATE_CHECKPOINT_V2' &&
        r.marker==c.io.read(c.io.BASE+'/marker',0600,128) && type(r.files)=='object' && join(',',sort(keys(r.files)))==join(',',sort([...PRIVATE])),'PRIVATE_RECEIPT');
    let choices=label=='rollback'?map([0,1,2,3,4,5,6,7],i=>c.name+(i?'.'+i:'')):[c.name];
    require(index(choices,r.storage)>=0,'PRIVATE_STORAGE');
    let suffix=substr(r.storage,length(c.name));c.base=c.io.BASE+'/'+r.storage;
    require(fs.lstat(c.record+'.new'+suffix)==null,'PRIVATE_PARTIAL');private_inventory(c,root,r.files,false);
    for(let rel in PRIVATE) {
        let rec=r.files[rel],secret=index(rel,'etc/')==0;
        if(rec!=null) {
            require(type(rec)=='object' && join(',',sort(keys(rec)))=='mode,sha256' && (rec.mode==0600 || (!secret && rec.mode==0644)) && match(rec.sha256,/^[0-9a-f]{64}$/),'PRIVATE_RECEIPT');
            c.io.read(c.base+'/'+rel,0600,8192);require(c.io.hashes([c.base+'/'+rel])[c.base+'/'+rel]==rec.sha256,'PRIVATE_SNAPSHOT');
        } else require(!secret,'PRIVATE_MISSING');
        if(after_start && !secret)continue;
        if(rec==null)require(fs.lstat(root+'/'+rel)==null,'PRIVATE_DRIFT');
        else {c.io.read(root+'/'+rel,rec.mode,8192);require(c.io.hashes([root+'/'+rel])[root+'/'+rel]==rec.sha256,'PRIVATE_DRIFT');}
    }
    return true;
};
export function capture_private_state(root,state,bb,label) {
    inspect_telegram(root,state,label=='prepare'?'initial':'stopped');let c=private_context(root,state,bb,label),files={},suffix='';
    require(fs.lstat(c.record)==null,'PRIVATE_NO_REPLAY');
    if(label=='rollback') {
        let selected=null,original=c.base;
        // Eight bounded attempts, preserving interrupted copies verbatim. No
        // replay of a stale offset after reboot or of a newer callback state.
        for(let i=0;i<8;i++) {
            let tail=i?'.'+i:'',path=original+tail,pending=c.record+'.new'+tail;
            if(fs.lstat(path)!=null) {private_inventory({...c,base:path},root,null,true);if(fs.lstat(pending)!=null)c.io.read(pending,0600,4096);}
            else {require(fs.lstat(pending)==null,'PRIVATE_UNKNOWN_PENDING');if(selected==null)selected=tail;}
        }
        require(selected!=null,'PRIVATE_EVIDENCE_LIMIT');suffix=selected;c.base=original+suffix;
    } else require(fs.lstat(c.record+'.new')==null && fs.lstat(c.base)==null,'PRIVATE_PARTIAL');
    let total=0;
    for(let rel in PRIVATE) {
        let path=root+'/'+rel,st=fs.lstat(path),secret=index(rel,'etc/')==0;
        if(label=='prepare' && !secret) {files[rel]=null;continue;}
        if(st==null) {require(!secret,'PRIVATE_MISSING');files[rel]=null;continue;}
        require(st.mode==0600 || (!secret && st.mode==0644),'PRIVATE_MODE');
        let raw=c.io.read(path,st.mode,8192);total+=length(raw);require(total<=32768,'PRIVATE_BUDGET');c.io.space(total);
        c.io.write(c.base+'/'+rel,raw,0600);files[rel]={mode:st.mode,sha256:c.io.hashes([c.base+'/'+rel])[c.base+'/'+rel]};
    }
    let record={format:'HG_PRIVATE_CHECKPOINT_V2',marker:c.io.read(c.io.BASE+'/marker',0600,128),storage:c.name+suffix,files},pending=c.record+'.new'+suffix;
    c.io.write(pending,sprintf('%J\n',record),0600);require(fs.rename(pending,c.record),'PRIVATE_PUBLISH');c.io.sync([c.io.BASE]);
    verify_private_state(root,state,bb,label,label=='prepare');return true;
};
