// Single native file/journal coordinator, integrated under one held guard.
// Full production entrypoint remains blocked until service/boot controls pass.
import * as fs from 'fs';
import { snapshot_io,verify_legacy_snapshot } from './migration-snapshot.uc';
import { verify_candidate_snapshot } from './migration-candidate.uc';
import { prepare_runtime,apply_runtime,restore_runtime,preflight_restore_runtime,verify_runtime,verify_candidate_runtime } from './migration-runtime.uc';
import { prepare_handoff,verify_handoff,publish_handoff,restore_handoff,preflight_restore_handoff } from './migration-handoff.uc';
function require(ok,reason) { if(!ok)die('MIGRATION_COORDINATOR_'+reason); }
function plan(root,state,bb) {
    require(root!='','PRODUCTION_NOT_ACCEPTED');
    let io=snapshot_io(root,state,bb),old=verify_legacy_snapshot(root,state,bb),candidate=verify_candidate_snapshot(root,state,bb);
    require(fs.lstat(io.BASE+'/coordinator.json.new')==null && fs.lstat(io.BASE+'/coordinator.publish-pending')==null,'PARTIAL');
    let p=json(io.read(io.BASE+'/coordinator.json',0600,1024));
    require(type(p)=='object' && join(',',sort(keys(p)))=='commit,format,manifest_sha256,marker,was_running' &&
        p.format=='HG_NATIVE_COORDINATOR_V1' && p.marker==old.marker &&
        p.manifest_sha256==candidate.manifest_sha256 && match(p.commit,/^[0-9a-f]{40}$/) &&
        type(p.was_running)=='int' && (p.was_running==0 || p.was_running==1),'PLAN');
    return {io,p,old};
}
export function prepare_coordinator(root,state,bb,commit,was_running) {
    require(root!='' && state.phase()=='PREPARING' && match(commit,/^[0-9a-f]{40}$/) &&
        type(was_running)=='int' && (was_running==0 || was_running==1),'INPUT');
    let io=snapshot_io(root,state,bb),old=verify_legacy_snapshot(root,state,bb),candidate=verify_candidate_snapshot(root,state,bb),
        p={format:'HG_NATIVE_COORDINATOR_V1',marker:old.marker,manifest_sha256:candidate.manifest_sha256,commit,was_running};
    require(fs.lstat(io.BASE+'/coordinator.json')==null && fs.lstat(io.BASE+'/coordinator.publish-pending')==null,'NO_REPLAY');
    io.write(io.BASE+'/coordinator.json.new',sprintf('%J\n',p),0600);
    io.write(io.BASE+'/coordinator.publish-pending',old.marker,0600);
    require(fs.rename(io.BASE+'/coordinator.json.new',io.BASE+'/coordinator.json'),'PUBLISH');io.sync([io.BASE]);
    require(fs.unlink(io.BASE+'/coordinator.publish-pending'),'PUBLISH');io.sync([io.BASE]);
    prepare_runtime(root,state,bb);
    // A verified separate HGDEPLOY2 anchor exists BEFORE any live file changes.
    prepare_handoff(root,state,bb,commit,was_running);plan(root,state,bb);
};
export function apply_coordinator(root,state,bb) {
    require(state.phase()=='PREPARED','NO_REPLAY');plan(root,state,bb);verify_handoff(root,state,bb);
    apply_runtime(root,state,bb);publish_handoff(root,state,bb);verify_handoff(root,state,bb);
    // APPLYING remains fenced until service/control verification and admission.
};
function abort_preparing(root,state,bb) {
    verify_runtime(root,state,bb,false);
    state.recover_rollback_phase();
    let io=snapshot_io(root,state,bb),marker=io.read(io.BASE+'/marker',0600,128),path=io.BASE+'/coordinator.abort';
    if(fs.lstat(path)!=null) {
        let raw=io.read(path,0600,128);
        require(length(raw)<=length(marker) && raw==substr(marker,0,length(raw)),'UNKNOWN_ABORT');
        if(raw!=marker) { require(fs.unlink(path),'ABORT');io.sync([io.BASE]); }
    }
    if(fs.lstat(path)==null)io.write(path,marker,0600);
    if(state.phase()=='PREPARING')state.transition('PREPARED');
    if(state.phase()=='PREPARED')state.transition('RESTORING');
    require(state.phase()=='RESTORING','PHASE');verify_runtime(root,state,bb,false);
    // No live writes occurred; preserve partial private receipts for inspection.
}
export function rollback_coordinator(root,state,bb) {
    require(index(['PREPARING','PREPARED','APPLYING','COMMITTED','RESTORING'],state.phase())>=0,'PHASE');
    if(state.phase()=='PREPARING' || state.phase()=='PREPARED' || fs.lstat(root+'/etc/home-gateway-migration/coordinator.abort')!=null) {
        require(state.phase()!='APPLYING','PHASE');abort_preparing(root,state,bb);return;
    }
    let c=plan(root,state,bb);
    // Refuse live/pending drift before changing the published journal pointer.
    preflight_restore_runtime(root,state,bb);
    let partial=fs.lstat(c.io.BASE+'/handoff.publish-pending')!=null || fs.lstat(c.io.BASE+'/handoff.json.new')!=null;
    if(!partial && fs.lstat(c.io.BASE+'/handoff.json')!=null)preflight_restore_handoff(root,state,bb);
    if(state.phase()=='COMMITTED') { require(!partial,'COMMITTED_HANDOFF');verify_candidate_runtime(root,state,bb); }
    state.recover_rollback_phase();
    if(state.phase()=='COMMITTED')state.transition('RESTORING');
    if(fs.lstat(c.io.BASE+'/handoff.json')!=null && !partial)restore_handoff(root,state,bb);
    else {
        // A partial, unpublished private anchor is preserved, never adopted.
        // It cannot have changed latest or published a deployment transaction.
        let nonce=trim(substr(c.old.marker,22)),id='tx.m'+substr(replace(nonce,'-',''),0,24),deploy=root+'/etc/home-gateway-deploy';
        require(c.io.read(deploy+'/latest',0600,40)==c.old.latest && fs.lstat(deploy+'/'+id)==null &&
            fs.lstat(c.io.BASE+'/latest.pending')==null,'UNKNOWN_HANDOFF');
        if(fs.lstat(c.io.BASE+'/handoff.publish-pending')!=null) {
            let raw=c.io.read(c.io.BASE+'/handoff.publish-pending',0600,128);
            require(length(raw)<=length(c.old.marker) && raw==substr(c.old.marker,0,length(raw)),'UNKNOWN_HANDOFF');
        }
    }
    restore_runtime(root,state,bb);
    // RESTORING remains fenced until original service/control state is verified.
};
