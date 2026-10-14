// Native file publication/restore core. No admission or service execution.
// Production entrypoint is deliberately unavailable until boot/service guards
// and HGDEPLOY2 journal handoff are integrated and accepted together.
import * as fs from 'fs';
import { snapshot_io, verify_legacy_snapshot } from './migration-snapshot.uc';
import { verify_candidate_snapshot } from './migration-candidate.uc';

function require(ok, reason) { if (!ok) die('MIGRATION_RUNTIME_' + reason); }
function context(root, state, bb) {
    require(type(root)=='string' && root!='', 'COORDINATOR_NOT_ACCEPTED');
    let io=snapshot_io(root,state,bb), old=verify_legacy_snapshot(root,state,bb),
        candidate=verify_candidate_snapshot(root,state,bb), records={};
    for (let name in keys(old.files)) if (index(name,'runtime/')==0)
        records[substr(name,8)]=old.files[name];
    const added=['usr/lib/home-gateway/actions.uc','usr/lib/home-gateway/notifications.uc'];
    require(length(keys(records))==21 && length(keys(candidate.files))==23,'INVENTORY');
    function journal(require_latest=true) {
        let deploy=root+'/etc/home-gateway-deploy';
        require(fs.lstat(deploy+'/active')==null && fs.lstat(deploy+'/active.new')==null &&
            fs.lstat(deploy+'/latest.new')==null,'DEPLOYMENT_DRIFT');
        let latest=io.read(deploy+'/latest',0600,40);
        require(match(latest,/^tx\.[a-zA-Z0-9]{1,32}\n$/) && (!require_latest || latest==old.latest),'DEPLOYMENT_DRIFT');
        let tx=deploy+'/'+trim(old.latest), names=[];
        function walk(path,prefix) {
            io.checked(path,'directory',0700,0);
            let entries=fs.lsdir(path); require(entries!=null && length(entries)<=32,'JOURNAL');
            for(let n in entries) {
                let rel=prefix+'/'+n;
                require(length(filter(keys(old.files),k=>k==rel || index(k,rel+'/')==0))>0,'JOURNAL_DRIFT');
                if(fs.lstat(path+'/'+n)?.type=='directory') walk(path+'/'+n,rel);
                else push(names,rel);
            }
        }
        walk(tx,'journal');
        let expected=filter(keys(old.files),k=>index(k,'journal/')==0);
        require(length(names)==length(expected),'JOURNAL_DRIFT');
        let paths=map(expected,k=>tx+substr(k,7)), hashes=io.hashes(paths);
        for(let k in expected) {
            let p=tx+substr(k,7), r=old.files[k];
            io.read(p,r.mode,262144); require(hashes[p]==r.sha256,'JOURNAL_DRIFT');
        }
    }
    function file(rel, record) {
        let p=root+'/'+rel; io.read(p,record.mode,262144);
        require(io.hashes([p])[p]==record.sha256,'LIVE_DRIFT');
    }
    function inventory(newer) {
        let expected=filter(keys(newer?candidate.files:records),k=>index(k,'usr/lib/home-gateway/')==0),
            names=fs.lsdir(root+'/usr/lib/home-gateway');
        require(names!=null && length(names)==length(expected) &&
            length(filter(names,n=>index(expected,'usr/lib/home-gateway/'+n)>=0))==length(expected),'LIVE_INVENTORY');
    }
    function verify(newer) {
        journal(); inventory(newer);
        let r=newer?candidate.files:records;
        for(let rel in keys(r))file(rel,r[rel]);
        if(!newer)for(let rel in added)require(fs.lstat(root+'/'+rel)==null,'LIVE_INVENTORY');
    }
    function pending_dir() {
        let p=io.BASE+'/runtime-pending';
        if(fs.lstat(p)==null) {
            require(state.phase()=='PREPARING','PENDING_MISSING');
            require(fs.mkdir(p,0700),'MKDIR'); io.sync([io.BASE]);
            io.write(p+'/owner',old.marker,0600);
        }
        io.checked(p,'directory',0700,0);
        require(io.read(p+'/owner',0600,128)==old.marker,'PENDING_OWNER');
        let names=fs.lsdir(p); require(names!=null && length(names)<=24,'PENDING');
        return p;
    }
    function pending(rel) { return pending_dir()+'/'+replace(rel,'/','_'); }
    function publish(rel,record,source) {
        let p=root+'/'+rel, parent=replace(p,/\/[^/]+$/,''), a=fs.lstat(parent), b=fs.lstat(io.BASE);
        require(a?.type=='directory' && !(a.mode&022) && a.uid==b.uid && a.gid==b.gid &&
            a.dev.major==b.dev.major && a.dev.minor==b.dev.minor,'FILESYSTEM');
        let stage=pending(rel), raw=io.read(source,record.mode,262144);
        require(io.hashes([source])[source]==record.sha256,'SNAPSHOT_CHANGED');
        io.write(stage,raw,record.mode);
        require(io.hashes([stage])[stage]==record.sha256,'STAGE_HASH');
        require(fs.rename(stage,p),'RENAME'); io.sync([p,parent,io.BASE+'/runtime-pending']);
        file(rel,record);
    }
    return {io,old,candidate,records,added,journal,file,verify,pending_dir,pending,publish};
}

export function prepare_runtime(root,state,bb) {
    require(state.phase()=='PREPARING','NO_REPLAY');
    let c=context(root,state,bb); c.verify(false);
    let bytes=0; for(let rel in keys(c.candidate.files))bytes+=fs.lstat(c.io.BASE+'/candidate/'+rel).size;
    c.io.space(bytes); c.pending_dir(); c.verify(false); state.transition('PREPARED');
};
export function apply_runtime(root,state,bb) {
    require(state.phase()=='PREPARED','NO_REPLAY');
    let c=context(root,state,bb); c.verify(false);
    require(length(fs.lsdir(c.pending_dir()))==1 && fs.lsdir(c.pending_dir())[0]=='owner','PENDING');
    let bytes=0; for(let rel in keys(c.candidate.files))bytes+=fs.lstat(c.io.BASE+'/candidate/'+rel).size;
    c.io.space(bytes); state.transition('APPLYING');
    for(let rel in keys(c.candidate.files)) c.publish(rel,c.candidate.files[rel],c.io.BASE+'/candidate/'+rel);
    c.verify(true);
    // Leave APPLYING fenced: full service/journal coordinator owns commit.
};
export function verify_runtime(root,state,bb,newer) {
    require(type(newer)=='bool','SCOPE'); context(root,state,bb).verify(newer); return true;
};
function restore_preflight(root,c,check_journal) {
    c.journal(check_journal);
    // Refuse foreign live bytes before overwriting anything. A partial apply
    // can contain only exact old/new files, and added files may be absent.
    let names=fs.lsdir(root+'/usr/lib/home-gateway');
    require(names!=null && length(filter(names,n=>c.candidate.files['usr/lib/home-gateway/'+n]==null))==0,'LIVE_INVENTORY');
    for(let rel in keys(c.candidate.files)) {
        let p=root+'/'+rel, r=c.candidate.files[rel], st=fs.lstat(p);
        if(st==null) { require(index(c.added,rel)>=0,'LIVE_MISSING'); continue; }
        c.io.read(p,r.mode,262144); let h=c.io.hashes([p])[p];
        require(h==r.sha256 || h==c.records[rel]?.sha256,'LIVE_DRIFT');
    }
    let directory=c.pending_dir();
    for(let name in fs.lsdir(directory)) {
        if(name=='owner')continue;
        let rel=filter(keys(c.candidate.files),r=>replace(r,'/','_')==name);
        require(length(rel)==1,'UNKNOWN_PENDING'); rel=rel[0];
        let p=directory+'/'+name, r=c.candidate.files[rel], st=fs.lstat(p);
        require(st?.type=='file' && (st.mode&~r.mode)==0,'UNKNOWN_PENDING');
        let raw=c.io.read(p,st.mode,262144), source=c.io.BASE+'/candidate/'+rel, data=c.io.read(source,r.mode,262144);
        require(c.io.hashes([source])[source]==r.sha256,'SNAPSHOT_CHANGED');
        let valid=length(raw)<=length(data) && raw==substr(data,0,length(raw));
        if(!valid && c.records[rel]!=null) {
            source=c.io.BASE+'/old/runtime/'+rel;data=c.io.read(source,r.mode,262144);
            require(c.io.hashes([source])[source]==c.records[rel].sha256,'SNAPSHOT_CHANGED');
            valid=length(raw)<=length(data) && raw==substr(data,0,length(raw));
        }
        require(valid,'UNKNOWN_PENDING');
    }
    let largest=0;
    for(let rel in keys(c.records)) {
        let size=fs.lstat(c.io.BASE+'/old/runtime/'+rel).size;
        if(size>largest)largest=size;
    }
    c.io.space(largest);
    return directory;
}
export function preflight_restore_runtime(root,state,bb) {
    let c=context(root,state,bb);restore_preflight(root,c,false);return true;
};
export function restore_runtime(root,state,bb) {
    let phase=state.phase(); require(index(['PREPARED','APPLYING','RESTORING'],phase)>=0,'PHASE');
    let c=context(root,state,bb);
    let directory=restore_preflight(root,c,true);
    if(phase!='RESTORING')state.transition('RESTORING');
    for(let name in fs.lsdir(directory)) { if(name=='owner')continue; require(fs.unlink(directory+'/'+name),'UNLINK'); c.io.sync([directory]); }
    for(let rel in keys(c.records)) c.publish(rel,c.records[rel],c.io.BASE+'/old/runtime/'+rel);
    for(let rel in c.added) if(fs.lstat(root+'/'+rel)!=null) {
        c.file(rel,c.candidate.files[rel]); require(fs.unlink(root+'/'+rel),'UNLINK');
        c.io.sync([replace(root+'/'+rel,/\/[^/]+$/,'')]);
    }
    c.verify(false);
    // Leave RESTORING fenced until service/control restoration is verified.
};
