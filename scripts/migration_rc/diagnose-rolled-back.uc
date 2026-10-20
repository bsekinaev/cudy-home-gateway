// Owner-executed READ-ONLY evidence probe. No service commands, locks or writes.
// This probes retained state; it cannot recreate an earlier APPLYING failure.
import * as fs from 'fs';
const BASE='/etc/home-gateway-migration', LOCK='/etc/home-gateway-migration.lock';
function bounded(path,limit) {
 let st=fs.lstat(path);
 if(st?.type!='file' || st.uid!=0 || st.gid!=0 || st.mode!=0600 || st.nlink!=1 || st.size>limit)return null;
 let f=fs.open(path,'re');if(f==null)return null;
 let raw=f.read(limit+1);f.close();return type(raw)=='string' && length(raw)==st.size?raw:null;
}
function emit(name,value) {print(name+'='+sprintf('%J',value)+'\n');}
let phase=bounded(BASE+'/phase',32);
if(phase!='ROLLED_BACK\n') {print('PROBE_REFUSED=EXPECTED_ROLLED_BACK\n');exit(73);}
emit('SCOPE','READ_ONLY_POST_ROLLBACK_NOT_APPLY_REPLAY');
let lock=fs.lstat(LOCK),base=fs.lstat(BASE),held=fs.stat('/proc/self/fd/8');
emit('FD8_PRESENT',held!=null);
emit('FD8_IDENTITY',held!=null && held.inode==lock?.inode && held.dev.major==lock.dev.major && held.dev.minor==lock.dev.minor);
emit('GUARD_SAME_FILESYSTEM',lock!=null && base!=null && lock.dev.major==base.dev.major && lock.dev.minor==base.dev.minor);
for(let path in [LOCK,BASE,BASE+'/marker',BASE+'/phase',BASE+'/admission',BASE+'/service-check',BASE+'/fence',BASE+'/fence/marker','/tmp/home-gateway-deploy.lock',BASE+'/coordinator.json',BASE+'/handoff.json',BASE+'/candidate/migration.sha256',BASE+'/phase.new',BASE+'/admission.new',BASE+'/service-check.new',BASE+'/latest.pending',BASE+'/handoff',BASE+'/handoff.publish-pending']) {
 let s=fs.lstat(path);
 emit(path,s==null?null:{type:s.type,uid:s.uid,gid:s.gid,mode:s.mode,nlink:s.nlink,size:s.size,inode:s.inode,dev:s.dev});
}
let marker=bounded(BASE+'/marker',128),nonce=null;
if(type(marker)=='string' && match(marker,/^HG_MIGRATION_STATE_V1 [0-9a-f-]{36}\n$/))nonce=trim(substr(marker,22));
emit('OWNER_TRANSACTION_MATCH',nonce=='38bd5771-7472-45e7-8e2f-e4a37f7948ab');
emit('ROLLED_BACK_ADMISSION_MATCH',nonce!=null && bounded(BASE+'/admission',128)=='HG_MIGRATION_ADMITTED_V2 ROLLED_BACK '+nonce+' '+lock?.inode+'\n');
emit('RETAINED_SERVICE_TICKET_MATCH',nonce!=null && bounded(BASE+'/service-check',128)=='HG_MIGRATION_SERVICE_CHECK_V1 '+nonce+' '+lock?.inode+'\n');
for(let name in ['coordinator.json','handoff.json']) {
 let raw=bounded(BASE+'/'+name,16384),rec=null;
 try {if(raw!=null)rec=json(raw);}catch(e) {}
 emit(name+'_BINDING',{valid_object:type(rec)=='object',marker_matches:marker!=null && rec?.marker==marker,source_matches:rec?.commit=='908dd3222b81992d9fee056bd015a1266a0ce8d7',was_running:rec?.was_running==1?1:rec?.was_running==0?0:null});
}
emit('HISTORICAL_REJECTING_ASSERTION','UNKNOWN_REQUIRES_ADDITIONAL_EVIDENCE');
