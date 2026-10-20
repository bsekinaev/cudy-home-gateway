// Delivery B's sole production boundary. No arbitrary command/file interface.
import * as fs from 'fs';
import {retire_rolled_back} from './native/migration-retirement.uc';
import {open_state} from './native/migration-state.uc';
import {snapshot_io,prepare_legacy_snapshot} from './native/migration-snapshot.uc';
import {prepare_candidate_snapshot} from './native/migration-candidate.uc';
import {apply_controls,verify_controls,verify_restored_controls,verify_telegram_boot,verify_final_controls} from './native/migration-controls.uc';
import {verify_runtime,verify_candidate_runtime} from './native/migration-runtime.uc';
import {verify_handoff} from './native/migration-handoff.uc';
import {inspect_telegram,verify_private_state} from './native/migration-service.uc';
import {prepare_service_coordinator,apply_service_coordinator,commit_service_coordinator,rollback_service_coordinator,complete_service_rollback,abort_service_preparation,complete_preparation_abort,verify_preparation_abort,resume_service_rollback} from './native/migration-terminal.uc';
function require(ok,reason) {if(!ok)die('RC_B_REFUSED_'+reason);}
// Pure hardware predicates, also exercised by native ucode regression tests.
// TR3000-256MB names NAND capacity, not RAM. Linux MemTotal excludes reserved
// memory from the physical 512 MiB DDR3 (owner observation: 496724 kB).
function verify_owner_hardware(board,mem) {
 require(match(board.model??'',/^Cudy TR3000( 256MB)? v1$/),'TARGET_MODEL');
 require(board.release?.target=='mediatek/filogic','TARGET_PLATFORM');
 let amount=match('\n'+mem,/\nMemTotal:[ \t]+([0-9]+) kB\n/);
 require(amount!=null && +amount[1]>=450000 && +amount[1]<=524288,'TARGET_MEMORY');
}
function verify_available_memory(mem) {
 let available=match('\n'+mem,/\nMemAvailable:[ \t]+([0-9]+) kB\n/);
 require(available!=null && +available[1]>=32768,'MEMORY_BUDGET');
}
// End hardware predicates.
function quote(s) {return "'"+replace(s,"'","'\\''")+"'";}
function command(args,limit) {
 let p=fs.popen('/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin '+join(' ',map(args,quote))+' 2>/dev/null','r');require(p!=null,'COMMAND');
 let raw=p.read((limit??65536)+1),code=p.close();require(type(raw)=='string' && length(raw)<=(limit??65536),'COMMAND_OUTPUT');return {code,raw};
}
let kit=ARGV[0],op=ARGV[1],pin=ARGV[2],tx=ARGV[3],base='/etc/home-gateway-migration',top=fs.lstat(kit);
require(length(ARGV)>=3 && length(ARGV)<=5 && type(kit)=='string' && match(kit,/^\/[A-Za-z0-9_.\/-]+$/) && kit!='/' && !match(kit,/(^|\/)\.\.?($|\/)/),'KIT_PATH');
require(top?.type=='directory' && top.uid==0 && top.gid==0 && top.mode==0700 && match(pin,/^[0-9a-f]{64}$/),'KIT_METADATA');
function checked(path,kind,mode,limit) {
 let parts=split(path,'/'),prefix='';
 for(let i=1;i<length(parts)-1;i++) {prefix+='/'+parts[i];let s=fs.lstat(prefix);require(s?.type=='directory' && s.uid==0 && (!(s.mode&022)||s.perm.sticky),'PARENT');}
 let s=fs.lstat(path);require(s?.type==kind && s.uid==0 && s.gid==0 && s.mode==mode,'METADATA');
 if(kind=='file')require(s.nlink==1 && s.size<=limit,'LINK_OR_SIZE');return s;
}
function read(path,mode,limit) {
 let before=checked(path,'file',mode,limit),f=fs.open(path,'re');require(f!=null,'READ');let held=fs.stat('/proc/self/fd/'+f.fileno());
 require(held?.inode==before.inode && held.dev.major==before.dev.major && held.dev.minor==before.dev.minor,'READ_CHANGED');
 let raw=f.read(limit+1),closed=f.close(),after=fs.lstat(path);
 require(closed!=null && type(raw)=='string' && length(raw)==before.size && after?.inode==before.inode && after.dev.major==before.dev.major && after.dev.minor==before.dev.minor && after.mode==before.mode && after.uid==0 && after.gid==0 && after.nlink==1 && after.size==before.size && after.mtime==before.mtime,'READ_CHANGED');return raw;
}
let raw=read(kit+'/manifest.json',0600,65536),sha=command(['timeout','-k','2','10','sha256sum',kit+'/manifest.json'],1024);
require(sha.code==0 && sha.raw==pin+'  '+kit+'/manifest.json\n','MANIFEST_PIN');
let m=json(raw);require(m.format=='HGDEPLOY2_RC_B_V1' && match(m.source_commit,/^[0-9a-f]{40}$/) && type(m.files)=='array' && length(m.files)<=96 &&
 match(m.candidate_manifest_sha256,/^[0-9a-f]{64}$/) && match(m.controls_manifest_sha256,/^[0-9a-f]{64}$/),'MANIFEST');
let records={},total=0;
for(let r in m.files) {
 require(type(r.path)=='string' && match(r.path,/^[A-Za-z0-9][A-Za-z0-9_.\/-]+$/) && !match(r.path,/(^|\/)\.\.?($|\/)/) && r.path!='manifest.json' && records[r.path]==null &&
 r.uid==0 && r.gid==0 && index([0600,0644,0700,0755],r.mode)>=0 && type(r.size)=='int' && r.size>=0 && r.size<=262144 && match(r.sha256,/^[0-9a-f]{64}$/),'RECORD');
 records[r.path]=r;total+=r.size;
}
require(total<=8388608 && records['candidate/migration.sha256']?.sha256==m.candidate_manifest_sha256 && records['controls/controls.sha256']?.sha256==m.controls_manifest_sha256,'MANIFEST_BINDING');
let actual=[];
function walk(path,prefix,depth) {
 require(depth<=8,'DEPTH');checked(path,'directory',0700,0);let names=fs.lsdir(path);require(names!=null && length(names)<=96,'INVENTORY');
 for(let name in names) {let rel=prefix?prefix+'/'+name:name;
  if(fs.lstat(path+'/'+name)?.type=='directory') {require(length(filter(keys(records),p=>index(p,rel+'/')==0))>0,'EXTRA');walk(path+'/'+name,rel,depth+1);}
  else {require(rel=='manifest.json' || records[rel]!=null,'EXTRA');if(rel!='manifest.json') {let r=records[rel];require(checked(path+'/'+name,'file',r.mode,262144).size==r.size,'SIZE');push(actual,rel);}}
 }
}
walk(kit,'',0);require(length(actual)==length(m.files),'INVENTORY');
let hashes=command(['timeout','-k','2','30','sha256sum',...map(actual,p=>kit+'/'+p)],131072),rows=split(hashes.raw,'\n');
require(hashes.code==0 && pop(rows)=='' && length(rows)==length(actual),'HASH');
for(let i=0;i<length(actual);i++)require(rows[i]==records[actual[i]].sha256+'  '+kit+'/'+actual[i],'HASH');
for(let n in ['state','snapshot','candidate','runtime','handoff','coordinator','controls','service','terminal'])
 require(records['native/migration-'+n+'.uc']?.sha256==records['controls/usr/libexec/home-gateway-deploy/migration-'+n+'.uc']?.sha256,'CONTROL_CLOSURE');
let owner=m.delivery=='B_OWNER_MANUAL' && m.production_apply==true,vm=m.delivery=='B_VM_ACCEPTANCE' && m.production_apply==false;
require(owner || vm,'PRODUCTION_NOT_ACCEPTED');
if(owner) {
 require(records['acceptance.json']!=null,'ACCEPTANCE_REQUIRED');let a=json(read(kit+'/acceptance.json',0600,262144));
 require(a.format=='HG_DELIVERY_B_ACCEPTANCE_V1' && a.commit==m.source_commit && type(a.reports)=='object','ACCEPTANCE_SOURCE');
 for(let name in ['rc-b-root-cycle','rc-b-crash-apply','rc-b-crash-restore','overlay-identity','service-cycle','retirement-reboot']) {
  let r=a.reports[name];require(r?.commit==m.source_commit && r.status=='PASS' && r.failed==0 && r.total>0 && type(r.checks)=='object' && length(filter(keys(r.checks),k=>r.checks[k]!='PASS'))==0,'ACCEPTANCE_FAILED');
 }
}
if(op=='check') {print('RC_B_PACKAGE=VERIFIED SOURCE='+m.source_commit+' PROFILE='+m.delivery+'\n');exit(0);}
require(index(['preflight','prepare','apply','commit','rollback','complete-rollback','complete-abort','verify','service','retire','retire-check','verify-retired'],op)>=0,'OPERATION');
require(match(fs.readfile('/etc/openwrt_release')??'',/DISTRIB_RELEASE='25\.12\.5'/),'OPENWRT_VERSION');
let version=fs.popen('/bin/busybox ash --help 2>&1','r');require(version!=null,'BUSYBOX');let v=version.read(4097);version.close();require(type(v)=='string' && length(v)<=4096 && index(v,'BusyBox v1.37.0')>=0,'BUSYBOX_VERSION');
require(trim(fs.readfile('/proc/1/comm')??'')=='procd','PROCD_PID1');
if(vm) {
 require(read('/etc/hg-disposable-vm',0600,64)=='HG_NETWORKLESS_OPENWRT_VM_V1\n' && trim(fs.readfile('/proc/1/comm')??'')=='procd','VM_ONLY');
 let arch=command(['uname','-m'],64);require(arch.code==0 && trim(arch.raw)=='x86_64','VM_ONLY');
 for(let net in fs.lsdir('/sys/class/net')??[])require(fs.lstat('/sys/class/net/'+net+'/device')==null,'VM_NETWORK_DEVICE');
} else {
 let board=command(['ubus','-S','call','system','board'],8192);require(board.code==0,'BOARD');let b=json(board.raw);
 verify_owner_hardware(b,fs.readfile('/proc/meminfo')??'');
}
const retired_prefix='home-gateway-migration.retired.';
function retirement_identity() {return owner?{source:'908dd3222b81992d9fee056bd015a1266a0ce8d7',pin:'67b65f1ceabe1534ff74fba8f6c486e9d02bfce9a7e7999875bd11929df467a1'}:{source:m.source_commit,pin};}
function retire(nonce,mutate,check_only) {let old=retirement_identity();return retire_rolled_back('',null,nonce,old.source,old.pin,mutate,function(){return 'HGDEPLOY2_DELIVERY_B_V1';},check_only);}
if(op=='retire' || op=='retire-check' || op=='verify-retired') {
 require(length(ARGV)==4,'RETIRE_ARGUMENTS');
 let archive=retire(tx,op=='retire',op=='retire-check'?true:null);print((op=='retire'?'RC_B_RETIREMENT=PASS':op=='retire-check'?'RC_B_RETIREMENT_CHECK=PASS':'RC_B_RETIREMENT_VERIFIED=PASS')+' TRANSACTION='+tx+' ARCHIVE='+archive+'\n');exit(0);
}
if(op=='preflight' || op=='prepare') {
 require(length(ARGV)==3 && fs.lstat(base)==null,'EXISTING_MIGRATION');
 let retired=filter(fs.lsdir('/etc')??[],n=>index(n,retired_prefix)==0);require(length(retired)<=8,'RETIREMENT_BUDGET');
 for(let name in retired) {
  // The verifier borrows/closes only its child FD8. Keep this caller's FD8
  // intact for Prepare's open_state() and for every subsequent archive.
  let nonce=substr(name,length(retired_prefix));require(match(nonce,/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),'ARCHIVE_NAME');
  let r=command(['timeout','-k','2','180','/usr/bin/ucode',kit+'/rc-b.uc',kit,'verify-retired',pin,nonce],4096);
  require(r.code==0 && r.raw=='RC_B_RETIREMENT_VERIFIED=PASS TRANSACTION='+nonce+' ARCHIVE=/etc/'+name+'\n','RETIREMENT_ARCHIVE');
 }
 checked('/etc/home-gateway','directory',0700,0);checked('/etc/home-gateway/secrets','directory',0700,0);
 for(let n in ['telegram.token','telegram.user_id','telegram.chat_id'])require(length(read('/etc/home-gateway/secrets/'+n,0600,8192))>0,'PRIVATE_INPUT');
 verify_available_memory(fs.readfile('/proc/meminfo')??'');
 let old=command(['timeout','-k','2','90','/bin/sh',kit+'/legacy-preflight.sh','4b1f9ea568167a67f24470615b31efe4b9fd7a68374e666443ad31945e58922e']);require(old.code==0,'LEGACY_BASELINE');
 if(op=='preflight') {print('RC_B_PREFLIGHT=PASS SOURCE='+m.source_commit+' SERVICE_INTENT=CHECKED_DURING_PREPARE\n');exit(0);}
}
require(op=='prepare'?length(ARGV)==3:(type(tx)=='string' && match(tx,/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)),'TRANSACTION');
let delivery=function() {
 let path=base+'/delivery.json';
 if(fs.lstat(path)!=null) {let rec=json(read(path,0600,1024));require(rec.guard_inode==checked('/etc/home-gateway-migration.lock','file',0600,0).inode,'GUARD_REPLACED');}
 return 'HGDEPLOY2_DELIVERY_B_V1';
};
let s=open_state('',op=='prepare',null,op=='rollback'?true:null,null,true,delivery),marker=read(base+'/marker',0600,128),nonce=trim(substr(marker,22));
if(op=='prepare') {print('RC_B_TRANSACTION='+nonce+' SOURCE='+m.source_commit+'\n');fs.stdout.flush();}
else require(tx==nonce,'TRANSACTION_IDENTITY');
let proxy={...s,read_only:true,fence:function(){s.assert_root('');}},io=snapshot_io('',proxy,null),recordPath=base+'/delivery.json',record=null;
if(op=='prepare') {
 require(fs.lstat(recordPath)==null && fs.lstat(recordPath+'.new')==null,'NO_REPLAY');
 s.fence();record={format:'HG_DELIVERY_B_RECORD_V1',source:m.source_commit,manifest_sha256:pin,marker,profile:m.delivery,guard_inode:io.checked('/etc/home-gateway-migration.lock','file',0600,0).inode,boot_id:trim(fs.readfile('/proc/sys/kernel/random/boot_id')??'')};
 require(match(record.boot_id,/^[0-9a-f-]{36}$/),'BOOT_ID');io.write(recordPath+'.new',sprintf('%J\n',record),0600);require(fs.rename(recordPath+'.new',recordPath),'RECORD');io.sync([base]);
 prepare_legacy_snapshot('',s,null);prepare_candidate_snapshot('',s,null,kit+'/candidate',m.candidate_manifest_sha256);
 prepare_service_coordinator('',s,null,kit+'/controls',m.controls_manifest_sha256,m.source_commit);apply_controls('',s,null);
} else {
 if(fs.lstat(recordPath)!=null) {
  record=json(read(recordPath,0600,1024));require(join(',',sort(keys(record)))=='boot_id,format,guard_inode,manifest_sha256,marker,profile,source' && record.format=='HG_DELIVERY_B_RECORD_V1' && record.marker==marker && record.source==m.source_commit && record.manifest_sha256==pin && record.profile==m.delivery && match(record.boot_id,/^[0-9a-f-]{36}$/),'RECORD_IDENTITY');
  require(fs.lstat(recordPath+'.new')==null,'PARTIAL_RECORD');
 } else require(index(['rollback','complete-abort','verify'],op)>=0 && (s.phase()=='PREPARING' || read(base+'/preparation-abort',0600,128)==marker),'MISSING_RECORD');
}
if(fs.lstat(base+'/coordinator.json')!=null) {
 let p=json(io.read(base+'/coordinator.json',0600,1024));
 require(type(p)=='object' && join(',',sort(keys(p)))=='commit,format,manifest_sha256,marker,was_running' && p.format=='HG_NATIVE_COORDINATOR_V1' && p.marker==marker &&
  p.commit==m.source_commit && p.manifest_sha256==m.candidate_manifest_sha256 && type(p.was_running)=='int' && (p.was_running==0 || p.was_running==1),'PLAN_PACKAGE_BINDING');
}
if(fs.lstat(base+'/controls.json')!=null) {
 let c=json(io.read(base+'/controls.json',0600,8192));require(c.format=='HG_MIGRATION_CONTROLS_V2' && c.marker==marker && type(c.files)=='object','CONTROL_BINDING');
 for(let rel in keys(c.files))require(c.files[rel].sha256==records['controls/'+rel]?.sha256 && c.files[rel].mode==records['controls/'+rel]?.mode,'CONTROL_PACKAGE_BINDING');
}
let start='NONE',finish='NONE';
if(op=='apply') {
 require(record.boot_id==trim(fs.readfile('/proc/sys/kernel/random/boot_id')??''),'REBOOT_NO_APPLY');
 if(apply_service_coordinator('',s,null))start='CANDIDATE';finish='COMMIT';
} else if(op=='commit')commit_service_coordinator('',s,null);
else if(op=='rollback') {
 if(fs.lstat(base+'/preparation-abort')!=null && s.phase()=='ROLLED_BACK')complete_preparation_abort('',s,null);
 else if(s.phase()=='PREPARING' || fs.lstat(base+'/preparation-abort')!=null) {abort_service_preparation('',s,null);finish='ABORT';}
 else if(s.phase()=='ROLLED_BACK') {if(resume_service_rollback('',s,null))start='LEGACY';finish='ROLLBACK';}
 else {if(rollback_service_coordinator('',s,null))start='LEGACY';finish='ROLLBACK';}
} else if(op=='complete-rollback')complete_service_rollback('',s,null);
else if(op=='complete-abort')complete_preparation_abort('',s,null);
else if(op=='service') {
 let p=json(io.read(base+'/coordinator.json',0600,1024)),expected=s.phase()=='APPLYING'?'candidate':'legacy';
 inspect_telegram('',s,p.was_running?expected:'stopped');
} else if(op=='verify') {
 let phase=s.phase(),lock=io.checked('/etc/home-gateway-migration.lock','file',0600,0);
 require(index(['COMMITTED','ROLLED_BACK'],phase)>=0 && io.read(base+'/admission',0600,128)=='HG_MIGRATION_ADMITTED_V2 '+phase+' '+nonce+' '+lock.inode+'\n','ADMISSION');
 require(fs.lstat(base+'/phase.new')==null && fs.lstat(base+'/admission.new')==null && fs.lstat('/tmp/home-gateway-deploy.lock')==null,'PENDING_OR_FENCED');
 if(fs.lstat(base+'/preparation-abort')!=null)verify_preparation_abort('',proxy,null);
 else {
  let p=json(io.read(base+'/coordinator.json',0600,1024));verify_private_state('',proxy,null,'prepare',true);
  if(phase=='COMMITTED') {verify_candidate_runtime('',proxy,null);verify_controls('',proxy,null);let h=verify_handoff('',proxy,null);require(io.read('/etc/home-gateway-deploy/latest',0600,40)==h.id+'\n','LATEST');verify_private_state('',proxy,null,'apply',true);}
  else {verify_runtime('',proxy,null,false);verify_final_controls('',proxy,null);verify_private_state('',proxy,null,'rollback',true);}
  verify_telegram_boot('',proxy,null,true);inspect_telegram('',proxy,p.was_running?(phase=='COMMITTED'?'candidate':'legacy'):'stopped');
 }
}
print('RC_B_STAGE='+op+' RESULT=PASS PHASE='+s.phase()+' SOURCE='+m.source_commit+' TRANSACTION='+nonce+' SERVICE_START='+start+' FINISH='+finish+'\n');
s.close();
