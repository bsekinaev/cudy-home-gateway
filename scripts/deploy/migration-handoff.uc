// Native HGDEPLOY2 journal anchor. Legacy journal remains byte-for-byte intact.
// This is a coordinator component, not a production installation entrypoint.
import * as fs from 'fs';
import { snapshot_io, verify_legacy_snapshot } from './migration-snapshot.uc';
import { verify_candidate_snapshot } from './migration-candidate.uc';
import { verify_runtime } from './migration-runtime.uc';
function require(ok, reason) { if(!ok)die('MIGRATION_HANDOFF_'+reason); }
function context(root,state,bb) {
    require(type(root)=='string' && root!='','COORDINATOR_NOT_ACCEPTED');
    let io=snapshot_io(root,state,bb), old=verify_legacy_snapshot(root,state,bb),
        candidate=verify_candidate_snapshot(root,state,bb);
    let marker=io.read(io.BASE+'/marker',0600,128), nonce=trim(substr(marker,22)),
        id='tx.m'+substr(replace(nonce,'-',''),0,24), deploy=root+'/etc/home-gateway-deploy';
    require(match(id,/^tx\.m[0-9a-f]{24}$/),'IDENTITY');
    io.checked(deploy,'directory',0700,0);
    require(fs.lstat(deploy+'/active')==null && fs.lstat(deploy+'/active.new')==null &&
        fs.lstat(deploy+'/latest.new')==null,'ACTIVE_OR_PENDING');
    return {io,old,candidate,marker,id,deploy,stage:io.BASE+'/handoff',live:deploy+'/'+id};
}
function verify(c) {
    require(fs.lstat(c.io.BASE+'/handoff.json.new')==null &&
        fs.lstat(c.io.BASE+'/handoff.publish-pending')==null,'PARTIAL');
    let r=json(c.io.read(c.io.BASE+'/handoff.json',0600,16384));
    require(type(r)=='object' && join(',',sort(keys(r)))=='commit,files,format,id,marker,was_running' &&
        r.format=='HG_NATIVE_HANDOFF_V1' && r.id==c.id && r.marker==c.marker &&
        match(r.commit,/^[0-9a-f]{40}$/) && (r.was_running==0 || r.was_running==1) &&
        type(r.files)=='object','RECEIPT');
    let staged=fs.lstat(c.stage)!=null, live=fs.lstat(c.live)!=null;
    require(staged!=live,'LOCATION'); let base=staged?c.stage:c.live;
    let runtime=filter(keys(c.candidate.files),p=>index(p,'usr/libexec/')!=0 && p!='etc/init.d/home-gateway-deploy-recover'),
        required=[...map(runtime,p=>'backup/'+p),'phase','commit','was-running','inventory-version',
            'new.sha256','backup.sha256','preflight.log','postflight.log','service.log'];
    require(length(runtime)==20 && length(keys(r.files))==length(required) &&
        length(filter(required,p=>r.files[p]!=null))==length(required),'INVENTORY');
    let actual=[];
    function walk(path,prefix) {
        c.io.checked(path,'directory',0700,0);
        let entries=fs.lsdir(path); require(entries!=null && length(entries)<=32,'INVENTORY');
        for(let name in entries) {
            let rel=prefix?prefix+'/'+name:name;
            require(length(filter(required,p=>p==rel || index(p,rel+'/')==0))>0,'INVENTORY');
            if(fs.lstat(path+'/'+name)?.type=='directory')walk(path+'/'+name,rel);
            else push(actual,rel);
        }
    }
    walk(base,''); require(length(actual)==length(required),'INVENTORY');
    let hashes=c.io.hashes(map(required,p=>base+'/'+p));
    for(let rel in required) {
        let record=r.files[rel], backup=index(rel,'backup/')==0,
            mode=backup?c.candidate.files[substr(rel,7)].mode:0600;
        require(type(record)=='object' && join(',',sort(keys(record)))=='mode,sha256' &&
            record.mode==mode && record.sha256==hashes[base+'/'+rel],'HASH');
        c.io.read(base+'/'+rel,mode,262144);
        if(backup)require(record.sha256==c.candidate.files[substr(rel,7)].sha256,'HASH');
    }
    require(c.io.read(base+'/phase',0600,32)=='COMMITTED\n' &&
        c.io.read(base+'/inventory-version',0600,16)=='HGDEPLOY2\n' &&
        c.io.read(base+'/commit',0600,41)==r.commit+'\n' &&
        c.io.read(base+'/was-running',0600,2)==r.was_running+'\n','JOURNAL');
    let manifest=join('',map(sort(runtime),p=>c.candidate.files[p].sha256+'  '+p+'\n'));
    require(c.io.read(base+'/new.sha256',0600,8192)==manifest &&
        c.io.read(base+'/backup.sha256',0600,8192)==manifest,'MANIFEST');
    return r;
}
function check_pending_pointer(c) {
    let pending=c.io.BASE+'/latest.pending';
    if(fs.lstat(pending)==null)return;
    let raw=c.io.read(pending,0600,40), known=[c.old.latest,c.id+'\n'];
    require(length(filter(known,p=>length(raw)<=length(p) && raw==substr(p,0,length(raw))))>0,'FOREIGN_PENDING');
}
function pointer(c,value) {
    check_pending_pointer(c);
    let pending=c.io.BASE+'/latest.pending';
    if(fs.lstat(pending)!=null) {
        let raw=c.io.read(pending,0600,40);
        if(raw!=value) { require(fs.unlink(pending),'POINTER'); c.io.sync([c.io.BASE]); }
    }
    if(fs.lstat(pending)==null)c.io.write(pending,value,0600);
    let a=fs.lstat(c.io.BASE),b=fs.lstat(c.deploy);
    require(a.dev.major==b.dev.major && a.dev.minor==b.dev.minor,'FILESYSTEM');
    require(fs.rename(pending,c.deploy+'/latest'),'POINTER'); c.io.sync([c.io.BASE,c.deploy]);
    require(c.io.read(c.deploy+'/latest',0600,40)==value,'POINTER');
}
export function prepare_handoff(root,state,bb,commit,was_running) {
    require(index(['PREPARED','APPLYING'],state.phase())>=0 && match(commit,/^[0-9a-f]{40}$/) &&
        (was_running==0 || was_running==1),'INPUT');
    verify_runtime(root,state,bb,state.phase()=='APPLYING'); let c=context(root,state,bb);
    require(fs.lstat(c.stage)==null && fs.lstat(c.live)==null &&
        fs.lstat(c.io.BASE+'/handoff.json')==null && fs.lstat(c.io.BASE+'/handoff.json.new')==null &&
        fs.lstat(c.io.BASE+'/handoff.publish-pending')==null,'PARTIAL');
    let files={}, runtime=filter(keys(c.candidate.files),p=>index(p,'usr/libexec/')!=0 && p!='etc/init.d/home-gateway-deploy-recover'),total=0;
    for(let rel in runtime)total+=fs.lstat(c.io.BASE+'/candidate/'+rel).size;
    c.io.space(total);
    function put(rel,raw,mode) { c.io.write(c.stage+'/'+rel,raw,mode); files[rel]={mode,sha256:c.io.hashes([c.stage+'/'+rel])[c.stage+'/'+rel]}; }
    for(let rel in runtime)put('backup/'+rel,c.io.read(c.io.BASE+'/candidate/'+rel,c.candidate.files[rel].mode,262144),c.candidate.files[rel].mode);
    let manifest=join('',map(sort(runtime),p=>c.candidate.files[p].sha256+'  '+p+'\n'));
    put('new.sha256',manifest,0600);put('backup.sha256',manifest,0600);
    put('phase','COMMITTED\n',0600);put('inventory-version','HGDEPLOY2\n',0600);
    put('commit',commit+'\n',0600);put('was-running',was_running+'\n',0600);
    for(let name in ['preflight.log','postflight.log','service.log'])put(name,'NATIVE_MIGRATION_ANCHOR\n',0600);
    let receipt={format:'HG_NATIVE_HANDOFF_V1',id:c.id,marker:c.marker,commit,was_running,files};
    c.io.write(c.io.BASE+'/handoff.json.new',sprintf('%J\n',receipt),0600);
    c.io.write(c.io.BASE+'/handoff.publish-pending',c.marker,0600);
    verify_runtime(root,state,bb,state.phase()=='APPLYING');
    require(fs.rename(c.io.BASE+'/handoff.json.new',c.io.BASE+'/handoff.json'),'PUBLISH');c.io.sync([c.io.BASE]);
    require(fs.unlink(c.io.BASE+'/handoff.publish-pending'),'PUBLISH');c.io.sync([c.io.BASE]);
    return verify(c);
};
export function publish_handoff(root,state,bb) {
    require(state.phase()=='APPLYING','PHASE'); let c=context(root,state,bb),r=verify(c);
    let latest=c.io.read(c.deploy+'/latest',0600,40);
    require(latest==c.old.latest || latest==c.id+'\n','NEW_DEPLOYMENT');
    check_pending_pointer(c);
    if(latest==c.old.latest) {
        verify_runtime(root,state,bb,true);
        if(fs.lstat(c.stage)!=null) {
            let a=fs.lstat(c.stage),b=fs.lstat(c.deploy);require(a.dev.major==b.dev.major && a.dev.minor==b.dev.minor,'FILESYSTEM');
            require(fs.rename(c.stage,c.live),'PUBLISH');c.io.sync([c.io.BASE,c.deploy]);
        }
        pointer(c,c.id+'\n');
    }
    if(fs.lstat(c.io.BASE+'/latest.pending')!=null)pointer(c,c.id+'\n');
    require(fs.lstat(c.stage)==null && fs.lstat(c.live)!=null,'LOCATION');return verify(c);
};
export function restore_handoff(root,state,bb) {
    require(index(['PREPARED','APPLYING','RESTORING'],state.phase())>=0,'PHASE');let c=context(root,state,bb);verify(c);
    let latest=c.io.read(c.deploy+'/latest',0600,40);require(latest==c.old.latest || latest==c.id+'\n','NEW_DEPLOYMENT');
    check_pending_pointer(c);
    if(latest!=c.old.latest || fs.lstat(c.io.BASE+'/latest.pending')!=null)pointer(c,c.old.latest);
    if(fs.lstat(c.live)!=null) {require(fs.rename(c.live,c.stage),'RESTORE');c.io.sync([c.deploy,c.io.BASE]);}
    verify(c);return true;
};

export function verify_handoff(root,state,bb) { return verify(context(root,state,bb)); };

export function preflight_restore_handoff(root,state,bb) { let c=context(root,state,bb);verify(c);let latest=c.io.read(c.deploy+'/latest',0600,40);require(latest==c.old.latest || latest==c.id+'\n','NEW_DEPLOYMENT');check_pending_pointer(c);if(state.phase()=='COMMITTED')require(latest==c.id+'\n' && fs.lstat(c.live)?.type=='directory','COMMITTED_HANDOFF');return true; };
