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
require(m.format=='HG_OWNER_UPDATE_V1' && m.profile=='VM_ONLY' && m.production_apply==false &&
    m.baseline_commit==BASELINE && match(m.source_commit??'',/^[0-9a-f]{40}$/) && join(',',m.changed??[])==DELTA,'PACKAGE');
// No owner escape hatch. This prototype cannot execute on the production CUDY.
require(read('/etc/hg-disposable-vm',0600,64)=='HG_NETWORKLESS_OPENWRT_VM_V1\n' &&
    trim(fs.readfile('/proc/1/comm')??'')=='procd' && command('test "$(uname -m)" = x86_64')==0,'VM_ONLY');
let expected=['baseline.sha256','candidate.sha256','update.sh','inspect.uc','owner.ps1',
    ...map(PATHS,p=>'baseline/'+p),...map(PATHS,p=>'candidate/'+p)];
require(type(m.files)=='array' && length(m.files)==length(expected),'INVENTORY');
let seen={};
for(let f in m.files) {
    require(index(expected,f.path)>=0 && !seen[f.path] && match(f.sha256??'',/^[0-9a-f]{64}$/) &&
        type(f.size)=='int' && f.size>=0 && f.size<=262144,'INVENTORY');seen[f.path]=true;
    let rel=replace(f.path,/^(baseline|candidate)\//,''),perm=index(PATHS,rel)>=0?(index(PATHS,rel)<3?0755:0644):(f.path=='update.sh'?0700:0600);
    require(f.mode==perm,'MODE');let s=checked(kit+'/'+f.path,'file',perm,262144);require(s.size==f.size,'SIZE');
    require(command('printf '+quote(f.sha256+'  '+kit+'/'+f.path+'\n')+' | sha256sum -c -')==0,'FILE_PIN');
}
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
if(operation=='kit') { print('OWNER_UPDATE_KIT=VERIFIED SOURCE='+m.source_commit+' PROFILE=VM_ONLY\n');exit(0); }
require(index(['baseline','candidate','mixed','journal','pending'],operation)>=0,'OPERATION');
require(read('/etc/home-gateway-migration/phase',0600,32)=='COMMITTED\n','MIGRATION_PHASE');
require(type(m.controls)=='object' && length(keys(m.controls))==14,'CONTROL_INVENTORY');
for(let p,digest in m.controls) {
    require(match(p,/^(usr\/libexec\/home-gateway-deploy\/[a-z-]+\.(sh|uc)|etc\/init.d\/home-gateway-[a-z-]+)$/) && match(digest,/^[0-9a-f]{64}$/),'CONTROL_PATH');
    checked('/'+p,'file',index(p,'etc/init.d/')==0?0755:(match(p,/\.uc$/)?0600:0700),262144);
    require(command('printf '+quote(digest+'  /'+p+'\n')+' | sha256sum -c -')==0,'CONTROL_DRIFT');
}
function pending(path) {
    let raw=read(path,0644,262144);
    require(length(filter(['baseline','candidate'],n=>substr(fs.readfile(kit+'/'+n+'/'+DELTA),0,length(raw))==raw))>0,'UNKNOWN_PENDING_RUNTIME');
}
if(operation=='pending') {pending('/'+DELTA+'.hg-owner-new');exit(0);}
if(operation=='journal') {
    const J='/etc/home-gateway-owner-update',D='/etc/home-gateway-deploy';
    checked(J,'directory',0700,0);
    require(read(J+'/kit-pin',0600,65)==pin+'\n','JOURNAL_PACKAGE');
    let old=trim(read(J+'/old-latest',0600,40)),id=trim(read(J+'/new-id',0600,40));
    require(match(old,/^tx\.m[a-f0-9]{24}$/) && id=='tx.u'+substr(m.source_commit,0,24),'JOURNAL_IDENTITY');
    let phase=trim(read(J+'/phase',0600,32));
    require(index(['PREPARED','QUARANTINING','QUARANTINED','APPLYING','CHECKING','COMMITTED','RESTORING','ROLLED_BACK'],phase)>=0,'JOURNAL_PHASE');
    let expected=['kit-pin','old-latest','new-id','phase','migration.sha256','anchor.sha256','lease'];
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
    require(read(tx+'/commit',0600,41)==m.source_commit+'\n' && read(tx+'/inventory-version',0600,16)=='HGDEPLOY2\n' && read(tx+'/was-running',0600,2)=='1\n','TX_IDENTITY');
    require(read(tx+'/backup.sha256',0600,8192)==fs.readfile(kit+'/baseline.sha256') &&
        read(tx+'/new.sha256',0600,8192)==fs.readfile(kit+'/candidate.sha256'),'TX_MANIFEST');
    for(let p in PATHS)checked(tx+'/backup/'+p,'file',index(PATHS,p)<3?0755:0644,262144);
    let required=['commit','inventory-version','was-running','backup.sha256','new.sha256','phase','preflight.log','postflight.log','service.log',...map(PATHS,p=>'backup/'+p)],actual=[];
    if(fs.lstat(tx+'/interrupted-poller')!=null) {pending(tx+'/interrupted-poller');push(required,'interrupted-poller');}
    function tx_walk(path,prefix) {
        checked(path,'directory',0700,0);let names=fs.lsdir(path);require(names!=null && length(names)<=32,'TX_DIRECTORY');
        for(let n in names) {let p=prefix?prefix+'/'+n:n;
            require(index(required,p)>=0 || length(filter(required,r=>index(r,p+'/')==0))>0,'TX_UNKNOWN_FILE');
            if(fs.lstat(path+'/'+n)?.type=='directory')tx_walk(path+'/'+n,p);else {checked(path+'/'+n,'file',p=='interrupted-poller'?0644:index(p,'backup/')==0?(index(PATHS,substr(p,7))<3?0755:0644):0600,262144);push(actual,p);}
        }
    }
    tx_walk(tx,'');require(length(actual)==length(required),'TX_INCOMPLETE');
    require(command('cd '+quote(tx+'/backup')+' && sha256sum -c ../backup.sha256')==0,'BACKUP_PIN');
    print('OWNER_UPDATE_JOURNAL=VERIFIED PHASE='+phase+'\n');exit(0);
}
for(let p in PATHS) {
    checked('/'+p,'file',index(PATHS,p)<3?0755:0644,262144);
    let allowed=operation=='mixed' && p==DELTA?['baseline','candidate']:[operation=='mixed'?'baseline':operation];
    require(length(filter(allowed,n=>command('printf '+quote(m.inventories[n][p]+'  /'+p+'\n')+' | sha256sum -c -')==0))>0,'LIVE_DRIFT');
}
let library=fs.lsdir('/usr/lib/home-gateway');
require(library!=null && length(library)==17 && length(filter(library,n=>index(PATHS,'usr/lib/home-gateway/'+n)>=0))==17,'UNKNOWN_RUNTIME');
print('OWNER_UPDATE_RUNTIME=VERIFIED IDENTITY='+operation+'\n');
