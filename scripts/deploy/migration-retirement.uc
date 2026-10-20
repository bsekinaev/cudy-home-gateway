// Explicit terminal retirement. Never applies runtime or starts/stops a service.
import * as fs from 'fs';
import {snapshot_io} from './migration-snapshot.uc';
import {verify_runtime} from './migration-runtime.uc';
import {verify_telegram_boot} from './migration-controls.uc';
import {inspect_telegram,verify_private_state} from './migration-service.uc';
function require(ok,why) {if(!ok)die('MIGRATION_RETIRE_'+why);}
const KEEP=['etc/init.d/home-gateway-migration','usr/libexec/home-gateway-deploy/migration-state.uc'];
const BOOT='etc/rc.d/S08home-gateway-migration',TARGET='../init.d/home-gateway-migration';
const CONTROLS=['etc/init.d/home-gateway-migration',...map(['state','snapshot','candidate','runtime','handoff','coordinator','controls','service','terminal','admission'],n=>'usr/libexec/home-gateway-deploy/migration-'+n+(n=='admission'?'.sh':'.uc'))];
export function retire_rolled_back(root,bb,nonce,source,pin,mutate,authorize,check_only) {
 require(type(root)=='string' && (root!='' || (type(authorize)=='function' && authorize()=='HGDEPLOY2_DELIVERY_B_V1')),'BOUNDARY');
 require(check_only==null || check_only==true,'CHECK_MODE');require(!check_only || !mutate,'CHECK_MODE');
 require(type(mutate)=='bool' && match(nonce,/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) && match(source,/^[0-9a-f]{40}$/) && match(pin,/^[0-9a-f]{64}$/),'IDENTITY');
 const BASE=root+'/etc/home-gateway-migration',ARCHIVE=BASE+'.retired.'+nonce,LOCK=root+'/etc/home-gateway-migration.lock',RAM=root+'/tmp/home-gateway-deploy.lock';
 let where=fs.lstat(BASE)!=null?BASE:ARCHIVE,owner=0,group=0;
 if(root!='') {require(root!='/' && match(root,/^\/[A-Za-z0-9_.\/-]+$/) && !match(root,/(^|\/)\.\.?($|\/)/),'ROOT');let top=fs.lstat(root),mark=fs.lstat(root+'/.hg-deploy-test-root');require(top?.type=='directory' && mark?.type=='file' && mark.uid==top.uid && mark.gid==top.gid && mark.nlink==1,'LAB');owner=top.uid;group=top.gid;}
 function checked(path,kind,mode,limit) {
  let parts=split(path,'/'),parent='';for(let i=1;i<length(parts)-1;i++) {parent+='/'+parts[i];let s=fs.lstat(parent);require(s?.type=='directory' && (s.uid==0 || s.uid==owner) && (!(s.mode&022) || s.perm.sticky),'PARENT');}
  let s=fs.lstat(path);require(s?.type==kind && s.uid==owner && s.gid==group && s.mode==mode,'METADATA');if(kind=='file')require(s.nlink==1 && s.size<=limit,'LINK_OR_SIZE');return s;
 }
 let lock=checked(LOCK,'file',0600,0),guard=fs.fdopen(8,'r');
 require(guard!=null && guard.ioctl(fs.IOC_DIR_NONE,0x54,0x51)==0,'FD8');
 let held=fs.stat('/proc/self/fd/'+guard.fileno());
 require(held?.inode==lock.inode && held.dev.major==lock.dev.major && held.dev.minor==lock.dev.minor && guard.lock('xn')!=null,'BUSY');
 const marker='HG_MIGRATION_STATE_V1 '+nonce+'\n';
 function raw(path,mode,limit) {let s=checked(path,'file',mode,limit),f=fs.open(path,'re');require(f!=null,'READ');let h=fs.stat('/proc/self/fd/'+f.fileno());require(h?.inode==s.inode && h.dev.major==s.dev.major && h.dev.minor==s.dev.minor,'READ_CHANGED');let data=f.read(limit+1),closed=f.close(),after=fs.lstat(path);require(closed!=null && type(data)=='string' && length(data)==s.size && after?.inode==s.inode && after.dev.major==s.dev.major && after.dev.minor==s.dev.minor && after.size==s.size && after.mode==mode && after.uid==owner && after.gid==group && after.nlink==1 && after.mtime==s.mtime,'READ_CHANGED');return data;}
 function assert_root(r) {
  require(r==root,'ROOT_CHANGED');let s=checked(LOCK,'file',0600,0),h=fs.stat('/proc/self/fd/'+guard.fileno());require(s.inode==lock.inode && s.dev.major==lock.dev.major && s.dev.minor==lock.dev.minor && h?.inode==lock.inode && h.dev.major==lock.dev.major && h.dev.minor==lock.dev.minor,'GUARD_CHANGED');
  checked(where,'directory',0700,0);require(raw(where+'/marker',0600,128)==marker,'TRANSACTION');
  require(where==BASE?fs.lstat(ARCHIVE)==null:fs.lstat(BASE)==null,'STATE_CONFLICT');
 }
 assert_root(root);
 function view() {return {read_only:true,archive_base:where==ARCHIVE?ARCHIVE:null,assert_root,fence:function(){assert_root(root);},phase:function(){require(raw(where+'/phase',0600,32)=='ROLLED_BACK\n','PHASE');return 'ROLLED_BACK';},assert_delivery:function(){return 'HGDEPLOY2_DELIVERY_B_V1';}};}
 function context() {
  let s=view();s.phase();let io=snapshot_io(root,s,bb);
  require(raw(where+'/admission',0600,128)=='HG_MIGRATION_ADMITTED_V2 ROLLED_BACK '+nonce+' '+lock.inode+'\n','ADMISSION');
  let d=json(raw(where+'/delivery.json',0600,1024));require(join(',',sort(keys(d)))=='boot_id,format,guard_inode,manifest_sha256,marker,profile,source' && match(d.boot_id,/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) && index(['B_OWNER_MANUAL','B_VM_ACCEPTANCE'],d.profile)>=0 && d.format=='HG_DELIVERY_B_RECORD_V1' && d.source==source && d.manifest_sha256==pin && d.marker==marker && d.guard_inode==lock.inode,'OLD_PACKAGE');
  for(let n in ['phase.new','admission.new','delivery.json.new','coordinator.json.new','coordinator.publish-pending','controls.json.new','latest.pending','handoff.json.new','handoff.publish-pending'])require(fs.lstat(where+'/'+n)==null,'PARTIAL_STATE');
  let p=json(raw(where+'/coordinator.json',0600,1024));require(join(',',sort(keys(p)))=='commit,format,manifest_sha256,marker,was_running' && p.format=='HG_NATIVE_COORDINATOR_V1' && p.marker==marker && p.commit==source && type(p.was_running)=='int' && (p.was_running==0 || p.was_running==1) && io.hashes([where+'/candidate/migration.sha256'])[where+'/candidate/migration.sha256']==p.manifest_sha256,'PLAN');
  verify_runtime(root,s,bb,false);verify_private_state(root,s,bb,'prepare',true);verify_private_state(root,s,bb,'rollback',true);
  verify_telegram_boot(root,s,bb,true);inspect_telegram(root,s,p.was_running?'legacy':'stopped');
  let boots=fs.lsdir(root+'/etc/rc.d');require(boots!=null && length(boots)<=256 && length(filter(boots,n=>match(n,/home-gateway-migration$/) && n!='S08home-gateway-migration'))==0,'EXTRA_BOOT_LINK');
  let controls=json(raw(where+'/controls.json',0600,8192));require(join(',',sort(keys(controls.files)))==join(',',sort([...CONTROLS])),'CONTROL_INVENTORY');
  for(let rel in CONTROLS) {
   if(index(KEEP,rel)>=0 && fs.lstat(root+'/'+rel)!=null) {let rec=controls.files[rel];io.read(root+'/'+rel,rec.mode,262144);require(io.hashes([root+'/'+rel])[root+'/'+rel]==rec.sha256,'CONTROL_DRIFT');}
   else require(fs.lstat(root+'/'+rel)==null && (where==ARCHIVE || index(KEEP,rel)<0),'CONTROL_DRIFT');
  }
  let boot=fs.lstat(root+'/'+BOOT);if(boot!=null) {checked(root+'/'+BOOT,'link',0777,0);require(boot.nlink==1 && fs.readlink(root+'/'+BOOT)==TARGET,'BOOT_DRIFT');}else require(where==ARCHIVE,'MISSING_BOOT');
  checked(where+'/fence','directory',0700,0);require(join(',',fs.lsdir(where+'/fence'))=='marker' && raw(where+'/fence/marker',0600,128)==marker,'FENCE_MARKER');
  return io;
 }
 let io=context(),plan=sprintf('%J\n',{format:'HG_RETIREMENT_V1',marker,guard_inode:lock.inode,source,manifest_sha256:pin,archive:ARCHIVE});
 const complete='HG_MIGRATION_RETIRED_V1 '+nonce+' '+lock.inode+'\n';
 function owned_ram() {let s=checked(RAM,'link',0777,0),to=fs.readlink(RAM);require(s.nlink==1 && (to==where+'/fence' || (where==ARCHIVE && to==BASE+'/fence')),'FOREIGN_FENCE');}
 if(fs.lstat(RAM)!=null)owned_ram();
 for(let pair in [['retirement.json',plan,1024],['retirement.complete',complete,128]]) {
  let final=where+'/'+pair[0],pending=final+'.new';
  if(fs.lstat(final)!=null)require(raw(final,0600,pair[2])==pair[1] && fs.lstat(pending)==null,'UNKNOWN_PUBLICATION');
  else if(fs.lstat(pending)!=null) {let part=raw(pending,0600,pair[2]);require(length(part)<=length(pair[1]) && part==substr(pair[1],0,length(part)),'FOREIGN_PARTIAL');}
 }
 if(where==ARCHIVE)require(raw(where+'/retirement.json',0600,1024)==plan,'UNKNOWN_ARCHIVE');
 else require(fs.lstat(where+'/retirement.complete')==null && fs.lstat(where+'/retirement.complete.new')==null,'UNKNOWN_PUBLICATION');
 if(check_only) {guard.close();return where;}
 if(!mutate) {
  require(where==ARCHIVE && raw(where+'/retirement.json',0600,1024)==plan && raw(where+'/retirement.complete',0600,128)==complete && fs.lstat(RAM)==null,'NOT_COMPLETE');
  for(let rel in [...KEEP,BOOT])require(fs.lstat(root+'/'+rel)==null,'INCOMPLETE_CONTROLS');guard.close();return ARCHIVE;
 }
 // The existing marker-only migration fence is also fail-closed to HG1:
 // legacy recover refuses a PID-less lease instead of adopting/deleting it.
 if(fs.lstat(RAM)==null) {require(fs.symlink(where+'/fence',RAM),'BUSY');io.sync([root+'/tmp']);}
 owned_ram();io=context();
 function publish(name,data,limit) {
  assert_root(root);let path=where+'/'+name,pending=path+'.new';
  if(fs.lstat(path)!=null) {require(raw(path,0600,limit)==data && fs.lstat(pending)==null,'UNKNOWN_PUBLICATION');return;}
  if(fs.lstat(pending)!=null) {
   let part=raw(pending,0600,limit);require(length(part)<=length(data) && part==substr(data,0,length(part)),'FOREIGN_PARTIAL');let dest=null;
   for(let i=0;i<8;i++)if(fs.lstat(path+'.interrupted.'+i)==null) {dest=path+'.interrupted.'+i;break;}
   require(dest!=null && fs.rename(pending,dest),'EVIDENCE_LIMIT');io.sync([where]);
  }
  let f=fs.open(pending,'wxe',0600);require(f!=null && fs.chmod(pending,0600),'WRITE');let ok=f.write(data)==length(data) && f.flush()!=null;require(f.close()!=null && ok,'WRITE');io.sync([pending,where]);
  require(raw(pending,0600,limit)==data && fs.rename(pending,path),'PUBLISH');io.sync([where]);
 }
 if(where==BASE) {
  publish('retirement.json',plan,1024);io=context();
  require(fs.lstat(ARCHIVE)==null && fs.rename(BASE,ARCHIVE),'ARCHIVE_RENAME');where=ARCHIVE;io=snapshot_io(root,view(),bb);io.sync([root+'/etc']);
 } else require(raw(where+'/retirement.json',0600,1024)==plan,'UNKNOWN_ARCHIVE');
 io=context();owned_ram();
 // Only these three exact verified controls are retired; runtime, receiver,
 // deployment journal, latest, private state and Telegram remain untouched.
 for(let rel in [BOOT,...KEEP]) {assert_root(root);if(fs.lstat(root+'/'+rel)!=null) {if(rel==BOOT) {checked(root+'/'+rel,'link',0777,0);require(fs.readlink(root+'/'+rel)==TARGET,'BOOT_DRIFT');}else {let r=json(raw(where+'/controls.json',0600,8192)).files[rel];io.read(root+'/'+rel,r.mode,262144);require(io.hashes([root+'/'+rel])[root+'/'+rel]==r.sha256,'CONTROL_DRIFT');}require(fs.unlink(root+'/'+rel),'CONTROL_UNLINK');io.sync([replace(root+'/'+rel,/\/[^/]+$/,'')]);}}
 io=context();publish('retirement.complete',complete,128);owned_ram();require(fs.unlink(RAM),'FENCE_RELEASE');io.sync([root+'/tmp']);assert_root(root);guard.close();return ARCHIVE;
};
