// Delivery A: only a freshly marked /tmp namespace can be mutated.
import * as fs from 'fs';
import { open_state,open_rollback_state } from './native/migration-state.uc';
import { prepare_legacy_snapshot,snapshot_io } from './native/migration-snapshot.uc';
import { prepare_candidate_snapshot } from './native/migration-candidate.uc';
import { prepare_coordinator,apply_coordinator,rollback_coordinator } from './native/migration-coordinator.uc';
import { verify_handoff } from './native/migration-handoff.uc';
import { verify_runtime } from './native/migration-runtime.uc';
function require(ok,reason) { if(!ok)die('RC_A_REFUSED_'+reason); }
function quote(s) { return "'"+replace(s,"'","'\\''")+"'"; }
let kit=ARGV[0],op=ARGV[1],bb=ARGV[2],root=ARGV[3],top=fs.lstat(kit);
require(length(ARGV)==(op=='check'?3:4) && type(kit)=='string' && kit!='/' &&
    match(kit,/^\/[A-Za-z0-9_.\/-]+$/) && !match(kit,/(^|\/)\.\.?($|\/)/),'KIT_PATH');
require(top?.type=='directory' && top.mode==0700,'KIT_METADATA');
function checked(path,kind,mode,limit) {
    let st=fs.lstat(path);require(st?.type==kind && st.uid==top.uid && st.gid==top.gid && st.mode==mode,'METADATA');
    if(kind=='file')require(st.nlink==1 && st.size<=limit,'LINK_OR_SIZE');return st;
}
function read(path,mode,limit) {
    let st=checked(path,'file',mode,limit),f=fs.open(path,'re');require(f!=null,'READ');
    let held=fs.stat('/proc/self/fd/'+f.fileno());require(held?.inode==st.inode && held.dev.major==st.dev.major && held.dev.minor==st.dev.minor,'READ_CHANGED');
    let raw=f.read(limit+1);require(f.close()!=null && type(raw)=='string' && length(raw)==st.size && fs.lstat(path)?.inode==st.inode,'READ_CHANGED');return raw;
}
let m=json(read(kit+'/manifest.json',0600,65536));
require(m.format=='HGDEPLOY2_RC_A_V1' && m.delivery=='A_ISOLATED_ONLY' && m.production_apply==false &&
    match(m.source_commit,/^[0-9a-f]{40}$/) && type(m.files)=='array' && length(m.files)<128,'MANIFEST');
let records={},total=0;
for(let r in m.files) {
    require(type(r.path)=='string' && match(r.path,/^[A-Za-z0-9][A-Za-z0-9_.\/-]+$/) &&
        !match(r.path,/(^|\/)\.\.?($|\/)/) && records[r.path]==null && r.path!='manifest.json' &&
        r.uid==0 && r.gid==0 && type(r.mode)=='int' && (r.mode==0600 || r.mode==0644 || r.mode==0700 || r.mode==0755) &&
        type(r.size)=='int' && r.size>=0 && r.size<=262144 && match(r.sha256,/^[0-9a-f]{64}$/),'RECORD');
    records[r.path]=r;total+=r.size;
}
require(total<=8388608 && records['legacy.wire']?.sha256==m.legacy_wire_sha256 &&
    records['candidate/migration.sha256']?.sha256==m.candidate_manifest_sha256,'BUDGET_OR_BINDING');
let actual=[];
function walk(path,prefix,depth) {
    require(depth<=8,'DEPTH');checked(path,'directory',0700,0);
    let names=fs.lsdir(path);require(names!=null && length(names)<=128,'INVENTORY');
    for(let name in names) {
        let rel=prefix?prefix+'/'+name:name;
        if(fs.lstat(path+'/'+name)?.type=='directory') {
            require(length(filter(keys(records),p=>index(p,rel+'/')==0))>0,'EXTRA_DIRECTORY');walk(path+'/'+name,rel,depth+1);
        } else {
            require(rel=='manifest.json' || records[rel]!=null,'EXTRA_FILE');
            if(rel!='manifest.json') { let r=records[rel];require(checked(path+'/'+name,'file',r.mode,262144).size==r.size,'SIZE');push(actual,rel); }
        }
    }
}
walk(kit,'',0);require(length(actual)==length(m.files),'INVENTORY');
let hash=fs.popen('timeout -k 2 30 sha256sum '+join(' ',map(actual,p=>quote(kit+'/'+p)))+' 2>/dev/null','r');require(hash!=null,'HASH');
let rows=split(hash.read(65537),'\n');require(hash.close()==0 && pop(rows)=='' && length(rows)==length(actual),'HASH');
for(let i=0;i<length(actual);i++)require(rows[i]==records[actual[i]].sha256+'  '+kit+'/'+actual[i],'HASH_MISMATCH');
if(op=='check') { print('RC_A_PACKAGE=VERIFIED SOURCE='+m.source_commit+' PRODUCTION_APPLY=BLOCKED\n');exit(0); }
require(type(bb)=='string' && match(bb,/^\/[A-Za-z0-9_.\/-]+$/),'BUSYBOX');
require(type(root)=='string' && match(root,/^\/tmp\/hgdeploy2-rc-a\.[A-Za-z0-9]{6}$/),'ISOLATED_ROOT_ONLY');
checked(root,'directory',0700,0);
require(read(root+'/.hg-rc-a-lab',0600,64)=='HGDEPLOY2_RC_A_LAB_V1\n' &&
    read(root+'/.hg-deploy-test-root',0600,64)=='DISPOSABLE\n','LAB_MARKER');
if(op=='seed') {
    require(fs.lstat(root+'/etc')==null && fs.lstat(root+'/usr')==null,'NO_REPLAY');
    let p=fs.popen('cp -Rp '+quote(kit+'/fixture/.')+' '+quote(root+'/')+' >/dev/null 2>&1','r');require(p!=null && p.close()==0,'SEED');
    require(fs.writefile(root+'/.rc-a-source',m.source_commit+'\n')!=null && fs.chmod(root+'/.rc-a-source',0600),'SOURCE');exit(0);
}
require(read(root+'/.rc-a-source',0600,41)==m.source_commit+'\n','SOURCE');
let state=op=='prepare'?open_state(root,true,bb):op=='rollback'?open_rollback_state(root,bb):open_state(root,false,bb);
if(op=='prepare') {
    prepare_legacy_snapshot(root,state,bb);
    prepare_candidate_snapshot(root,state,bb,kit+'/candidate',m.candidate_manifest_sha256);
    prepare_coordinator(root,state,bb,m.source_commit,0);
} else if(op=='apply')apply_coordinator(root,state,bb);
else if(op=='verify') {
    require(state.phase()=='APPLYING','PHASE');verify_handoff(root,state,bb);
    let io=snapshot_io(root,state,bb),r=json(io.read(io.BASE+'/candidate.json',0600,16384));
    let paths=map(keys(r.files),p=>root+'/'+p),hashes=io.hashes(paths);
    for(let rel in keys(r.files)) { io.read(root+'/'+rel,r.files[rel].mode,262144);require(hashes[root+'/'+rel]==r.files[rel].sha256,'INSTALLED_HASH'); }
    require(length(fs.lsdir(root+'/usr/lib/home-gateway'))==17,'INSTALLED_INVENTORY');
    require(io.read(root+'/etc/home-gateway-deploy/latest',0600,40)==json(io.read(io.BASE+'/handoff.json',0600,16384)).id+'\n','LATEST');
} else if(op=='rollback') { rollback_coordinator(root,state,bb);verify_runtime(root,state,bb,false); }
else require(false,'OPERATION');
print('RC_A_STAGE='+op+' RESULT=PASS SCOPE=ISOLATED_TMP PHASE='+state.phase()+' PRODUCTION_APPLY=BLOCKED SERVICE_LIFECYCLE=NOT_TESTED\n');
state.close();
