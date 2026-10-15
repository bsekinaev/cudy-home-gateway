// Terminal certification. Production is still blocked until full lifecycle integration.
import * as fs from 'fs';
import { snapshot_io,verify_legacy_snapshot } from './migration-snapshot.uc';
import { verify_candidate_snapshot } from './migration-candidate.uc';
import { verify_runtime,verify_candidate_runtime } from './migration-runtime.uc';
import { verify_handoff } from './migration-handoff.uc';
import { verify_controls,verify_restored_controls } from './migration-controls.uc';
import { inspect_telegram } from './migration-service.uc';
function require(ok,why) { if(!ok)die('MIGRATION_TERMINAL_'+why); }
function context(root,state,bb) {
    require(type(root)=='string' && root!='','PRODUCTION_NOT_ACCEPTED');
    let io=snapshot_io(root,state,bb),old=verify_legacy_snapshot(root,state,bb),candidate=verify_candidate_snapshot(root,state,bb);
    let p=json(io.read(io.BASE+'/coordinator.json',0600,1024));
    require(p.format=='HG_NATIVE_COORDINATOR_V1' && p.marker==old.marker && p.manifest_sha256==candidate.manifest_sha256 &&
        match(p.commit,/^[0-9a-f]{40}$/) && type(p.was_running)=='int' && (p.was_running==0 || p.was_running==1),'PLAN');
    let lock=io.checked(root+'/etc/home-gateway-migration.lock','file',0600,0),nonce=trim(substr(old.marker,22));
    function record(phase) { return 'HG_MIGRATION_ADMITTED_V2 '+phase+' '+nonce+' '+lock.inode+'\n'; }
    function publish(phase) {
        let pending=io.BASE+'/admission.new',final=io.BASE+'/admission',expected=record(phase),other=record('COMMITTED');
        // Refuse all unknown receipt bytes before advancing the durable phase.
        if(fs.lstat(final)!=null) { let raw=io.read(final,0600,128);require(raw==expected || (phase=='ROLLED_BACK' && raw==other),'UNKNOWN_ADMISSION'); }
        if(fs.lstat(pending)!=null) {
            let raw=io.read(pending,0600,128);
            require(length(raw)<=length(expected) && raw==substr(expected,0,length(raw)) ||
                (phase=='ROLLED_BACK' && length(raw)<=length(other) && raw==substr(other,0,length(raw))),'UNKNOWN_ADMISSION');
            let archive=null,duplicate=false;
            for(let i=0;i<8;i++) {
                let path=io.BASE+'/admission.interrupted'+(i?'.'+i:'');
                if(fs.lstat(path)==null) { if(archive==null)archive=path;continue; }
                let saved=io.read(path,0600,128);
                require(length(saved)<=length(expected) && saved==substr(expected,0,length(saved)) ||
                    length(saved)<=length(other) && saved==substr(other,0,length(saved)),'UNKNOWN_EVIDENCE');
                if(saved==raw)duplicate=true;
            }
            require(archive!=null || duplicate,'EVIDENCE_LIMIT');
            if(duplicate)require(fs.unlink(pending),'UNLINK');
            else require(fs.rename(pending,archive),'ARCHIVE');
            io.sync([io.BASE]);
        }
        if(state.phase()!=phase)state.transition(phase);
        if(fs.lstat(final)==null || io.read(final,0600,128)!=expected) {
            io.write(pending,expected,0600);require(fs.rename(pending,final),'PUBLISH');io.sync([io.BASE]);
        }
        require(io.read(final,0600,128)==expected,'ADMISSION');state.release();return phase;
    }
    return {io,p,publish};
}
export function commit_migration(root,state,bb) {
    require(index(['APPLYING','COMMITTED'],state.phase())>=0,'PHASE');let c=context(root,state,bb);
    verify_controls(root,state,bb);let h=verify_handoff(root,state,bb);verify_candidate_runtime(root,state,bb);
    require(c.io.read(root+'/etc/home-gateway-deploy/latest',0600,40)==h.id+'\n' && fs.lstat(root+'/etc/home-gateway-deploy/'+h.id)?.type=='directory','HANDOFF_NOT_PUBLISHED');
    inspect_telegram(root,state,c.p.was_running?'candidate':'stopped');
    return c.publish('COMMITTED');
};
export function complete_rollback(root,state,bb,keep_recovery) {
    require(keep_recovery==true,'RECOVERY_GUARD_REQUIRED');
    require(index(['RESTORING','ROLLED_BACK'],state.phase())>=0,'PHASE');let c=context(root,state,bb);
    verify_runtime(root,state,bb,false);verify_restored_controls(root,state,bb,keep_recovery);
    inspect_telegram(root,state,c.p.was_running?'legacy':'stopped');
    return c.publish('ROLLED_BACK');
};
