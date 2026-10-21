// Read-only validation for the VM-only owner update prototype.
import * as fs from 'fs';
function require(ok, why) { if (!ok) die('OWNER_UPDATE_REFUSED_' + why); }
function quote(s) { return "'" + replace(s, "'", "'\\''") + "'"; }
function command(s) { let p=fs.popen(s+' >/dev/null 2>&1','r'); require(p!=null,'PROCESS');return p.close(); }
function checked(path,kind,mode,limit) {
    let parts=split(path,'/'),prefix='';
    for(let i=1;i<length(parts)-1;i++) {
        prefix+='/'+parts[i];let s=fs.lstat(prefix);
        require(s?.type=='directory' && s.uid==0 && (!(s.mode&022)||s.perm.sticky),'PARENT');
    }
    let s=fs.lstat(path);
    require(s?.type==kind && s.uid==0 && s.gid==0 && s.mode==mode,'METADATA');
    if(kind=='file')require(s.nlink==1 && s.size<=limit,'SIZE_OR_LINK');
    return s;
}
function read(path,mode,limit) { checked(path,'file',mode,limit);let v=fs.readfile(path);require(type(v)=='string' && length(v)<=limit,'READ');return v; }
const PATHS=['etc/init.d/home-gateway-telegram','usr/bin/gateway','usr/bin/home-gateway-ci-smoke',
    ...map(['actions.uc','asata.sh','common.sh','dns.sh','doctor.sh','health.sh','incidents.uc','network.sh',
    'notifications.uc','redmi.sh','selftest.sh','status.sh','tailscale.sh','telegram-poller.uc','telegram.sh','torrent.sh','vpn.sh'],n=>'usr/lib/home-gateway/'+n)];
const BASELINE='62592457237e7f026786c086d1ca6fdd4b6c095d';
const DELTA='usr/lib/home-gateway/telegram-poller.uc';
let kit=ARGV[0],pin=ARGV[1],operation=ARGV[2];
require(length(ARGV)==3 && match(kit??'',/^\/[A-Za-z0-9_./-]+$/) && !match(kit,/(^|\/)\.\.?($|\/)/) && match(pin??'',/^[0-9a-f]{64}$/),'ARGUMENTS');
checked(kit,'directory',0700,0);
read(kit+'/manifest.json',0600,65536);
require(command('printf '+quote(pin+'  '+kit+'/manifest.json\n')+' | sha256sum -c -')==0,'MANIFEST_PIN');
let m=json(fs.readfile(kit+'/manifest.json'));
let owner=m.profile=='OWNER_MANUAL' && m.production_apply==true,vm=m.profile=='VM_ONLY' && m.production_apply==false;
require(m.format=='HG_OWNER_UPDATE_V1' && (owner || vm) &&
    m.baseline_commit==BASELINE && match(m.source_commit??'',/^[0-9a-f]{40}$/) && join(',',m.changed??[])==DELTA,'PACKAGE');
require(trim(fs.readfile('/proc/1/comm')??'')=='procd' && match(fs.readfile('/etc/openwrt_release')??'',/DISTRIB_RELEASE='25\.12\.5'/),'OPENWRT_RUNTIME');
require(command("busybox ash --help 2>&1 | grep -q 'BusyBox v1.37.0'")==0,'BUSYBOX_RUNTIME');
if(vm) require(read('/etc/hg-disposable-vm',0600,64)=='HG_NETWORKLESS_OPENWRT_VM_V1\n' && command('test "$(uname -m)" = x86_64')==0,'VM_ONLY');
else {
    let p=fs.popen('ubus -S call system board','r');require(p!=null,'BOARD');let raw=p.read(8193);require(p.close()==0 && type(raw)=='string' && length(raw)<=8192,'BOARD');
    let board=json(raw),mem=fs.readfile('/proc/meminfo')??'',total=match('\n'+mem,/\nMemTotal:[ \t]+([0-9]+) kB\n/),available=match('\n'+mem,/\nMemAvailable:[ \t]+([0-9]+) kB\n/);
    require(match(board.model??'',/^Cudy TR3000( 256MB)? v1$/) && board.release?.target=='mediatek/filogic' && total!=null && +total[1]>=450000 && +total[1]<=524288,'OWNER_HARDWARE');
    require(available!=null && +available[1]>=32768,'OWNER_MEMORY');
}
let expected=['baseline.sha256','candidate.sha256','update.sh','inspect.uc','owner.ps1','boot.init',
    ...map(PATHS,p=>'baseline/'+p),...map(PATHS,p=>'candidate/'+p)];
if(owner)push(expected,'acceptance.json');
require(type(m.files)=='array' && length(m.files)==length(expected),'INVENTORY');
let seen={},kit_hashes='';
for(let f in m.files) {
    require(index(expected,f.path)>=0 && !seen[f.path] && match(f.sha256??'',/^[0-9a-f]{64}$/) &&
        type(f.size)=='int' && f.size>=0 && f.size<=262144,'INVENTORY');seen[f.path]=true;
    let rel=replace(f.path,/^(baseline|candidate)\//,''),perm=index(PATHS,rel)>=0?(index(PATHS,rel)<3?0755:0644):(f.path=='boot.init'?0755:f.path=='update.sh'?0700:0600);
    require(f.mode==perm,'MODE');let s=checked(kit+'/'+f.path,'file',perm,262144);require(s.size==f.size,'SIZE');
    kit_hashes+=f.sha256+'  '+kit+'/'+f.path+'\n';
}
require(command('printf %s '+quote(kit_hashes)+' | sha256sum -c -')==0,'FILE_PIN');
function walk(path,prefix) {
    checked(path,'directory',0700,0);let names=fs.lsdir(path);require(names!=null && length(names)<=32,'DIRECTORY');
    for(let n in names) {let p=prefix?prefix+'/'+n:n;
        require(p=='manifest.json' || index(expected,p)>=0 || length(filter(expected,e=>index(e,p+'/')==0))>0,'UNKNOWN_FILE');
        if(fs.lstat(path+'/'+n)?.type=='directory')walk(path+'/'+n,p);
    }
}
walk(kit,'');
for(let name in ['baseline','candidate']) {
    require(type(m.inventories[name])=='object' && join(',',sort(keys(m.inventories[name])))==join(',',sort([...PATHS])),'RUNTIME_INVENTORY');
    let manifest='';
    for(let p in PATHS) {let digest=m.inventories[name][p];require(match(digest??'',/^[0-9a-f]{64}$/),'RUNTIME_PIN');
        require(length(filter(m.files,f=>f.path==name+'/'+p && f.sha256==digest))==1,'RUNTIME_BINDING');manifest+=digest+'  '+p+'\n';}
    require(read(kit+'/'+name+'.sha256',0600,8192)==manifest,'MANIFEST_BYTES');
}
require(join(',',filter(PATHS,p=>m.inventories.baseline[p]!=m.inventories.candidate[p]))==DELTA,'DELTA');
if(owner) {
    let a=json(read(kit+'/acceptance.json',0600,262144)),r=a.report;
    require(a.format=='HG_OWNER_UPDATE_ACCEPTANCE_V1' && a.commit==m.source_commit && a.ci_head==m.source_commit && a.review_head==m.source_commit && a.ci_conclusion=='success' && a.review_blockers==0 &&
        match(a.ci_url??'',/^https:\/\/github\.com\/bsekinaev\/cudy-home-gateway\/actions\/runs\/[0-9]+$/) && r?.commit==m.source_commit && r.status=='PASS' && r.failed==0 && r.scenario=='owner-update' && r.total==length(keys(r.checks??{})) && r.total>0 && length(filter(keys(r.checks),k=>r.checks[k]!='PASS'))==0,'OWNER_ACCEPTANCE');
}
if(operation=='kit') { print('OWNER_UPDATE_KIT=VERIFIED SOURCE='+m.source_commit+' PROFILE='+m.profile+'\n');exit(0); }
require(index(['baseline','candidate','mixed','journal','recovery','pending','workers'],operation)>=0,'OPERATION');
require(read('/etc/home-gateway-migration/phase',0600,32)=='COMMITTED\n','MIGRATION_PHASE');
require(type(m.controls)=='object' && length(keys(m.controls))==14,'CONTROL_INVENTORY');
let control_hashes='';
for(let p,digest in m.controls) {
    require(match(p,/^(usr\/libexec\/home-gateway-deploy\/[a-z-]+\.(sh|uc)|etc\/init.d\/home-gateway-[a-z-]+)$/) && match(digest,/^[0-9a-f]{64}$/),'CONTROL_PATH');
    checked('/'+p,'file',index(p,'etc/init.d/')==0?0755:(match(p,/\.uc$/)?0600:0700),262144);
    control_hashes+=digest+'  /'+p+'\n';
}
require(command('printf %s '+quote(control_hashes)+' | sha256sum -c -')==0,'CONTROL_DRIFT');
let boot='/etc/init.d/home-gateway-owner-update',boot_link='/etc/rc.d/S07home-gateway-owner-update';
function pending_boot(path) {
    let mode=fs.lstat(path)?.mode;require(mode==0600 || mode==0755,'PENDING_BOOT_MODE');
    let raw=read(path,mode,262144);require(substr(fs.readfile(kit+'/boot.init'),0,length(raw))==raw,'UNKNOWN_PENDING_BOOT');
}
if(fs.lstat(boot+'.new')!=null) {require(operation=='recovery' || operation=='mixed','PENDING_BOOT_CONTROL');pending_boot(boot+'.new');}
if(fs.lstat(boot)!=null) {
    checked(boot,'file',0755,262144);
    let digest=filter(m.files,f=>f.path=='boot.init')[0].sha256;
    require(command('printf %s '+quote(digest+'  '+boot+'\n')+' | sha256sum -c -')==0,'BOOT_CONTROL_PIN');
}
if(fs.lstat(boot_link)!=null) {checked(boot_link,'link',0777,0);require(fs.readlink(boot_link)=='../init.d/home-gateway-owner-update','BOOT_CONTROL_LINK');}
if(operation=='workers') {
    // Reuse the installed, baseline-pinned proof: both procd instances, exact
    // commands, root UID, respawn policy and stable non-zombie PID starttimes.
    let code='import { inspect_telegram } from "/usr/libexec/home-gateway-deploy/migration-service.uc"; inspect_telegram("",{assert_root:function(r){if(r!="")die("ROOT");}},"candidate");';
    require(command('/usr/bin/ucode -e '+quote(code))==0,'WORKERS');
    print('OWNER_UPDATE_WORKERS=PASS\n');exit(0);
}
function pending(path) {
    let mode=fs.lstat(path)?.mode;require(mode==0600 || mode==0644,'PENDING_MODE');
    let raw=read(path,mode,262144);
    require(length(filter(['baseline','candidate'],n=>substr(fs.readfile(kit+'/'+n+'/'+DELTA),0,length(raw))==raw))>0,'UNKNOWN_PENDING_RUNTIME');
}
if(operation=='pending') {pending('/'+DELTA+'.hg-owner-new');exit(0);}
if(operation=='journal' || operation=='recovery') {
    const J='/etc/home-gateway-owner-update',D='/etc/home-gateway-deploy';
    checked(J,'directory',0700,0);
    require(read(J+'/kit-pin',0600,65)==pin+'\n','JOURNAL_PACKAGE');
    let old=trim(read(J+'/old-latest',0600,40)),id=trim(read(J+'/new-id',0600,40));
    require(match(old,/^tx\.m[a-f0-9]{24}$/) && id=='tx.u'+substr(m.source_commit,0,24),'JOURNAL_IDENTITY');
    let phases=['PREPARED','QUARANTINING','QUARANTINED','APPLYING','CHECKING','COMMITTED','RESTORING','ROLLED_BACK'];
    function record(path,label) {
        let values=label=='active'?[id+'\n']:label=='latest'?[id+'\n',old+'\n']:map(phases,p=>p+'\n');
        let raw=read(path,0600,64);
        require(length(filter(values,v=>substr(v,0,length(raw))==raw))>0,'UNKNOWN_PENDING_RECORD');
    }
    require(match(read(J+'/lease',0600,128),/^[1-9][0-9]{0,9}:[0-9]+:[0-9]+:[0-9a-f-]{36}\n$/),'LEASE_EVIDENCE');
    let phase_raw=operation=='recovery' && fs.lstat(J+'/phase')==null?'PREPARED\n':read(J+'/phase',0600,32),phase=trim(phase_raw);
    require(phase_raw==phase+'\n','PHASE_BYTES');
    require(index(['PREPARED','QUARANTINING','QUARANTINED','APPLYING','CHECKING','COMMITTED','RESTORING','ROLLED_BACK'],phase)>=0,'JOURNAL_PHASE');
    let expected=['kit-pin','old-latest','new-id','phase','migration.sha256','anchor.sha256','lease'];
    if(operation=='recovery' && fs.lstat(J+'/phase')==null) {
        require(fs.lstat(J+'/phase.new')!=null,'MISSING_PHASE');expected=filter(expected,p=>p!='phase');
    }
    if(fs.lstat(J+'/phase.new')!=null) {require(operation=='recovery','PENDING_PHASE');record(J+'/phase.new','owner-phase');push(expected,'phase.new');}
    require(length(fs.lsdir(J))==length(expected) && length(filter(fs.lsdir(J),p=>index(expected,p)>=0))==length(expected),'JOURNAL_UNKNOWN');
    for(let p in ['migration.sha256','anchor.sha256']) {
        let raw=read(J+'/'+p,0600,131072),rows=split(raw,'\n');require(pop(rows)=='' && length(rows)>0 && length(rows)<512,'EVIDENCE');
        for(let row in rows)require(match(row,/^[0-9a-f]{64}  \/etc\/home-gateway-(migration|deploy)\/[A-Za-z0-9_./-]+$/) && !match(row,/(^|\/)\.\.($|\/)/),'EVIDENCE_PATH');
        let actual=[];
        function evidence_walk(path) {
            let st=fs.lstat(path);require(st!=null && st.uid==0 && st.gid==0,'EVIDENCE_METADATA');
            if(st.type=='file') {require(st.nlink==1,'EVIDENCE_LINK');push(actual,path);return;}
            require(st.type=='directory','EVIDENCE_TYPE');let names=fs.lsdir(path);require(names!=null && length(names)<128,'EVIDENCE_DIRECTORY');
            for(let n in names)evidence_walk(path+'/'+n);
        }
        evidence_walk(p=='migration.sha256'?'/etc/home-gateway-migration':D+'/'+old);
        require(join('\n',sort(actual))==join('\n',sort(map(rows,r=>substr(r,66)))),'EVIDENCE_UNKNOWN_FILE');
        require(command('sha256sum -c '+quote(J+'/'+p))==0,'HISTORICAL_EVIDENCE_DRIFT');
    }
    let tx=D+'/'+id;checked(tx,'directory',0700,0);
    for(let name in ['active','latest'])if(fs.lstat(D+'/'+name+'.new')!=null) {require(operation=='recovery','PENDING_POINTER');record(D+'/'+name+'.new',name);}
    require(read(tx+'/commit',0600,41)==m.source_commit+'\n' && read(tx+'/inventory-version',0600,16)=='HGDEPLOY2\n' && read(tx+'/was-running',0600,2)=='1\n','TX_IDENTITY');
    require(read(tx+'/backup.sha256',0600,8192)==fs.readfile(kit+'/baseline.sha256') &&
        read(tx+'/new.sha256',0600,8192)==fs.readfile(kit+'/candidate.sha256'),'TX_MANIFEST');
    for(let p in PATHS)checked(tx+'/backup/'+p,'file',index(PATHS,p)<3?0755:0644,262144);
    let required=['commit','inventory-version','was-running','backup.sha256','new.sha256','phase','preflight.log','postflight.log','service.log',...map(PATHS,p=>'backup/'+p)],actual=[];
    if(fs.lstat(tx+'/interrupted-poller')!=null) {pending(tx+'/interrupted-poller');push(required,'interrupted-poller');}
    for(let name in fs.lsdir(tx)) {
        if(match(name,/^interrupted-boot\.[1-8]$/)) {pending_boot(tx+'/'+name);push(required,name);}
        if(match(name,/^interrupted-poller\.[1-8]$/)) {pending(tx+'/'+name);push(required,name);}
        let saved=match(name,/^interrupted-record-(owner-phase|tx-phase|active|latest)\.[1-8]$/);
        if(saved) {record(tx+'/'+name,saved[1]);push(required,name);}
    }
    if(fs.lstat(tx+'/phase')==null) {require(operation=='recovery' && fs.lstat(tx+'/phase.new')!=null,'MISSING_TX_PHASE');required=filter(required,p=>p!='phase');}
    else {let raw=read(tx+'/phase',0600,32),p=trim(raw);require(raw==p+'\n' && index(phases,p)>=0,'TX_PHASE');}
    if(fs.lstat(tx+'/phase.new')!=null) {require(operation=='recovery','PENDING_TX_PHASE');record(tx+'/phase.new','tx-phase');push(required,'phase.new');}
    function tx_walk(path,prefix) {
        checked(path,'directory',0700,0);let names=fs.lsdir(path);require(names!=null && length(names)<=32,'TX_DIRECTORY');
        for(let n in names) {let p=prefix?prefix+'/'+n:n;
            require(index(required,p)>=0 || length(filter(required,r=>index(r,p+'/')==0))>0,'TX_UNKNOWN_FILE');
            if(fs.lstat(path+'/'+n)?.type=='directory')tx_walk(path+'/'+n,p);else {let mode=index(p,'interrupted-poller')==0 || index(p,'interrupted-boot')==0?fs.lstat(path+'/'+n)?.mode:index(p,'backup/')==0?(index(PATHS,substr(p,7))<3?0755:0644):0600;checked(path+'/'+n,'file',mode,262144);push(actual,p);}
        }
    }
    tx_walk(tx,'');require(length(actual)==length(required),'TX_INCOMPLETE');
    require(command('cd '+quote(tx+'/backup')+' && sha256sum -c ../backup.sha256')==0,'BACKUP_PIN');
    print('OWNER_UPDATE_JOURNAL=VERIFIED PHASE='+phase+'\n');exit(0);
}
let live_hashes='';
for(let p in PATHS) {
    checked('/'+p,'file',index(PATHS,p)<3?0755:0644,262144);
    if(operation=='mixed' && p==DELTA) {
        require(length(filter(['baseline','candidate'],n=>command('printf %s '+quote(m.inventories[n][p]+'  /'+p+'\n')+' | sha256sum -c -')==0))>0,'LIVE_DRIFT');
    } else live_hashes+=m.inventories[operation=='mixed'?'baseline':operation][p]+'  /'+p+'\n';
}
require(command('printf %s '+quote(live_hashes)+' | sha256sum -c -')==0,'LIVE_DRIFT');
let library=fs.lsdir('/usr/lib/home-gateway');
if(operation=='mixed' && fs.lstat('/'+DELTA+'.hg-owner-new')!=null) {
    pending('/'+DELTA+'.hg-owner-new');
    library=filter(library,n=>n!='telegram-poller.uc.hg-owner-new');
}
require(library!=null && length(library)==17 && length(filter(library,n=>index(PATHS,'usr/lib/home-gateway/'+n)>=0))==17,'UNKNOWN_RUNTIME');
print('OWNER_UPDATE_RUNTIME=VERIFIED IDENTITY='+operation+'\n');
