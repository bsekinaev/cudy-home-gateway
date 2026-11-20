// Owner-controlled coordinator. No automatic installation or recovery at boot.
'use strict';
import * as fs from 'fs';
import { open_protocol, decode_record, runtime_mode } from './protocol.uc';
import { open_io, describe_operation, validate_operation_intent, valid_process_prefix } from './state.uc';
const SERIES='/etc/home-gateway-owner-series',D='/etc/home-gateway-deploy',LOCK='/tmp/home-gateway-deploy.lock';
const ACCEPTED='d2039b6c62da3aa458f720af1c46fb619aee48dd';
const V1TX='tx.u'+substr(ACCEPTED,0,24);
const STAGES=['preflight','apply','verify','rollback','recover'];
function need(ok,why){if(!ok)die('OWNER_SERIES_ENGINE_'+why);}
function quote(s){return "'"+replace(s,"'","'\\''")+"'";}
function opid(id){return type(id)=='string' && match(id,/^tx\.[0-9a-f]{32}$/)!=null;}
function txid(id){return type(id)=='string' && match(id,/^tx\.[A-Za-z0-9]{1,32}$/)!=null;}
function sha(value){return type(value)=='string' && match(value,/^[0-9a-f]{64}$/)!=null;}
function commit(value){return type(value)=='string' && match(value,/^[0-9a-f]{40}$/)!=null;}
function encode(value){return sprintf('%J\n',value);}

need(length(ARGV)==4 && index(STAGES,ARGV[0])>=0 && sha(ARGV[2]) && opid(ARGV[3]),'ARGUMENTS');
let stage=ARGV[0],kit=ARGV[1],pin=ARGV[2],id=ARGV[3],io=open_io(''),protocol=open_protocol('');
let m=protocol.package({kit,manifest_sha256:pin});
protocol.platform(m.profile);protocol.controls(m.controls);
const J=SERIES+'/generations/'+id;
let serial=null,actions=null,startup=null,lease=null,guardian=null,started=false,intent=null,milestone='initial';
function capture(args,limit) {
    let process=fs.popen('/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -k 2 90 '+
        join(' ',map(args,quote))+' 2>&1','r');need(process!=null,'PROCESS');
    let raw=process.read(limit+1),code=process.close();need(type(raw)=='string' && length(raw)<=limit,'OUTPUT_LIMIT');
    return {code,raw};
}
function command(args){let r=capture(args,262144);if(r.raw)print(r.raw);need(r.code==0,'COMMAND');return r.raw;}
function read_json(path,limit){return decode_record(io.read(path,0600,limit),'JOURNAL_JSON');}
function line(path,limit){let raw=io.read(path,0600,limit),value=trim(raw);need(raw==value+'\n','RECORD_BYTES');return value;}
function hook(point) {
    milestone=point;print('OWNER_SERIES_STEP='+point+'\n');fs.stdout.flush();
    if(m.profile=='VM_ONLY' && getenv('HG_SERIES_VM_KILL_AT')==point) {
        need(io.run(['/bin/sync']),'VM_SYNC');
        let pid=match(fs.readfile('/proc/self/stat')??'',/^([0-9]+) /);need(pid!=null,'SELF');
        io.run(['/bin/kill','-KILL',pid[1]]);die('VM_KILL_FAILED');
    }
}
function workers(expected) {
    let code='import { inspect_telegram } from "/usr/libexec/home-gateway-deploy/migration-service.uc";'+
        'inspect_telegram("",{assert_root:function(r){if(r!="")die("ROOT");}},'+sprintf('%J',expected)+');';
    command(['/usr/bin/ucode','-e',code]);
}
function quiesce() {
    command(['/usr/bin/ucode','-e','import { quiesce_telegram } from "/usr/libexec/home-gateway-deploy/migration-service.uc";'+
        'quiesce_telegram("",{assert_root:function(r){if(r!="")die("ROOT");}});']);
}
function checks() {
    let result=command(['/usr/bin/gateway','selftest']);
    if(m.profile=='OWNER_MANUAL' || getenv('HG_SERIES_VM_REQUIRE_DOCTOR')=='1')result+=command(['/usr/bin/gateway','doctor']);
    else result+='OWNER_SERIES_DOCTOR=NOT_TESTED_VM\n';
    return result;
}
function boot_links() {
    for(let pair in [['S94home-gateway-deploy-recover','home-gateway-deploy-recover'],['S95home-gateway-telegram','home-gateway-telegram']])
        need(io.check('/etc/rc.d/'+pair[0],'link',0777,0) && fs.readlink('/etc/rc.d/'+pair[0])=='../init.d/'+pair[1],'BOOT_LINK');
}
function anchor() {
    let destination=fs.mkdtemp('/tmp/home-gateway-series-anchor.XXXXXX');need(destination!=null,'ANCHOR_DIRECTORY');
    need(io.run(['tar','-xzpf',kit+'/bootstrap.tar.gz','-C',destination]),'ANCHOR_EXTRACT');
    need(io.hash(destination+'/manifest.json',0600,65536)==m.bootstrap.manifest_sha256,'ANCHOR_PIN');
    command(['/usr/bin/ucode',destination+'/inspect.uc',destination,m.bootstrap.manifest_sha256,'journal']);
    need(line('/etc/home-gateway-owner-update/phase',32)=='COMMITTED' &&
        line('/etc/home-gateway-owner-update/new-id',40)==V1TX,'V1_IDENTITY');
    function remove_scratch(path) {
        let st=fs.lstat(path);need(st!=null && st.uid==0 && st.gid==0,'ANCHOR_CLEANUP');
        if(st.type=='directory') {for(let name in fs.lsdir(path))remove_scratch(path+'/'+name);need(fs.rmdir(path),'ANCHOR_CLEANUP');}
        else {need(st.type=='file' && st.nlink==1,'ANCHOR_CLEANUP');need(fs.unlink(path),'ANCHOR_CLEANUP');}
    }
    remove_scratch(destination);
}
function marker() {
    if(!io.exists(SERIES))return false;
    io.check(SERIES,'directory',0700,0);need(io.read(SERIES+'/marker',0600,32)=='HG_OWNER_SERIES_V2\n','ROOT_MARKER');
    io.check(SERIES+'/generations','directory',0700,0);return true;
}
function generation_names() {
    if(!marker())return [];
    let names=fs.lsdir(SERIES+'/generations');need(names!=null && length(names)<=32,'GENERATION_LIMIT');
    for(let name in names)need(opid(name),'GENERATION_INVENTORY');return sort(names);
}
function self_contents(directory) {
    let evidence=protocol.history([directory]);
    evidence.entries=filter(evidence.entries,e=>index(['contents.json','contents.json.new','sealed','sealed.new','phase.new','postflight.log.new'],substr(e.path,length(directory)+1))<0);
    evidence.files=length(filter(evidence.entries,e=>e.type=='file'));return evidence;
}
function journal_layout(directory,kind,format) {
    io.check(directory,'directory',0700,0);
    let limits={'intent.json':8192,'manifest.json':65536,'kit-pin':65,phase:32,'phase.new':32,
        'history.json':2097152,'history.json.new':2097152,'contents.json':2097152,'contents.json.new':2097152,'sealed':64,'sealed.new':64,
        'transaction.json':2097152,'transaction.json.new':2097152,'preflight.log':262144,'postflight.log':262144,
        'postflight.log.new':262144,'service.log':262144};
    let names=fs.lsdir(directory);need(names!=null && length(names)<=128,'JOURNAL_LIMIT');
    for(let name in names) {
        if(name=='before-runtime'||name=='aborted-transaction') {
            need(name=='before-runtime'?kind=='ROLLBACK':kind=='APPLY','JOURNAL_UNKNOWN');io.check(directory+'/'+name,'directory',0700,0);continue;
        }
        if(match(name,/^interrupted\.[0-9]{1,2}$/)){io.check(directory+'/'+name,'file',0600,2097152);continue;}
        if(match(name,/^interrupted-runtime\.[0-9]{1,2}$/)){
            let mode=fs.lstat(directory+'/'+name)?.mode;
            need(mode==0644 || (format=='HG_OWNER_MONITOR_V3' && mode==0755),'JOURNAL_INTERRUPTED_MODE');
            io.check(directory+'/'+name,'file',mode,262144);continue;
        }
        need(limits[name]!=null,'JOURNAL_UNKNOWN');io.check(directory+'/'+name,'file',0600,limits[name]);
    }
}
function receipt(operation,shallow) {
    need(opid(operation),'RECEIPT_ID');let path=SERIES+'/generations/'+operation;
    io.check(path,'directory',0700,0);
    need(io.read(path+'/sealed',0600,64)=='HG_OWNER_SERIES_SEALED_V1\n','UNSEALED');
    for(let name in ['phase.new','postflight.log.new','contents.json.new','sealed.new'])need(!io.exists(path+'/'+name),'SEALED_PENDING');
    let data=read_json(path+'/intent.json',8192),manifest=read_json(path+'/manifest.json',65536),phase=line(path+'/phase',32);
    validate_operation_intent(data,manifest,data.kit_pin);
    journal_layout(path,data.kind,manifest.format);
    need(data.format=='HG_OWNER_SERIES_OPERATION_V1' && data.id==operation && sha(data.kit_pin) &&
        io.hash(path+'/manifest.json',0600,65536)==data.kit_pin && line(path+'/kit-pin',65)==data.kit_pin &&
        manifest.source_commit==data.source_commit && manifest.baseline_commit==data.baseline_commit &&
        index(['COMMITTED','ROLLED_BACK','ABORTED'],phase)>=0,'RECEIPT_IDENTITY');
    need(encode(read_json(path+'/contents.json',2097152))==encode(self_contents(path)),'RECEIPT_DRIFT');
    if(!shallow) {
        let evidence=read_json(path+'/history.json',2097152);
        protocol.verify_history(evidence);
        let captured=map(filter(evidence.roots,p=>index(p,SERIES+'/generations/')==0),p=>substr(p,length(SERIES+'/generations/')));
        push(captured,operation);
        let actual=filter(generation_names(),name=>name!=id || name==operation || io.exists(SERIES+'/generations/'+name+'/sealed'));
        need(join('\n',sort(captured))==join('\n',sort(actual)),'HISTORY_GENERATIONS');
        if(io.exists(path+'/transaction.json'))protocol.verify_history(read_json(path+'/transaction.json',2097152));
    }
    return {intent:data,manifest,phase};
}
function effective(record) {
    let prefix=record.phase=='COMMITTED'?'after_':'before_';
    return {generation:record.intent[prefix+'generation'],transaction:record.intent[prefix+'transaction'],source:record.intent[prefix+'source']};
}
function selection() {
    let selected={generation:'V1',transaction:V1TX,source:ACCEPTED,latest:'V1'};
    if(marker() && io.exists(SERIES+'/latest')) {
        let latest=line(SERIES+'/latest',36),last=receipt(latest),value=effective(last);
        selected={...value,latest};
        if(value.generation=='V1')need(!io.exists(SERIES+'/current'),'CURRENT_POINTER');
        else need(line(SERIES+'/current',36)==value.generation,'CURRENT_POINTER');
    } else if(marker())need(!io.exists(SERIES+'/current'),'CURRENT_POINTER');
    need(txid(selected.transaction) && commit(selected.source) &&
        line(D+'/latest',40)==selected.transaction && line(D+'/'+selected.transaction+'/phase',32)=='COMMITTED' &&
        line(D+'/'+selected.transaction+'/commit',41)==selected.source,'RAW_PARENT');
    if(selected.generation!='V1') {
        let current=receipt(selected.generation,selected.generation!=selected.latest);
        need(current.intent.kind=='APPLY' && current.phase=='COMMITTED' && current.intent.id==selected.transaction &&
            current.manifest.source_commit==selected.source,'CURRENT_RECEIPT');
        selected.parent_generation=current.intent.before_generation;
        selected.parent_transaction=current.intent.before_transaction;
    }
    return selected;
}
function parent_match(selected,kind) {
    need(selected.source==(kind=='APPLY'?m.baseline_commit:m.source_commit),'PARENT_SOURCE');
    let expected=kind=='APPLY'?m.parent.manifest_sha256:pin;
    if(selected.generation=='V1')need(kind=='APPLY' && expected==m.bootstrap.manifest_sha256,'PARENT_MANIFEST');
    else need(io.hash(SERIES+'/generations/'+selected.generation+'/manifest.json',0600,65536)==expected,'PARENT_MANIFEST');
}
function space() {
    let bytes=0;for(let file in m.files)bytes+=file.size;
    let free=capture(['df','-Pk','/etc'],4096);need(free.code==0,'SPACE');
    let rows=filter(split(trim(free.raw),'\n'),s=>length(s)>0),columns=split(trim(rows[length(rows)-1]??''),/\s+/);
    need(length(columns)>=6 && match(columns[3],/^[0-9]+$/) && +columns[3]*1024>=bytes*3+8388608,'PERSISTENT_SPACE');
    let platform=protocol.platform(m.profile);need(platform.available_kib*1024>=bytes*3+67108864,'RAM_SPACE');
}
function no_pending_global() {
    for(let path in [D+'/active',D+'/latest',SERIES+'/active',SERIES+'/current',SERIES+'/latest'])
        need(!io.exists(path+'.new'),'GLOBAL_PENDING');
}
function preflight(kind,held) {
    if(kind=='APPLY' && m.format=='HG_OWNER_MONITOR_V3') {
        let prerequisite=capture(['/bin/sh','-c','command -v setsid >/dev/null 2>&1 && setsid /bin/sh -c '+quote('exit 0')],1024);
        need(prerequisite.code==0,'MONITOR_SETSID_REQUIRED');
    }
    no_pending_global();
    for(let name in fs.lsdir('/etc'))need(index(name,'home-gateway-owner-series.preparing-')!=0,'FOREIGN_PREPARATION');
    need(!io.exists(SERIES+'/active') && !io.exists(SERIES+'/active.new') && !io.exists(D+'/active') &&
        !io.exists(D+'/active.new') && !io.exists(D+'/latest.new') && !io.exists(LOCK),'ACTIVE_OR_FOREIGN');
    let names=generation_names();need(length(names)<32 && index(names,id)<0,'REPLAY_OR_LIMIT');
    for(let name in names)need(io.exists(SERIES+'/generations/'+name+'/sealed'),'UNFINISHED_GENERATION');
    let selected=selection();parent_match(selected,kind);protocol.runtime(m.inventories[kind=='APPLY'?'baseline':'candidate']);
    protocol.controls(m.controls);protocol.actions(held);boot_links();anchor();workers('candidate');space();checks();
    if(startup==null)command(['/bin/sh','/usr/libexec/home-gateway-deploy/migration-admission.sh','--telegram-start']);
    return selected;
}
function process_record() {
    let raw=fs.readfile('/proc/self/stat')??'',pid=match(raw,/^([1-9][0-9]*) /),end=rindex(raw,') '),parts=split(trim(substr(raw,end+2)),/\s+/);
    let boot=trim(fs.readfile('/proc/sys/kernel/random/boot_id')??'');
    need(pid!=null && end>=0 && match(parts[19]??'',/^[0-9]+$/),'SELF');
    return 'HG_OWNER_PROCESS_V1 '+boot+' '+pid[1]+' '+parts[19]+'\n';
}
function process_alive(raw) {
    let proof=match(raw,/^HG_OWNER_PROCESS_V1 ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ([1-9][0-9]{0,9}) ([0-9]{1,20})\n$/);
    need(proof!=null && proof[0]==raw,'OWNER_PROCESS');
    if(proof[1]!=trim(fs.readfile('/proc/sys/kernel/random/boot_id')??''))return false;
    let stat=fs.readfile('/proc/'+proof[2]+'/stat');if(stat==null)return false;
    let end=rindex(stat,') '),parts=split(trim(substr(stat,end+2)),/\s+/);need(end>=0,'OWNER_STAT');
    return parts[19]==proof[3] && parts[0]!='Z';
}
let own=process_record(),own_pid=split(trim(own),' ')[2];
function preserve_pending(path,choices) {
    if(!io.exists(path+'.new'))return;
    let raw=io.read(path+'.new',0600,2097152);
    need(length(filter(choices,v=>substr(v,0,length(raw))==raw))>0,'UNKNOWN_PENDING_RECORD');
    let n=0;while(io.exists(J+'/interrupted.'+n))n++;need(n<64,'INTERRUPTED_LIMIT');
    io.rename(path+'.new',J+'/interrupted.'+n,false);
}
function record(path,value,choices) {
    preserve_pending(path,choices??[value]);
    if(io.exists(path))need(index(choices??[value],io.read(path,0600,2097152))>=0,'UNKNOWN_RECORD');
    io.atomic(path,value,0600);
}
function phase(value) {
    let values=map(['PREPARING','PREPARED','QUARANTINING','APPLYING','CHECKING','RESTORING','COMMITTED','ROLLED_BACK','ABORTED'],v=>v+'\n');
    if(m.profile=='VM_ONLY' && getenv('HG_SERIES_VM_KILL_AT')=='partial_phase' && value=='CHECKING') {
        io.exclusive(J+'/phase.new','C',0600);io.run(['/bin/sync']);io.run(['/bin/kill','-KILL',own_pid]);
    }
    record(J+'/phase',value+'\n',values);
}
function root_prepare() {
    if(marker())return;
    let staged=SERIES+'.preparing-'+id;
    if(!io.exists(staged))io.mkdir(staged);
    io.check(staged,'directory',0700,0);
    for(let name in fs.lsdir(staged))need(index(['marker','generations'],name)>=0,'ROOT_PREPARATION_UNKNOWN');
    if(io.exists(staged+'/marker')) {
        let raw=io.read(staged+'/marker',0600,32);need(raw==substr('HG_OWNER_SERIES_V2\n',0,length(raw)),'ROOT_PREPARATION_UNKNOWN');
        if(raw!='HG_OWNER_SERIES_V2\n') {io.unlink(staged+'/marker');io.exclusive(staged+'/marker','HG_OWNER_SERIES_V2\n',0600);}
    } else io.exclusive(staged+'/marker','HG_OWNER_SERIES_V2\n',0600);
    io.mkdir(staged+'/generations');need(length(fs.lsdir(staged+'/generations'))==0,'ROOT_PREPARATION_UNKNOWN');
    io.rename(staged,SERIES,false);
}
function raw_pointer(path,choices) {
    if(!io.exists(path))return null;
    let value=line(path,40);need(index(choices,value)>=0,'FOREIGN_POINTER');return value;
}
function revoke_pid() {
    if(!io.exists(LOCK+'/pid'))return;
    let pid=line(LOCK+'/pid',16),owner=line(LOCK+'/owner-process',128),parts=split(owner,' ');
    need(parts[0]=='HG_OWNER_PROCESS_V1' && pid==parts[2] && line(LOCK+'/owner-pid',16)==pid,'LEGACY_PID');
    io.unlink(LOCK+'/pid');
}
function acquire(recovery) {
    if(serial==null)serial=io.lock('/tmp/home-gateway-deploy.serial',true);
    io.mkdir('/tmp/home-gateway');if(actions==null)actions=io.lock('/tmp/home-gateway/actions.lock',true);
    protocol.actions(actions);startup=io.lock('/etc/home-gateway-migration.lock',false);
    if(io.exists(LOCK)) {
        need(recovery,'FOREIGN_LEASE');io.check(LOCK,'directory',0700,0);
        need(line(LOCK+'/owner-series',65)==pin && line(LOCK+'/operation',36)==id,'FOREIGN_LEASE');
        if(io.exists(LOCK+'/owner-process'))need(!process_alive(io.read(LOCK+'/owner-process',0600,128)),'LIVE_OWNER');
        else need(line(SERIES+'/active',36)==id && line(J+'/kit-pin',65)==pin,'BOOT_LEASE');
        revoke_pid();
        if(io.exists(D+'/active')) {
            raw_pointer(D+'/active',[id,intent.before_transaction,intent.after_transaction]);io.unlink(D+'/active');
        }
        quiesce();
        for(let field in ['owner-process','owner-pid','pid']) {
            let value=field=='owner-process'?own:own_pid+'\n';
            if(io.exists(LOCK+'/'+field+'.new')) {
                let raw=io.read(LOCK+'/'+field+'.new',0600,128);
                let boot=split(trim(own),' ')[1];
                need(field=='owner-process'?valid_process_prefix(raw,boot):
                    (raw=='' || match(raw,/^[1-9][0-9]{0,9}\n?$/)!=null),'UNKNOWN_LEASE_PREFIX');
                let n=0;while(io.exists(LOCK+'/interrupted-'+field+'.'+n))n++;need(n<32,'LEASE_EVIDENCE_LIMIT');
                io.rename(LOCK+'/'+field+'.new',LOCK+'/interrupted-'+field+'.'+n,false);
            }
            if(field=='owner-process' && m.profile=='VM_ONLY' && getenv('HG_SERIES_VM_KILL_AT')=='recovery_partial_owner') {
                io.exclusive(LOCK+'/'+field+'.new',substr(value,0,length(value)-3),0600);io.run(['/bin/sync']);io.run(['/bin/kill','-KILL',own_pid]);
            }
            if(io.exists(LOCK+'/'+field))io.atomic(LOCK+'/'+field,value,0600);else io.exclusive(LOCK+'/'+field,value,0600);
        }
    } else {
        if(recovery && io.exists(D+'/active')) {
            raw_pointer(D+'/active',[id,intent.before_transaction,intent.after_transaction]);io.unlink(D+'/active');
        }
        let staged=fs.mkdtemp('/tmp/home-gateway-series-lease.XXXXXX');need(staged!=null,'LEASE_DIRECTORY');
        for(let field,value in {'owner-series':pin+'\n',operation:id+'\n','owner-process':own,'owner-pid':own_pid+'\n',pid:own_pid+'\n'})
            io.exclusive(staged+'/'+field,value,0600);
        io.rename(staged,LOCK,false);
    }
    lease=fs.lstat(LOCK);
}
function guardian_start() {
    let dir=fs.mkdtemp('/tmp/home-gateway-series-guard.XXXXXX');need(dir!=null,'GUARD_DIRECTORY');
    let script='umask 077; trap "" HUP; /usr/bin/ucode '+quote(kit+'/watch.uc')+' '+quote(kit)+' '+quote(pin)+' '+quote(id)+' '+quote(trim(own))+' '+quote(dir)+
        ' </dev/null >'+quote(dir+'.log')+' 2>&1 & echo $!';
    let result=capture(['/bin/sh','-c',script],64);need(result.code==0 && match(trim(result.raw),/^[1-9][0-9]*$/),'GUARD_START');
    guardian={dir,pid:trim(result.raw)};
    for(let n=0;n<30;n++) {
        if(io.exists(dir+'/ready')) {
            let ready=io.read(dir+'/ready',0600,128);need(match(ready,/^HG_OWNER_PROCESS_V1 /) && process_alive(ready),'GUARD_IDENTITY');return;
        }
        need(io.run(['/bin/kill','-0',guardian.pid]),'GUARD_DIED');need(io.run(['/bin/sleep','1']),'WAIT');
    }
    die('OWNER_SERIES_ENGINE_GUARD_TIMEOUT');
}
function history_roots() {
    let roots=['/etc/home-gateway-migration','/etc/home-gateway-owner-update',D+'/'+V1TX,
        D+'/'+line('/etc/home-gateway-owner-update/old-latest',40)];
    for(let name in generation_names()) {
        if(name==id)continue;
        let directory=SERIES+'/generations/'+name;need(io.exists(directory+'/sealed'),'UNFINISHED_GENERATION');
        push(roots,directory);let data=read_json(directory+'/intent.json',8192);
        if(data.kind=='APPLY' && io.exists(D+'/'+name))push(roots,D+'/'+name);
    }
    return sort(roots);
}
function begin(selected,kind) {
    root_prepare();need(!io.exists(J),'REPLAY');io.mkdir(J);
    intent=describe_operation(kind,id,m,selected,pin);intent.before_latest=selected.latest??'V1';
    io.exclusive(J+'/intent.json',encode(intent),0600);io.copy(kit+'/manifest.json',J+'/manifest.json',0600);
    io.exclusive(J+'/kit-pin',pin+'\n',0600);io.exclusive(J+'/phase','PREPARING\n',0600);
    io.exclusive(J+'/history.json',encode(protocol.history(history_roots())),0600);
    for(let name in ['preflight.log','postflight.log','service.log'])io.exclusive(J+'/'+name,'',0600);
    hook('preparing');
}
function repair_preparing(selected) {
    root_prepare();if(!io.exists(J)){begin(selected,selected.source==m.baseline_commit?'APPLY':'ROLLBACK');return;}
    let kind=selected.source==m.baseline_commit?'APPLY':'ROLLBACK';
    let expected=describe_operation(kind,id,m,selected,pin);expected.before_latest=selected.latest??'V1';
    for(let path,value in {'intent.json':encode(expected),'manifest.json':io.read(kit+'/manifest.json',0600,65536),
                          'kit-pin':pin+'\n',phase:'PREPARING\n'}) {
        if(io.exists(J+'/'+path)) {
            let raw=io.read(J+'/'+path,0600,65536);need(raw==substr(value,0,length(raw)),'PREPARATION_PREFIX');
            if(raw!=value){let n=0;while(io.exists(J+'/interrupted.'+n))n++;io.rename(J+'/'+path,J+'/interrupted.'+n,false);io.exclusive(J+'/'+path,value,0600);}
        } else io.exclusive(J+'/'+path,value,0600);
    }
    intent=expected;
    io.complete_prefix(J+'/history.json',encode(protocol.history(history_roots())),0600);
    protocol.verify_history(read_json(J+'/history.json',2097152));
    for(let name in ['preflight.log','postflight.log','service.log'])if(!io.exists(J+'/'+name))io.exclusive(J+'/'+name,'',0600);
}
function backup() {
    let destination=intent.kind=='APPLY'?D+'/'+id:J+'/before-runtime';io.mkdir(destination);
    if(intent.kind=='APPLY') {
        for(let name,value in {commit:m.source_commit+'\n','inventory-version':'HGDEPLOY2\n','was-running':'1\n',
            'backup.sha256':io.read(kit+'/baseline.sha256',0600,8192),'new.sha256':io.read(kit+'/candidate.sha256',0600,8192),phase:'PREPARED\n',
            'preflight.log':'','postflight.log':'','service.log':''})io.exclusive(destination+'/'+name,value,0600);
        destination+='/backup';io.mkdir(destination);
    }
    let inventory=m.inventories[intent.kind=='APPLY'?'baseline':'candidate'];
    for(let path in keys(inventory)) {
        let mode=path=='etc/init.d/home-gateway-telegram' || index(path,'usr/bin/')==0?0755:0644;
        io.mkdir(replace(destination+'/'+path,/\/[^/]+$/,''));io.copy('/'+path,destination+'/'+path,mode);
        need(io.hash(destination+'/'+path,mode,262144)==inventory[path],'BACKUP_DRIFT');hook('backup_file');
    }
    phase('PREPARED');hook('prepared');
}
function install_guard() {
    let destination='/etc/init.d/home-gateway-owner-series',link='/etc/rc.d/S06home-gateway-owner-series';
    if(io.exists(destination)) {
        let accepted=[filter(m.files,f=>f.path=='boot.init')[0].sha256];
        if(io.exists(SERIES+'/latest')) {
            let last=read_json(SERIES+'/generations/'+line(SERIES+'/latest',36)+'/manifest.json',65536);
            push(accepted,filter(last.files,f=>f.path=='boot.init')[0]?.sha256);
        }
        need(index(accepted,io.hash(destination,0755,262144))>=0,'BOOT_GUARD_DRIFT');
    }
    let bytes=io.read(kit+'/boot.init',0755,262144);
    if(io.exists(destination+'.new')) {
        let raw=io.read(destination+'.new',0755,262144);need(raw==substr(bytes,0,length(raw)),'BOOT_GUARD_PREFIX');
        io.unlink(destination+'.new');
    }
    io.exclusive(destination+'.new',bytes,0755);io.rename(destination+'.new',destination,true);
    if(io.exists(link))need(fs.readlink(link)=='../init.d/home-gateway-owner-series','BOOT_GUARD_LINK');
    else {need(fs.symlink('../init.d/home-gateway-owner-series',link),'BOOT_GUARD_LINK');io.sync('/etc/rc.d');}
    hook('guard_installed');
}
function quarantine() {
    record(SERIES+'/active',id+'\n',[id+'\n']);hook('active_published');
    phase('QUARANTINING');
    for(let name in ['S94home-gateway-deploy-recover','S95home-gateway-telegram'])if(io.exists('/etc/rc.d/'+name)) {
        let wanted=name=='S94home-gateway-deploy-recover'?'../init.d/home-gateway-deploy-recover':'../init.d/home-gateway-telegram';
        need(fs.readlink('/etc/rc.d/'+name)==wanted,'FOREIGN_BOOT_LINK');io.unlink('/etc/rc.d/'+name);
    }
    hook('quarantined');
}
function restore_boot() {
    for(let pair in [['S94home-gateway-deploy-recover','home-gateway-deploy-recover'],['S95home-gateway-telegram','home-gateway-telegram']]) {
        let path='/etc/rc.d/'+pair[0],target='../init.d/'+pair[1];
        if(io.exists(path))need(fs.readlink(path)==target,'FOREIGN_BOOT_LINK');
        else need(fs.symlink(target,path),'RESTORE_BOOT_LINK');
    }
    io.sync('/etc/rc.d');boot_links();
}
function publish(identity, recovering) {
    // Refuse all drift before the first runtime write, including unchanged files.
    for(let path in keys(m.inventories.baseline)) {
        let mode=path=='etc/init.d/home-gateway-telegram'||index(path,'usr/bin/')==0?0755:0644;
        let current=io.hash('/'+path,mode,262144);
        need(current==m.inventories.baseline[path] || current==m.inventories.candidate[path],'UNKNOWN_RUNTIME');
        let pending='/'+path+'.hg-series-new';
        if(io.exists(pending)) {
            need(index(m.changed,path)>=0,'UNKNOWN_RUNTIME_PREFIX');let raw=io.read(pending,mode,262144);
            let a=io.read(kit+'/baseline/'+path,mode,262144),b=io.read(kit+'/candidate/'+path,mode,262144);
            need(raw==substr(a,0,length(raw)) || raw==substr(b,0,length(raw)),'UNKNOWN_RUNTIME_PREFIX');
        }
    }
    let library=fs.lsdir('/usr/lib/home-gateway');
    for(let name in library)need(m.inventories.baseline['usr/lib/home-gateway/'+name]!=null ||
        (substr(name,-14)=='.hg-series-new' && index(m.changed,'usr/lib/home-gateway/'+substr(name,0,length(name)-14))>=0),'UNKNOWN_RUNTIME');
    let other=identity=='baseline'?'candidate':'baseline';
    for(let path in m.changed) {
        let mode=runtime_mode(path),target='/'+path,pending=target+'.hg-series-new',bytes=io.read(kit+'/'+identity+'/'+path,mode,262144);
        let current=io.hash(target,mode,262144);need(current==m.inventories.baseline[path] || current==m.inventories.candidate[path],'UNKNOWN_RUNTIME');
        if(io.exists(pending)) {
            let raw=io.read(pending,mode,262144),a=io.read(kit+'/baseline/'+path,mode,262144),b=io.read(kit+'/candidate/'+path,mode,262144);
            need(raw==substr(a,0,length(raw)) || raw==substr(b,0,length(raw)),'UNKNOWN_RUNTIME_PREFIX');
            let n=0;while(io.exists(J+'/interrupted-runtime.'+n))n++;need(n<32,'INTERRUPTED_LIMIT');
            io.rename(pending,J+'/interrupted-runtime.'+n,false);
        }
        if(current==m.inventories[identity][path])continue;
        if(!recovering && m.profile=='VM_ONLY' && getenv('HG_SERIES_VM_KILL_AT')=='partial_runtime') {
            io.exclusive(pending,substr(bytes,0,int(length(bytes)/2)),mode);io.run(['/bin/sync']);io.run(['/bin/kill','-KILL',own_pid]);
        }
        io.exclusive(pending,bytes,mode);if(!recovering)hook('staged_runtime');
        io.rename(pending,target,true);
    }
    protocol.runtime(m.inventories[identity]);
}
function raw_active(transaction) {
    record(D+'/active',transaction+'\n',[id+'\n',intent.before_transaction+'\n',intent.after_transaction+'\n']);
}
function start_runtime(transaction,identity) {
    protocol.runtime(m.inventories[identity]);
    let log=checks(),previous_log=io.read(J+'/postflight.log',0600,262144);
    if(previous_log=='')record(J+'/postflight.log',log,[previous_log,log]);hook('postflight');
    if(guardian==null)guardian_start();hook('guard_ready');
    if(transaction==id && intent.kind=='APPLY' && line(D+'/'+id+'/phase',32)!='COMMITTED')
        record(D+'/'+id+'/phase','CHECKING\n',['PREPARED\n','APPLYING\n','CHECKING\n']);
    raw_active(transaction);
    if(startup!=null){startup.close();startup=null;}
    started=true;command(['/etc/init.d/home-gateway-telegram','start']);
    hook('service_returned');
    let proved=false;for(let n=0;n<8;n++) {
        let result=capture(['/usr/bin/ucode','-e','import { inspect_telegram } from "/usr/libexec/home-gateway-deploy/migration-service.uc"; inspect_telegram("",{assert_root:function(r){if(r!="")die("ROOT");}},"candidate");'],8192);
        if(result.code==0){proved=true;break;}io.run(['/bin/sleep','1']);
    }
    need(proved,'WORKER_START');workers('candidate');hook('candidate_started');
}
function point_current(generation) {
    let allowed=filter([intent.before_generation,intent.after_generation],opid);
    preserve_pending(SERIES+'/current',map(allowed,v=>v+'\n'));
    if(generation=='V1') {if(io.exists(SERIES+'/current')){raw_pointer(SERIES+'/current',allowed);io.unlink(SERIES+'/current');}}
    else record(SERIES+'/current',generation+'\n',map(allowed,v=>v+'\n'));
}
function validate_backup(partial,override) {
    let apply=intent.kind=='APPLY',base=override??(apply?D+'/'+id:J+'/before-runtime');
    if(!io.exists(base)){need(partial,'MISSING_BACKUP');return;}
    let values={},modes={};
    if(apply) {
        values={commit:m.source_commit+'\n','inventory-version':'HGDEPLOY2\n','was-running':'1\n',
            'backup.sha256':io.read(kit+'/baseline.sha256',0600,8192),'new.sha256':io.read(kit+'/candidate.sha256',0600,8192),
            'preflight.log':'','postflight.log':'','service.log':''};
        for(let path in keys(values))modes[path]=0600;
    }
    for(let path in keys(m.inventories.baseline)) {
        let rel=(apply?'backup/':'')+path,mode=path=='etc/init.d/home-gateway-telegram'||index(path,'usr/bin/')==0?0755:0644;
        values[rel]=io.read(kit+'/'+(apply?'baseline':'candidate')+'/'+path,mode,262144);modes[rel]=mode;
    }
    let seen={};
    function walk(path,prefix) {
        io.check(path,'directory',0700,0);let names=fs.lsdir(path);need(names!=null && length(names)<=64,'BACKUP_INVENTORY');
        for(let name in names) {
            let rel=prefix?prefix+'/'+name:name,full=path+'/'+name,st=fs.lstat(full);
            let known=values[rel]!=null || (apply && index(['phase','phase.new'],rel)>=0);
            need(known || length(filter(keys(values),p=>index(p,rel+'/')==0))>0,'BACKUP_UNKNOWN');
            if(st?.type=='directory') {need(!known,'BACKUP_UNKNOWN');walk(full,rel);continue;}
            seen[rel]=true;
            if(apply && index(['phase','phase.new'],rel)>=0) {
                let raw=io.read(full,0600,32),phases=map(['PREPARED','APPLYING','CHECKING','COMMITTED'],v=>v+'\n');
                need(length(filter(phases,v=>rel=='phase.new'||partial?substr(v,0,length(raw))==raw:v==raw))>0,'BACKUP_PHASE');
            } else {
                let raw=io.read(full,modes[rel],262144);
                need(partial?raw==substr(values[rel],0,length(raw)):raw==values[rel],'BACKUP_DRIFT');
            }
        }
    }
    walk(base,'');
    if(!partial) {
        need(length(filter(keys(values),p=>!seen[p]))==0 && (!apply || seen.phase),'BACKUP_INCOMPLETE');
    }
}
function seal(terminal) {
    journal_layout(J,intent.kind,m.format);validate_backup(terminal=='ABORTED');
    if(io.exists(J+'/aborted-transaction'))validate_backup(true,J+'/aborted-transaction');
    phase(terminal);
    if(intent.kind=='APPLY' && io.exists(D+'/'+id+'/backup.sha256')) {
        let expected=encode(protocol.history([D+'/'+id]));
        if(io.exists(J+'/transaction.json'))need(io.read(J+'/transaction.json',0600,2097152)==expected,'TRANSACTION_EVIDENCE');
        else io.atomic(J+'/transaction.json',expected,0600);
    }
    let contents=encode(self_contents(J));preserve_pending(J+'/contents.json',[contents]);
    need(!io.exists(J+'/contents.json'),'UNEXPECTED_CONTENTS');io.atomic(J+'/contents.json',encode(self_contents(J)),0600);
    preserve_pending(J+'/sealed',['HG_OWNER_SERIES_SEALED_V1\n']);
    io.atomic(J+'/sealed','HG_OWNER_SERIES_SEALED_V1\n',0600);hook('sealed');
}
function retire() {
    io.check(LOCK,'directory',0700,0);
    need(line(LOCK+'/owner-series',65)==pin && line(LOCK+'/operation',36)==id &&
        io.read(LOCK+'/owner-process',0600,128)==own && fs.lstat(LOCK)?.inode==lease.inode,'LEASE_IDENTITY');
    let retired=fs.mkdtemp('/tmp/home-gateway-series-released.XXXXXX');need(retired!=null,'RETIRE_DIRECTORY');
    io.rename(LOCK,retired,true);hook('lease_retired');
    if(io.exists(D+'/active')) {raw_pointer(D+'/active',[id,intent.before_transaction,intent.after_transaction]);io.unlink(D+'/active');}
    if(io.exists(SERIES+'/active')) {need(line(SERIES+'/active',36)==id,'ACTIVE_ID');io.unlink(SERIES+'/active');}
}
function finish(terminal,identity) {
    let after=terminal=='COMMITTED';
    let generation=intent[after?'after_generation':'before_generation'],transaction=intent[after?'after_transaction':'before_transaction'];
    record(D+'/latest',transaction+'\n',[intent.before_transaction+'\n',intent.after_transaction+'\n']);restore_boot();
    point_current(generation);record(SERIES+'/latest',id+'\n',map(filter([intent.before_latest,id],opid),v=>v+'\n'));
    seal(terminal);retire();
    command(['/bin/sh','/usr/libexec/home-gateway-deploy/migration-admission.sh','--telegram-start']);
    protocol.runtime(m.inventories[identity]);workers('candidate');checks();
}
function validate_intent() {
    need(!io.exists(J+'/history.json.new'),'UNEXPECTED_HISTORY_PENDING');
    need(line(J+'/kit-pin',65)==pin && io.read(J+'/manifest.json',0600,65536)==io.read(kit+'/manifest.json',0600,65536),'OPERATION_PACKAGE');
    intent=read_json(J+'/intent.json',8192);
    validate_operation_intent(intent,m,pin);
    need(intent.id==id && intent.kit_pin==pin && intent.format=='HG_OWNER_SERIES_OPERATION_V1' &&
        intent.source_commit==m.source_commit && intent.baseline_commit==m.baseline_commit &&
        index(['APPLY','ROLLBACK'],intent.kind)>=0 && txid(intent.before_transaction) && txid(intent.after_transaction) &&
        (intent.before_generation=='V1'||opid(intent.before_generation)) &&
        (intent.after_generation=='V1'||opid(intent.after_generation)) && commit(intent.before_source) && commit(intent.after_source),'OPERATION_INTENT');
    protocol.verify_history(read_json(J+'/history.json',2097152));
    if(intent.before_latest=='V1')need(intent.before_generation=='V1','INTENT_PREDECESSOR');
    else {
        let before=effective(receipt(intent.before_latest,true));
        need(before.generation==intent.before_generation && before.transaction==intent.before_transaction &&
            before.source==intent.before_source,'INTENT_PREDECESSOR');
    }
}
function recover() {
    // Recover may complete an interrupted operation, never invent a new one.
    if(!io.exists(J))need(io.exists(LOCK) && line(LOCK+'/owner-series',65)==pin &&
        line(LOCK+'/operation',36)==id,'NO_OWNED_OPERATION');
    if(io.exists(J)) {
        let kind=null;
        if(io.exists(J+'/intent.json')) {
            try {kind=read_json(J+'/intent.json',8192).kind;}catch(e){}
        }
        // Before a complete intent exists no backup subtree can have been published.
        journal_layout(J,kind,m.format);
    }
    let phase_raw=io.exists(J+'/phase')?io.read(J+'/phase',0600,32):'';
    let preparing=!io.exists(J+'/intent.json') || !io.exists(J+'/kit-pin') ||
        phase_raw==substr('PREPARING\n',0,length(phase_raw));
    if(preparing) {
        let selected=selection();parent_match(selected,selected.source==m.baseline_commit?'APPLY':'ROLLBACK');
        intent=describe_operation(selected.source==m.baseline_commit?'APPLY':'ROLLBACK',id,m,selected,pin);intent.before_latest=selected.latest;
        acquire(true);anchor();repair_preparing(selected);validate_backup(true);
        if(io.exists(J+'/aborted-transaction'))validate_backup(true,J+'/aborted-transaction');
        // Only preparation prefixes may exist; no runtime publication was admitted.
        protocol.runtime(m.inventories[intent.kind=='APPLY'?'baseline':'candidate']);
        if(io.exists(D+'/'+id)) {
            // Preserve complete or interrupted owned preparation as evidence.
            let base=D+'/'+id;
            for(let name in fs.lsdir(base))need(index(['backup','commit','inventory-version','was-running','backup.sha256','new.sha256','phase','preflight.log','postflight.log','service.log'],name)>=0,'PREPARATION_UNKNOWN');
            io.rename(base,J+'/aborted-transaction',false);
        }
        if(guardian==null)guardian_start();
        start_runtime(intent.before_transaction,intent.kind=='APPLY'?'baseline':'candidate');
        finish('ABORTED',intent.kind=='APPLY'?'baseline':'candidate');return;
    }
    validate_intent();let current=line(J+'/phase',32);validate_backup(current=='ABORTED');
    if(io.exists(J+'/sealed')) {
        let saved=receipt(id),value=effective(saved);need(index(['COMMITTED','ROLLED_BACK','ABORTED'],current)>=0,'TERMINAL_PHASE');
        no_pending_global();let selected=selection();need(selected.latest==id && selected.generation==value.generation && selected.source==value.source,'TERMINAL_SELECTION');
        need(line(SERIES+'/latest',36)==id && line(D+'/latest',40)==value.transaction,'TERMINAL_POINTER');
        protocol.runtime(m.inventories[value.source==m.source_commit?'candidate':'baseline']);
        acquire(true);guardian_start();raw_active(value.transaction);
        if(startup!=null){startup.close();startup=null;}
        let running=capture(['/usr/bin/ucode','-e','import { inspect_telegram } from "/usr/libexec/home-gateway-deploy/migration-service.uc"; inspect_telegram("",{assert_root:function(r){if(r!="")die("ROOT");}},"candidate");'],8192);
        if(running.code!=0)command(['/etc/init.d/home-gateway-telegram','start']);workers('candidate');retire();
        command(['/bin/sh','/usr/libexec/home-gateway-deploy/migration-admission.sh','--telegram-start']);return;
    }
    acquire(true);
    let expected_contents=encode(self_contents(J));
    if(io.exists(J+'/contents.json')) {
        need(io.read(J+'/contents.json',0600,2097152)==expected_contents,'CONTENTS_DRIFT');
        let n=0;while(io.exists(J+'/interrupted.'+n))n++;io.rename(J+'/contents.json',J+'/interrupted.'+n,false);
    }
    preserve_pending(J+'/contents.json',[expected_contents]);preserve_pending(J+'/sealed',['HG_OWNER_SERIES_SEALED_V1\n']);
    if(intent.kind=='APPLY' && io.exists(D+'/'+id+'/backup.sha256')) {
        let expected=encode(protocol.history([D+'/'+id]));
        preserve_pending(J+'/transaction.json',[expected]);
        if(io.exists(J+'/transaction.json'))need(io.read(J+'/transaction.json',0600,2097152)==expected,'TRANSACTION_EVIDENCE');
    }
    preserve_pending(D+'/active',[id+'\n',intent.before_transaction+'\n',intent.after_transaction+'\n']);
    preserve_pending(D+'/latest',[intent.before_transaction+'\n',intent.after_transaction+'\n']);anchor();
    preserve_pending(J+'/phase',map(['PREPARING','PREPARED','QUARANTINING','APPLYING','CHECKING','RESTORING','COMMITTED','ROLLED_BACK','ABORTED'],s=>s+'\n'));
    if(current=='COMMITTED') {
        let identity=intent.kind=='APPLY'?'candidate':'baseline';protocol.runtime(m.inventories[identity]);
        guardian_start();start_runtime(intent.after_transaction,identity);finish('COMMITTED',identity);return;
    }
    phase('RESTORING');quiesce();
    let identity=intent.kind=='APPLY'?'baseline':'candidate';publish(identity,true);
    if(intent.kind=='APPLY' && io.exists(D+'/'+id+'/phase.new'))preserve_pending(D+'/'+id+'/phase',['PREPARED\n','APPLYING\n','CHECKING\n','COMMITTED\n']);
    guardian_start();start_runtime(intent.before_transaction,identity);finish('ROLLED_BACK',identity);
}
try {
    if(stage=='preflight') {
        if(io.exists('/tmp/home-gateway-deploy.serial'))serial=io.lock('/tmp/home-gateway-deploy.serial',false);
        if(io.exists('/tmp/home-gateway/actions.lock'))actions=io.lock('/tmp/home-gateway/actions.lock',false);
        preflight('APPLY',actions);
    } else if(stage=='verify') {
        no_pending_global();
        need(!io.exists(LOCK) && !io.exists(SERIES+'/active') && !io.exists(D+'/active'),'VERIFY_PENDING');
        let saved=receipt(id),selected=selection(),value=effective(saved);
        need(selected.latest==id && selected.source==value.source && line(J+'/kit-pin',65)==pin,'VERIFY_IDENTITY');
        protocol.runtime(m.inventories[value.source==m.source_commit?'candidate':'baseline']);boot_links();anchor();workers('candidate');checks();
        command(['/bin/sh','/usr/libexec/home-gateway-deploy/migration-admission.sh','--telegram-start']);
    } else if(stage=='recover')recover();
    else {
        let kind=stage=='apply'?'APPLY':'ROLLBACK',selected=preflight(kind,null);
        serial=io.lock('/tmp/home-gateway-deploy.serial',true);io.mkdir('/tmp/home-gateway');actions=io.lock('/tmp/home-gateway/actions.lock',true);
        // Recheck before publishing a pid-bearing lease, then acquire startup exclusion.
        selected=preflight(kind,actions);
        acquire(false);begin(selected,kind);guardian_start();hook('lease_published');backup();install_guard();quarantine();
        phase('APPLYING');if(kind=='APPLY')record(D+'/'+id+'/phase','APPLYING\n',['PREPARED\n','APPLYING\n']);
        quiesce();hook('before_publication');publish(kind=='APPLY'?'candidate':'baseline',false);hook('after_publication');
        phase('CHECKING');start_runtime(intent.after_transaction,kind=='APPLY'?'candidate':'baseline');
        if(kind=='APPLY')record(D+'/'+id+'/phase','COMMITTED\n',['CHECKING\n','COMMITTED\n']);hook('raw_committed');
        // Publish accepted outcome before sealing; recovery may only finalize this outcome.
        record(D+'/latest',intent.after_transaction+'\n',[intent.before_transaction+'\n',intent.after_transaction+'\n']);restore_boot();
        point_current(intent.after_generation);record(SERIES+'/latest',id+'\n',map(filter([intent.before_latest,id],opid),v=>v+'\n'));
        phase('COMMITTED');hook('committed');finish('COMMITTED',kind=='APPLY'?'candidate':'baseline');
    }
    if(startup!=null){startup.close();startup=null;}
    if(actions!=null){actions.close();actions=null;}if(serial!=null){serial.close();serial=null;}
    print('OWNER_SERIES_STAGE='+stage+' RESULT=PASS SOURCE='+m.source_commit+' OPERATION='+id+'\n');
} catch(error) {
    if(started && io.exists(LOCK)) {
        try {if(startup==null)startup=io.lock('/etc/home-gateway-migration.lock',false);revoke_pid();quiesce();}
        catch(cleanup){warn('OWNER_SERIES_CLEANUP=EXPLICIT_RECOVERY_REQUIRED\n');}
    }
    warn('OWNER_SERIES_FAILED_AFTER='+milestone+'\n',error,'\n');exit(1);
}
