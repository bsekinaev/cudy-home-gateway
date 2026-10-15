// Terminal certification. Production is still blocked until full lifecycle integration.
import * as fs from 'fs';
import { prepare_coordinator,rollback_coordinator } from './migration-coordinator.uc';
import { snapshot_io,verify_legacy_snapshot } from './migration-snapshot.uc';
import { verify_candidate_snapshot } from './migration-candidate.uc';
import { verify_runtime,verify_candidate_runtime,apply_runtime,preflight_restore_runtime } from './migration-runtime.uc';
import { verify_handoff,publish_handoff,preflight_restore_handoff } from './migration-handoff.uc';
import { prepare_controls,verify_controls,verify_restored_controls,restore_controls } from './migration-controls.uc';
import { inspect_telegram,quiesce_telegram,capture_private_state,verify_private_state } from './migration-service.uc';
function require(ok,why) { if(!ok)die('MIGRATION_TERMINAL_'+why); }
function context(root,state,bb) {
    require(type(root)=='string' && root!='','PRODUCTION_NOT_ACCEPTED');
    let io=snapshot_io(root,state,bb),old=verify_legacy_snapshot(root,state,bb),candidate=verify_candidate_snapshot(root,state,bb);
    let p=json(io.read(io.BASE+'/coordinator.json',0600,1024));
    require(type(p)=='object' && join(',',sort(keys(p)))=='commit,format,manifest_sha256,marker,was_running' && p.format=='HG_NATIVE_COORDINATOR_V1' && p.marker==old.marker && p.manifest_sha256==candidate.manifest_sha256 &&
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
    require(h.commit==c.p.commit && h.was_running==c.p.was_running,'SERVICE_BINDING');
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
// File/service handoff stage. The owner shell holds FD8 across this native
// child, rc.common startup and terminal certification. No auto replay/restart.
export function apply_service_coordinator(root,state,bb) {
    require(root!='' && state.phase()=='PREPARED','PRODUCTION_NOT_ACCEPTED');
    let c=context(root,state,bb);verify_handoff(root,state,bb);verify_controls(root,state,bb);
    inspect_telegram(root,state,c.p.was_running?'legacy':'stopped');
    verify_private_state(root,state,bb,'prepare',true);
    apply_runtime(root,state,bb,function() {
        quiesce_telegram(root,state);
        capture_private_state(root,state,bb,'apply');
        verify_private_state(root,state,bb,'prepare',true);
    });
    publish_handoff(root,state,bb);let h=verify_handoff(root,state,bb);
    require(h.commit==c.p.commit && h.was_running==c.p.was_running,'SERVICE_BINDING');
    verify_private_state(root,state,bb,'apply',false);
    if(c.p.was_running) {
        let marker=c.io.read(c.io.BASE+'/marker',0600,128),lock=c.io.checked(root+'/etc/home-gateway-migration.lock','file',0600,0),
            ticket='HG_MIGRATION_SERVICE_CHECK_V1 '+trim(substr(marker,22))+' '+lock.inode+'\n';
        c.io.write(c.io.BASE+'/service-check.new',ticket,0600);
        require(fs.rename(c.io.BASE+'/service-check.new',c.io.BASE+'/service-check'),'SERVICE_TICKET');c.io.sync([c.io.BASE]);
    }
    return c.p.was_running;
};

export function commit_service_coordinator(root,state,bb) {
    verify_private_state(root,state,bb,'prepare',true);
    verify_private_state(root,state,bb,'apply',true);
    return commit_migration(root,state,bb);
};
export function rollback_service_coordinator(root,state,bb) {
    require(root!='' && index(['APPLYING','COMMITTED','RESTORING'],state.phase())>=0,'PRODUCTION_NOT_ACCEPTED');
    let c=context(root,state,bb);
    // Drift refusal precedes stop and any journal/runtime changes.
    preflight_restore_runtime(root,state,bb);preflight_restore_handoff(root,state,bb);
    verify_private_state(root,state,bb,'prepare',true);
    if(fs.lstat(c.io.BASE+'/private-apply.json')!=null)verify_private_state(root,state,bb,'apply',true);
    quiesce_telegram(root,state);
    if(fs.lstat(c.io.BASE+'/private-rollback.json')==null)capture_private_state(root,state,bb,'rollback');
    else verify_private_state(root,state,bb,'rollback',false);
    rollback_coordinator(root,state,bb);
    restore_controls(root,state,bb,true);
    verify_private_state(root,state,bb,'rollback',false);
    return c.p.was_running;
};
export function complete_service_rollback(root,state,bb) {
    verify_private_state(root,state,bb,'prepare',true);
    verify_private_state(root,state,bb,'rollback',true);
    return complete_rollback(root,state,bb,true);
};

export function prepare_service_coordinator(root,state,bb,source,pin,commit) {
    require(root!='' && state.phase()=='PREPARING','PRODUCTION_NOT_ACCEPTED');
    let initial=inspect_telegram(root,state,'initial');
    capture_private_state(root,state,bb,'prepare');
    prepare_controls(root,state,bb,source,pin);
    prepare_coordinator(root,state,bb,commit,length(initial.instances)?1:0);
};
