// Pinned control package. No services, terminal admission or production entrypoint.
import * as fs from 'fs';
import { snapshot_io } from './migration-snapshot.uc';
import { verify_runtime } from './migration-runtime.uc';
const DIR='usr/libexec/home-gateway-deploy/';
const FILES={
    'etc/init.d/home-gateway-migration':0755,
    'usr/libexec/home-gateway-deploy/migration-state.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-snapshot.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-candidate.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-runtime.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-handoff.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-coordinator.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-controls.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-service.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-terminal.uc':0600,
    'usr/libexec/home-gateway-deploy/migration-admission.sh':0700,
};
const KEEP=['etc/init.d/home-gateway-migration','usr/libexec/home-gateway-deploy/migration-state.uc'];
const BOOT='etc/rc.d/S08home-gateway-migration', TARGET='../init.d/home-gateway-migration';
const TELEGRAM_BOOT='etc/rc.d/S95home-gateway-telegram', TELEGRAM_TARGET='../init.d/home-gateway-telegram';
function require(ok,why) { if(!ok)die('MIGRATION_CONTROLS_'+why); }
function context(root,state,bb) {
    // Remove only after the complete production coordinator is accepted.
    require(type(root)=='string' && (root!='' || (type(state.assert_delivery)=='function' && state.assert_delivery())),'PRODUCTION_NOT_ACCEPTED');
    let io=snapshot_io(root,state,bb);
    function parent(rel) {
        let p=replace(root+'/'+rel,/\/[^/]+$/,''),a=fs.lstat(p),b=fs.lstat(io.BASE);
        require(a?.type=='directory' && !(a.mode&022) && a.uid==b.uid && a.gid==b.gid &&
            a.dev.major==b.dev.major && a.dev.minor==b.dev.minor,'FILESYSTEM');
        io.checked(p,'directory',a.mode,0);return p;
    }
    function file(path,record) {
        io.read(path,record.mode,262144);require(io.hashes([path])[path]==record.sha256,'HASH');
    }
    function receipt() {
        let r=json(io.read(io.BASE+'/controls.json',0600,8192));
        require(r.format=='HG_MIGRATION_CONTROLS_V2' && (r.telegram_boot=='ABSENT' || r.telegram_boot==TELEGRAM_TARGET) && r.marker==io.read(io.BASE+'/marker',0600,128) &&
            join(',',sort(keys(r.files)))==join(',',sort(keys(FILES))) && r.boot==TARGET,'RECEIPT');
        for(let rel in keys(FILES)) {
            let rec=r.files[rel];require(rec.mode==FILES[rel] && rec.old=='ABSENT' && match(rec.sha256,/^[0-9a-f]{64}$/),'RECEIPT');
            file(io.BASE+'/controls/'+rel,rec);
        }
        require(fs.lstat(io.BASE+'/controls.json.new')==null,'PARTIAL_RECEIPT');
        return r;
    }
    function telegram_boot(r,allow_enabled) {
        parent(TELEGRAM_BOOT);let path=root+'/'+TELEGRAM_BOOT,st=fs.lstat(path);
        if(st==null)return;
        io.checked(path,'link',0777,0);
        require(st.nlink==1 && allow_enabled && r.telegram_boot==TELEGRAM_TARGET && fs.readlink(path)==TELEGRAM_TARGET,'TELEGRAM_BOOT');
    }
    function quarantine_intent(r) {
        let path=io.BASE+'/telegram-boot-quarantine',marker=io.read(io.BASE+'/marker',0600,128);
        if(fs.lstat(path)==null)return false;
        let raw=io.read(path,0600,128);
        require(length(raw)<=length(marker) && raw==substr(marker,0,length(raw)),'FOREIGN_QUARANTINE');
        return true;
    }
    function boot_preflight(r) {
        telegram_boot(r,true);
        let owned=quarantine_intent(r);
        require(r.telegram_boot=='ABSENT' || fs.lstat(root+'/'+TELEGRAM_BOOT)!=null || owned,'MISSING_ORIGINAL_TELEGRAM_BOOT');
        return owned;
    }
    function live(r,complete) {
        boot_preflight(r);
        telegram_boot(r,!complete || index(['COMMITTED','ROLLED_BACK'],state.phase())>=0);
        for(let rel in keys(FILES)) {
            parent(rel);
            if(fs.lstat(root+'/'+rel)!=null)file(root+'/'+rel,r.files[rel]);
            else require(!complete,'MISSING');
        }
        parent(BOOT);let st=fs.lstat(root+'/'+BOOT);
        if(st!=null) {
            io.checked(root+'/'+BOOT,'link',0777,0);
            require(st.nlink==1 && fs.readlink(root+'/'+BOOT)==TARGET,'BOOT_LINK');
        } else require(!complete,'MISSING_BOOT');
    }
    function pending(r) {
        let p=io.BASE+'/control-pending';io.checked(p,'directory',0700,0);
        let names=fs.lsdir(p);require(names!=null && length(names)<=length(keys(FILES)),'PENDING');
        for(let name in names) {
            let rel=replace(name,'_','/');
            // Do not infer paths from flattened names: match exact whitelist.
            let paths=filter(keys(FILES),k=>replace(k,'/','_')==name);
            require(length(paths)==1,'FOREIGN_PENDING');rel=paths[0];
            let raw=io.read(p+'/'+name,FILES[rel],262144),expected=io.read(io.BASE+'/controls/'+rel,FILES[rel],262144);
            require(length(raw)<=length(expected) && raw==substr(expected,0,length(raw)),'FOREIGN_PENDING');
        }
        return p;
    }
    return {io,parent,file,receipt,live,pending,telegram_boot,quarantine_intent,boot_preflight};
}
export function prepare_controls(root,state,bb,source,pin) {
    require(state.phase()=='PREPARING','PHASE');let c=context(root,state,bb),io=c.io;
    require(type(source)=='string' && match(source,/^\/[A-Za-z0-9_.\/-]+$/) && !match(source,/(^|\/)\.\.?($|\/)/) &&
        match(pin,/^[0-9a-f]{64}$/),'SOURCE');
    io.checked(source,'directory',0700,0);
    require(io.hashes([source+'/controls.sha256'])[source+'/controls.sha256']==pin,'PIN');
    let raw=io.read(source+'/controls.sha256',0600,8192),rows=split(raw,'\n'),records={},bytes=0,actual=[];
    require(pop(rows)=='' && length(rows)==length(keys(FILES)),'MANIFEST');
    for(let row in rows) {
        let rel=substr(row,66),sha=substr(row,0,64);
        require(FILES[rel]!=null && records[rel]==null && substr(row,64,2)=='  ' && match(sha,/^[0-9a-f]{64}$/),'MANIFEST');
        records[rel]={mode:FILES[rel],sha256:sha,old:'ABSENT'};
    }
    function walk(path,prefix,depth) {
        require(depth<=6,'DEPTH');io.checked(path,'directory',0700,0);
        let names=fs.lsdir(path);require(names!=null && length(names)<=32,'INVENTORY');
        for(let n in names) {
            let rel=prefix?prefix+'/'+n:n;
            if(fs.lstat(path+'/'+n)?.type=='directory') {
                require(length(filter(keys(FILES),p=>index(p,rel+'/')==0))>0,'EXTRA');walk(path+'/'+n,rel,depth+1);
            } else { require(rel=='controls.sha256' || FILES[rel]!=null,'EXTRA');push(actual,rel); }
        }
    }
    walk(source,'',0);require(length(actual)==length(keys(FILES))+1,'INVENTORY');
    for(let rel in keys(FILES)) {
        c.parent(rel);require(fs.lstat(root+'/'+rel)==null,'UNKNOWN_EXISTING_CONTROL');
        c.file(source+'/'+rel,records[rel]);bytes+=fs.lstat(source+'/'+rel).size;
    }
    c.parent(BOOT);require(fs.lstat(root+'/'+BOOT)==null,'UNKNOWN_BOOT');
    c.parent(TELEGRAM_BOOT);let tele='ABSENT',st=fs.lstat(root+'/'+TELEGRAM_BOOT);
    if(st!=null) {
        io.checked(root+'/'+TELEGRAM_BOOT,'link',0777,0);
        require(st.nlink==1 && fs.readlink(root+'/'+TELEGRAM_BOOT)==TELEGRAM_TARGET,'UNKNOWN_TELEGRAM_BOOT');tele=TELEGRAM_TARGET;
    }
    require(fs.lstat(io.BASE+'/controls')==null && fs.lstat(io.BASE+'/controls.json')==null,'NO_REPLAY');
    io.space(bytes);require(fs.mkdir(io.BASE+'/control-pending',0700),'PENDING');io.sync([io.BASE]);
    for(let rel in keys(FILES))io.write(io.BASE+'/controls/'+rel,io.read(source+'/'+rel,FILES[rel],262144),FILES[rel]);
    for(let rel in keys(FILES)) { c.file(source+'/'+rel,records[rel]);c.file(io.BASE+'/controls/'+rel,records[rel]);require(fs.lstat(root+'/'+rel)==null,'SOURCE_CHANGED'); }
    require(io.hashes([source+'/controls.sha256'])[source+'/controls.sha256']==pin && fs.lstat(root+'/'+BOOT)==null,'SOURCE_CHANGED');
    let receipt={format:'HG_MIGRATION_CONTROLS_V2',telegram_boot:tele,marker:io.read(io.BASE+'/marker',0600,128),files:records,boot:TARGET};
    io.write(io.BASE+'/controls.json.new',sprintf('%J\n',receipt),0600);
    require(fs.rename(io.BASE+'/controls.json.new',io.BASE+'/controls.json'),'PUBLISH');io.sync([io.BASE]);
    c.receipt();return receipt;
};
export function preflight_telegram_boot(root,state,bb) {
    let c=context(root,state,bb);c.boot_preflight(c.receipt());return true;
};
export function quarantine_telegram_boot(root,state,bb) {
    let c=context(root,state,bb),r=c.receipt();c.boot_preflight(r);
    let path=c.io.BASE+'/telegram-boot-quarantine',marker=c.io.read(c.io.BASE+'/marker',0600,128);
    if(fs.lstat(path)!=null && c.io.read(path,0600,128)!=marker) {
        require(fs.unlink(path),'QUARANTINE');c.io.sync([c.io.BASE]);
    }
    if(fs.lstat(path)==null)c.io.write(path,marker,0600);
    if(fs.lstat(root+'/'+TELEGRAM_BOOT)!=null) {require(fs.unlink(root+'/'+TELEGRAM_BOOT),'TELEGRAM_BOOT');c.io.sync([c.parent(TELEGRAM_BOOT)]);}
    c.telegram_boot(r,false);return true;
};
export function apply_controls(root,state,bb) {
    require(state.phase()=='PREPARED','PHASE');let c=context(root,state,bb),r=c.receipt(),p=c.pending(r);
    c.live(r,false);let bytes=0;for(let rel in keys(FILES))bytes+=fs.lstat(c.io.BASE+'/controls/'+rel).size;c.io.space(bytes);
    // Every drift/pending predicate has passed before any live publication.
    for(let n in fs.lsdir(p)) { require(fs.unlink(p+'/'+n),'CLEAN_PENDING');c.io.sync([p]); }
    for(let rel in keys(FILES)) {
        if(fs.lstat(root+'/'+rel)!=null)continue;
        let stage=p+'/'+replace(rel,'/','_');c.io.write(stage,c.io.read(c.io.BASE+'/controls/'+rel,FILES[rel],262144),FILES[rel]);
        c.file(stage,r.files[rel]);require(fs.rename(stage,root+'/'+rel),'RENAME');c.io.sync([c.parent(rel),p]);c.file(root+'/'+rel,r.files[rel]);
    }
    // Quarantine the old boot path first: a power cut must never expose
    // S08 together with the original unguarded S95 service.
    quarantine_telegram_boot(root,state,bb);
    if(fs.lstat(root+'/'+BOOT)==null) { require(fs.symlink(TARGET,root+'/'+BOOT),'BOOT_LINK');c.io.sync([c.parent(BOOT)]); }
    c.live(r,true);return true;
};
export function verify_controls(root,state,bb) { let c=context(root,state,bb);c.live(c.receipt(),true);return true; };
export function verify_restored_controls(root,state,bb,keep_recovery) {
    require(keep_recovery==null || type(keep_recovery)=='bool','RETENTION');
    let c=context(root,state,bb),r=c.receipt();c.pending(r);
    for(let rel in keys(FILES)) {
        if(keep_recovery && (state.phase()=='RESTORING' || index(KEEP,rel)>=0))c.file(root+'/'+rel,r.files[rel]);
        else if(keep_recovery && state.phase()=='ROLLED_BACK' && fs.lstat(root+'/'+rel)!=null)c.file(root+'/'+rel,r.files[rel]);
        else require(fs.lstat(root+'/'+rel)==null,'RESTORE');
    }
    if(keep_recovery) {
        let st=c.io.checked(root+'/'+BOOT,'link',0777,0);
        require(st.nlink==1 && fs.readlink(root+'/'+BOOT)==TARGET,'BOOT_LINK');
    } else require(fs.lstat(root+'/'+BOOT)==null,'RESTORE');
    c.telegram_boot(r,state.phase()=='ROLLED_BACK');
    return true;
};

export function restore_controls(root,state,bb,keep_recovery) {
    require(keep_recovery==null || type(keep_recovery)=='bool','RETENTION');
    require(index(['PREPARING','PREPARED','RESTORING'],state.phase())>=0,'PHASE');
    let c=context(root,state,bb),r=c.receipt(),p=c.pending(r);c.live(r,false);
    // Never remove boot protection while the runtime/journal is mixed or drifted.
    verify_runtime(root,state,bb,false);
    if(!keep_recovery && fs.lstat(root+'/'+BOOT)!=null) { require(fs.unlink(root+'/'+BOOT),'BOOT_UNLINK');c.io.sync([c.parent(BOOT)]); }
    for(let rel in keys(FILES))if(!keep_recovery && fs.lstat(root+'/'+rel)!=null) { require(fs.unlink(root+'/'+rel),'UNLINK');c.io.sync([c.parent(rel)]); }
    for(let n in fs.lsdir(p)) { require(fs.unlink(p+'/'+n),'PENDING_UNLINK');c.io.sync([p]); }
    return verify_restored_controls(root,state,bb,keep_recovery);
};

export function restore_telegram_boot(root,state,bb) {
    let c=context(root,state,bb),r=c.receipt(),phase=state.phase(),marker=c.io.read(c.io.BASE+'/marker',0600,128),
        lock=c.io.checked(root+'/etc/home-gateway-migration.lock','file',0600,0);
    require(index(['COMMITTED','ROLLED_BACK'],phase)>=0 && c.io.read(c.io.BASE+'/admission',0600,128)==
        'HG_MIGRATION_ADMITTED_V2 '+phase+' '+trim(substr(marker,22))+' '+lock.inode+'\n','ADMISSION');
    c.telegram_boot(r,true);
    if(r.telegram_boot==TELEGRAM_TARGET && fs.lstat(root+'/'+TELEGRAM_BOOT)==null) {
        require(fs.symlink(TELEGRAM_TARGET,root+'/'+TELEGRAM_BOOT),'TELEGRAM_BOOT');c.io.sync([c.parent(TELEGRAM_BOOT)]);
    }
    // Once original enablement is durable, absence is no longer owned.
    let intent=c.io.BASE+'/telegram-boot-quarantine';
    if(fs.lstat(intent)!=null) {c.quarantine_intent(r);require(fs.unlink(intent),'QUARANTINE');c.io.sync([c.io.BASE]);}
    return true;
};
export function finalize_restored_controls(root,state,bb) {
    require(state.phase()=='ROLLED_BACK','PHASE');
    verify_runtime(root,state,bb,false);verify_restored_controls(root,state,bb,true);
    restore_telegram_boot(root,state,bb);
    let c=context(root,state,bb),r=c.receipt();
    for(let rel in keys(FILES))if(index(KEEP,rel)<0 && fs.lstat(root+'/'+rel)!=null) {
        c.file(root+'/'+rel,r.files[rel]);require(fs.unlink(root+'/'+rel),'UNLINK');c.io.sync([c.parent(rel)]);
    }
    verify_restored_controls(root,state,bb,true);return true;
};

export function verify_unpublished_controls(root,state,bb) {
    require(index(['PREPARING','PREPARED','RESTORING','ROLLED_BACK'],state.phase())>=0,'PHASE');let c=context(root,state,bb);
    for(let rel in keys(FILES)) {c.parent(rel);require(fs.lstat(root+'/'+rel)==null,'PUBLISHED_DURING_PREPARING');}
    c.parent(BOOT);require(fs.lstat(root+'/'+BOOT)==null,'PUBLISHED_DURING_PREPARING');
    // Native prepare never changes this original enablement. Unknown links
    // still refuse; no partial control/private snapshot is consumed or erased.
    c.telegram_boot({telegram_boot:TELEGRAM_TARGET},true);return true;
};

export function verify_telegram_boot(root,state,bb,restored) {
    require(type(restored)=='bool','BOOT_SCOPE');let c=context(root,state,bb),r=c.receipt();c.telegram_boot(r,restored);
    require((fs.lstat(root+'/'+TELEGRAM_BOOT)!=null)==(restored && r.telegram_boot==TELEGRAM_TARGET),'BOOT_ENABLEMENT');return true;
};
export function verify_final_controls(root,state,bb) {
    require(state.phase()=='ROLLED_BACK','PHASE');verify_restored_controls(root,state,bb,true);
    for(let rel in keys(FILES))if(index(KEEP,rel)<0)require(fs.lstat(root+'/'+rel)==null,'CLEANUP_INCOMPLETE');
    verify_telegram_boot(root,state,bb,true);return true;
};
