// Terminal certification. Production is still blocked until full lifecycle integration.
import * as fs from 'fs';
import { prepare_coordinator,rollback_coordinator } from './migration-coordinator.uc';
import { snapshot_io,verify_legacy_snapshot,verify_current_legacy } from './migration-snapshot.uc';
import { verify_candidate_snapshot } from './migration-candidate.uc';
import { verify_runtime,verify_candidate_runtime,apply_runtime,preflight_restore_runtime } from './migration-runtime.uc';
import { verify_handoff,publish_handoff,preflight_restore_handoff } from './migration-handoff.uc';
import { prepare_controls,apply_controls,verify_controls,verify_restored_controls,restore_controls,quarantine_telegram_boot,restore_telegram_boot,finalize_restored_controls,verify_unpublished_controls,preflight_telegram_boot } from './migration-controls.uc';
import { inspect_telegram,quiesce_telegram,capture_private_state,verify_private_state,private_live_state } from './migration-service.uc';
function require(ok,why) { if(!ok)die('MIGRATION_TERMINAL_'+why); }
function readonly_state(state,root) { return {...state,read_only:true,fence:function() {state.assert_root(root);}}; }
function publisher(root,state,io,marker) {
    let lock=io.checked(root+'/etc/home-gateway-migration.lock','file',0600,0),nonce=trim(substr(marker,22));
    function record(phase) { return 'HG_MIGRATION_ADMITTED_V2 '+phase+' '+nonce+' '+lock.inode+'\n'; }
    function publish(phase,read_only) {
        require(read_only==null || read_only==true,'PUBLICATION_SCOPE');
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
            if(!read_only) {
                if(duplicate)require(fs.unlink(pending),'UNLINK');
                else require(fs.rename(pending,archive),'ARCHIVE');
                io.sync([io.BASE]);
            }
        }
        if(read_only)return true;
        if(state.phase()!=phase)state.transition(phase);
        if(fs.lstat(final)==null || io.read(final,0600,128)!=expected) {
            io.write(pending,expected,0600);require(fs.rename(pending,final),'PUBLISH');io.sync([io.BASE]);
        }
        require(io.read(final,0600,128)==expected,'ADMISSION');state.release();return phase;
    }
    return publish;
}
function context(root,state,bb) {
    require(type(root)=='string' && (root!='' || (type(state.assert_delivery)=='function' && state.assert_delivery())),'PRODUCTION_NOT_ACCEPTED');
    let io=snapshot_io(root,state,bb),old=verify_legacy_snapshot(root,state,bb),candidate=verify_candidate_snapshot(root,state,bb);
    require(fs.lstat(io.BASE+'/coordinator.json.new')==null && fs.lstat(io.BASE+'/coordinator.publish-pending')==null,'PARTIAL_PLAN');
    let p=json(io.read(io.BASE+'/coordinator.json',0600,1024));
    require(type(p)=='object' && join(',',sort(keys(p)))=='commit,format,manifest_sha256,marker,was_running' && p.format=='HG_NATIVE_COORDINATOR_V1' && p.marker==old.marker && p.manifest_sha256==candidate.manifest_sha256 &&
        match(p.commit,/^[0-9a-f]{40}$/) && type(p.was_running)=='int' && (p.was_running==0 || p.was_running==1),'PLAN');
    return {io,p,publish:publisher(root,state,io,old.marker)};
}
export function commit_migration(root,state,bb) {
    require(index(['APPLYING','COMMITTED'],state.phase())>=0,'PHASE');let checked=state.phase()=='COMMITTED'?readonly_state(state,root):state,c=context(root,checked,bb);
    verify_controls(root,checked,bb);let h=verify_handoff(root,checked,bb);verify_candidate_runtime(root,checked,bb);
    require(h.commit==c.p.commit && h.was_running==c.p.was_running,'SERVICE_BINDING');
    require(c.io.read(root+'/etc/home-gateway-deploy/latest',0600,40)==h.id+'\n' && fs.lstat(root+'/etc/home-gateway-deploy/'+h.id)?.type=='directory','HANDOFF_NOT_PUBLISHED');
    inspect_telegram(root,checked,c.p.was_running?'candidate':'stopped');state.fence();
    let phase=c.publish('COMMITTED');restore_telegram_boot(root,state,bb);state.release();return phase;
};
export function complete_rollback(root,state,bb,keep_recovery) {
    require(keep_recovery==true,'RECOVERY_GUARD_REQUIRED');
    require(index(['RESTORING','ROLLED_BACK'],state.phase())>=0,'PHASE');let checked=state.phase()=='ROLLED_BACK'?readonly_state(state,root):state,c=context(root,checked,bb);
    verify_runtime(root,checked,bb,false);verify_restored_controls(root,checked,bb,keep_recovery);
    inspect_telegram(root,checked,c.p.was_running?'legacy':'stopped');state.fence();
    let phase=c.publish('ROLLED_BACK');finalize_restored_controls(root,state,bb);state.release();return phase;
};
// File/service handoff stage. The owner shell holds FD8 across this native
// child, rc.common startup and terminal certification. No auto replay/restart.
export function apply_service_coordinator(root,state,bb) {
    require((root!='' || (type(state.assert_delivery)=='function' && state.assert_delivery())) && state.phase()=='PREPARED','PRODUCTION_NOT_ACCEPTED');
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
    let checked=state.phase()=='COMMITTED'?readonly_state(state,root):state;
    verify_private_state(root,checked,bb,'prepare',true);
    verify_private_state(root,checked,bb,'apply',true);
    return commit_migration(root,state,bb);
};
export function rollback_service_coordinator(root,state,bb) {
    require((root!='' || (type(state.assert_delivery)=='function' && state.assert_delivery())) && index(['PREPARED','APPLYING','COMMITTED','RESTORING'],state.phase())>=0,'PRODUCTION_NOT_ACCEPTED');
    let checked=readonly_state(state,root),c=context(root,checked,bb);
    // Drift refusal precedes stop and any journal/runtime changes.
    if(state.phase()=='PREPARED')verify_runtime(root,checked,bb,false);
    else {preflight_restore_runtime(root,checked,bb);preflight_restore_handoff(root,checked,bb);}
    if(state.phase()=='COMMITTED')verify_candidate_runtime(root,checked,bb);
    if(state.phase()!='PREPARED')verify_controls(root,checked,bb);
    preflight_telegram_boot(root,checked,bb);
    state.preflight_rollback_phase();c.publish('ROLLED_BACK',true);
    verify_private_state(root,checked,bb,'prepare',true);
    if(fs.lstat(c.io.BASE+'/private-apply.json')!=null)verify_private_state(root,checked,bb,'apply',true);
    state.fence();
    if(state.phase()=='PREPARED')apply_controls(root,state,bb);
    quarantine_telegram_boot(root,state,bb);state.fence();
    state.recover_rollback_phase();
    if(state.phase()=='COMMITTED')state.transition('RESTORING');
    quiesce_telegram(root,state);
    let private_before=private_live_state(root,state,bb);
    if(fs.lstat(c.io.BASE+'/private-rollback.json')==null)capture_private_state(root,state,bb,'rollback');
    else verify_private_state(root,state,bb,'rollback',true);
    rollback_coordinator(root,state,bb);
    restore_controls(root,state,bb,true);
    verify_private_state(root,state,bb,'rollback',true);
    require(sprintf('%J',private_before)==sprintf('%J',private_live_state(root,state,bb)),'PRIVATE_CHANGED_DURING_ROLLBACK');
    return c.p.was_running;
};
export function complete_service_rollback(root,state,bb) {
    let checked=state.phase()=='ROLLED_BACK'?readonly_state(state,root):state;
    verify_private_state(root,checked,bb,'prepare',true);
    verify_private_state(root,checked,bb,'rollback',true);
    return complete_rollback(root,state,bb,true);
};

export function prepare_service_coordinator(root,state,bb,source,pin,commit) {
    require((root!='' || (type(state.assert_delivery)=='function' && state.assert_delivery())) && state.phase()=='PREPARING','PRODUCTION_NOT_ACCEPTED');
    let initial=inspect_telegram(root,state,'initial');
    capture_private_state(root,state,bb,'prepare');
    prepare_controls(root,state,bb,source,pin);
    prepare_coordinator(root,state,bb,commit,length(initial.instances)?1:0);
};

// An interrupted PREPARING operation cannot have published controls/runtime
// or stopped a service. Certify the old tree directly; never adopt/replay its
// partial private checkpoints or invent a coordinator plan to authorize apply.
function verify_abort_baseline(root,state,bb) {
    let current=verify_current_legacy(root,state,bb),base=root+'/etc/home-gateway-migration';
    if(fs.lstat(base+'/snapshot.json')!=null) {
        let old=verify_legacy_snapshot(root,state,bb,true);
        require(current.latest==old.latest && join(',',sort(keys(current.files)))==join(',',sort(keys(old.files))),'ABORT_BASELINE');
        for(let rel in keys(old.files))require(current.files[rel].sha256==old.files[rel].sha256 && current.files[rel].mode==old.files[rel].mode,'ABORT_BASELINE');
    }
    return current;
}
export function abort_service_preparation(root,state,bb) {
    require((root!='' || (type(state.assert_delivery)=='function' && state.assert_delivery())) && index(['PREPARING','PREPARED','RESTORING'],state.phase())>=0,'PRODUCTION_NOT_ACCEPTED');
    let checked=readonly_state(state,root);
    verify_abort_baseline(root,checked,bb);verify_unpublished_controls(root,checked,bb);
    inspect_telegram(root,checked,'initial');
    let io=snapshot_io(root,checked,bb),marker=io.read(io.BASE+'/marker',0600,128),path=io.BASE+'/preparation-abort';
    require(index(['PREPARING','PREPARED'],state.phase())>=0 || fs.lstat(path)!=null,'UNKNOWN_ABORT');
    if(fs.lstat(path)!=null) {
        let raw=io.read(path,0600,128);
        require(length(raw)<=length(marker) && raw==substr(marker,0,length(raw)),'UNKNOWN_ABORT');
    }
    state.preflight_rollback_phase();publisher(root,state,io,marker)('ROLLED_BACK',true);
    state.fence();state.recover_rollback_phase();
    if(fs.lstat(path)!=null && io.read(path,0600,128)!=marker) {require(fs.unlink(path),'ABORT');io.sync([io.BASE]);}
    if(fs.lstat(path)==null)io.write(path,marker,0600);
    if(state.phase()=='PREPARING')state.transition('PREPARED');
    if(state.phase()=='PREPARED')state.transition('RESTORING');
    return 'RESTORING';
};
export function complete_preparation_abort(root,state,bb) {
    require((root!='' || (type(state.assert_delivery)=='function' && state.assert_delivery())) && index(['RESTORING','ROLLED_BACK'],state.phase())>=0,'PRODUCTION_NOT_ACCEPTED');
    let checked=readonly_state(state,root),io=snapshot_io(root,checked,bb),marker=io.read(io.BASE+'/marker',0600,128);
    require(io.read(io.BASE+'/preparation-abort',0600,128)==marker,'UNKNOWN_ABORT');
    verify_abort_baseline(root,checked,bb);verify_unpublished_controls(root,checked,bb);inspect_telegram(root,checked,'initial');
    state.fence();return publisher(root,state,io,marker)('ROLLED_BACK');
};

export function verify_preparation_abort(root,state,bb) {
    require(state.phase()=='ROLLED_BACK','PHASE');let checked=readonly_state(state,root),io=snapshot_io(root,checked,bb);
    require(io.read(io.BASE+'/preparation-abort',0600,128)==io.read(io.BASE+'/marker',0600,128),'UNKNOWN_ABORT');
    verify_abort_baseline(root,checked,bb);verify_unpublished_controls(root,checked,bb);inspect_telegram(root,checked,'initial');return true;
};

// Explicit completion after a terminal-phase power cut. Certify the restored
// tree before restarting the old worker; never replay apply or restore bytes.
export function resume_service_rollback(root,state,bb) {
    require(state.phase()=='ROLLED_BACK','PHASE');let checked=readonly_state(state,root),c=context(root,checked,bb);
    verify_runtime(root,checked,bb,false);verify_restored_controls(root,checked,bb,true);
    verify_private_state(root,checked,bb,'prepare',true);verify_private_state(root,checked,bb,'rollback',true);
    preflight_telegram_boot(root,checked,bb);c.publish('ROLLED_BACK',true);
    let current=inspect_telegram(root,checked,'initial');
    require(c.p.was_running || length(current.instances)==0,'SERVICE_INTENT');
    state.fence();quarantine_telegram_boot(root,state,bb);
    return c.p.was_running && length(current.instances)==0;
};
