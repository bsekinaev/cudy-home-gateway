// Independent, OOM-protected startup guardian. Never apply or restore runtime.
import * as fs from 'fs';
function require(ok,why) { if(!ok)die('OWNER_GUARD_'+why); }
function quote(s) { return "'"+replace(s,"'","'\\''")+"'"; }
function run(args) { let p=fs.popen(join(' ',map(args,quote))+' >/dev/null 2>&1','r');require(p!=null,'PROCESS');return p.close()==0; }
function regular(path,limit) {
    // Read immutable snapshots through an open FD: an authenticated owner
    // handoff may atomically rename a new record while this guardian reads.
    for(let attempt=0;attempt<4;attempt++) {
        let s=fs.lstat(path);require(s?.type=='file' && s.uid==0 && s.gid==0 && s.mode==0600 && s.nlink==1 && s.size<=limit,'METADATA');
        let f=fs.open(path,'re');require(f!=null,'OPEN');let held=fs.stat('/proc/self/fd/'+f.fileno());
        if(held?.inode!=s.inode || held.dev.major!=s.dev.major || held.dev.minor!=s.dev.minor) {f.close();continue;}
        require(held.type=='file' && held.uid==0 && held.gid==0 && held.mode==0600 && held.nlink==1 && held.size<=limit,'HELD_METADATA');
        let raw=f.read(limit+1),closed=f.close();require(closed!=null && type(raw)=='string' && length(raw)==held.size,'READ');return raw;
    }
    die('OWNER_GUARD_RECORD_CHANGED');
}
function exclusive(path,raw) {
    require(fs.lstat(path)==null && fs.lstat(path+'.new')==null,'UNKNOWN_RECEIPT');let f=fs.open(path+'.new','wxe',0600);
    require(f!=null && f.write(raw)==length(raw) && f.flush()!=null && f.close()!=null,'RECEIPT');
    require(fs.rename(path+'.new',path),'RECEIPT_PUBLISH');
}
require(length(ARGV)==4,'ARGUMENTS');
let kit=ARGV[0],pin=ARGV[1],owner=ARGV[2],dir=ARGV[3];
require(match(kit??'',/^\/[A-Za-z0-9_./-]+$/) && !match(kit,/(^|\/)\.\.?($|\/)/) &&
    match(pin??'',/^[0-9a-f]{64}$/) && match(dir??'',/^\/tmp\/home-gateway-owner-guard\.[A-Za-z0-9]{6}$/),'ARGUMENTS');
let expected=match(owner??'',/^HG_OWNER_PROCESS_V1 ([0-9a-f-]{36}) ([1-9][0-9]{0,9}) ([0-9]{1,20})$/);
require(expected!=null && expected[0]==owner,'OWNER');
let ds=fs.lstat(dir);require(ds?.type=='directory' && ds.uid==0 && ds.gid==0 && ds.mode==0700 && length(fs.lsdir(dir))==0,'DIRECTORY');
let oom=fs.open('/proc/self/oom_score_adj','we');
require(oom!=null && oom.write('-1000\n')==6 && oom.flush()!=null && oom.close()!=null &&
    trim(fs.readfile('/proc/self/oom_score_adj')??'')=='-1000','OOM_PROTECTION');
require(run(['/usr/bin/ucode',kit+'/inspect.uc',kit,pin,'kit']),'KIT');
const J='/etc/home-gateway-owner-update',LOCK='/tmp/home-gateway-deploy.lock',SERIAL='/tmp/home-gateway-deploy.serial';
function load_owner_lease() {
    let s=fs.lstat(LOCK);if(s?.type!='directory' || s.uid!=0 || s.gid!=0 || s.mode!=0700)return false;
    if(regular(LOCK+'/owner-update',65)!=pin+'\n')return false;
    let raw=regular(LOCK+'/owner-process',128),m=match(raw,/^HG_OWNER_PROCESS_V1 ([0-9a-f-]{36}) ([1-9][0-9]{0,9}) ([0-9]{1,20})\n$/);
    require(m!=null && m[0]==raw,'LEASE_PROCESS');
    // Follow an authenticated same-kit recovery owner. Retiring the previous
    // guardian immediately would leave a gap if recovery itself was killed
    // before it reached quiescence or started its own startup guardian.
    owner=substr(raw,0,length(raw)-1);expected=m;return true;
}
function terminal() {
    let s=fs.lstat(J);require(s?.type=='directory' && s.uid==0 && s.gid==0 && s.mode==0700,'JOURNAL');
    require(regular(J+'/kit-pin',65)==pin+'\n','JOURNAL_PIN');
    let phase=regular(J+'/phase',32);return phase=='COMMITTED\n' || phase=='ROLLED_BACK\n';
}
function owner_alive() {
    if(trim(fs.readfile('/proc/sys/kernel/random/boot_id')??'')!=expected[1])return false;
    let raw=fs.readfile('/proc/'+expected[2]+'/stat');if(raw==null)return false;
    let end=rindex(raw,') '),f=split(trim(substr(raw,end+2)),/\s+/);
    require(end>=0 && match(f[19]??'',/^[0-9]+$/),'PROCESS_STAT');
    return f[19]==expected[3] && f[0]!='Z';
}
function serial_lock() {
    let s=fs.lstat(SERIAL);require(s?.type=='file' && s.uid==0 && s.gid==0 && s.mode==0600 && s.nlink==1 && s.size==0,'SERIAL');
    let f=fs.open(SERIAL,'re');require(f!=null,'SERIAL_OPEN');
    let held=fs.stat('/proc/self/fd/'+f.fileno());
    require(held?.inode==s.inode && held.dev.major==s.dev.major && held.dev.minor==s.dev.minor && held.size==0,'SERIAL_IDENTITY');
    if(f.lock('xn')==null) {f.close();return null;}
    let now=fs.lstat(SERIAL);require(now?.inode==s.inode && now.dev.major==s.dev.major && now.dev.minor==s.dev.minor && now.size==0,'SERIAL_CHANGED');return f;
}
let raw=fs.readfile('/proc/self/stat'),pid=match(raw??'',/^([1-9][0-9]*) /),end=rindex(raw??'',') '),fields=split(trim(substr(raw??'',end+2)),/\s+/);
require(pid!=null && end>=0 && match(fields[19]??'',/^[0-9]+$/),'SELF');
let own='HG_OWNER_PROCESS_V1 '+trim(fs.readfile('/proc/sys/kernel/random/boot_id'))+' '+pid[1]+' '+fields[19]+'\n';
require(load_owner_lease() && owner==ARGV[2] && !terminal() && owner_alive(),'INITIAL_STATE');
exclusive(dir+'/ready',own);
if(json(fs.readfile(kit+'/manifest.json')).profile=='VM_ONLY' && getenv('HG_OWNER_VM_GUARD_DELAY')=='30')require(run(['/bin/sleep','30']),'VM_DELAY');
while(true) {
    if(!load_owner_lease() || terminal())exit(0);
    if(owner_alive()) {require(run(['/bin/sleep','1']),'WAIT');continue;}
    let lock=serial_lock();if(lock==null) {require(run(['/bin/sleep','1']),'WAIT');continue;}
    if(!load_owner_lease() || terminal()) {lock.close();exit(0);}
    if(owner_alive()) {lock.close();continue;}
    require(run(['/usr/bin/ucode',kit+'/inspect.uc',kit,pin,'mixed']),'RUNTIME');
    require(run(['/usr/bin/ucode','-e','import { quiesce_telegram } from "/usr/libexec/home-gateway-deploy/migration-service.uc"; quiesce_telegram("",{assert_root:function(r){if(r!="")die("ROOT");}});']),'QUIESCE');
    exclusive(dir+'/done','HG_OWNER_GUARD_QUIESCED_V1\n');
    require(lock.close()!=null,'SERIAL_CLOSE');
    print('OWNER_UPDATE_GUARD_QUIESCED=PASS\n');exit(0);
}
