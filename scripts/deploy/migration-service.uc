// Read-only procd/process certification. No PID signalling or network writes.
import * as fs from 'fs';
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
        return service.instances??{};
    }
    let instances=query(),names=sort(keys(instances)),wanted=expected=='stopped'?0:expected=='legacy'?1:2;
    require(expected=='quiesce'?length(names)<=2:expected=='initial'?length(names)<=1:length(names)==wanted,'INSTANCE_COUNT');
    let allowed=[prefix+'/usr/lib/home-gateway/telegram-poller.uc'];
    if(expected=='candidate' || expected=='quiesce')push(allowed,prefix+'/usr/lib/home-gateway/notifications.uc');
    let seen={},proof=[];
    for(let name in names) {
        let instance=instances[name],pid=instance?.pid,cmd=instance?.command;
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
