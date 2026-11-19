// Internal durable I/O for the series coordinator. Never a bot command surface.
'use strict';
import * as fs from 'fs';
import { open_protocol } from './protocol.uc';
function need(ok,why){if(!ok)die('OWNER_SERIES_STATE_'+why);}
function quote(s){return "'"+replace(s,"'","'\\''")+"'";}
function same(a,b){return a?.inode==b?.inode && a?.dev?.major==b?.dev?.major && a?.dev?.minor==b?.dev?.minor;}

export function valid_process_prefix(raw,boot) {
    if(type(raw)!='string' || length(raw)>128 || type(boot)!='string' ||
        !match(boot,/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/))return false;
    let header='HG_OWNER_PROCESS_V1 ';
    if(length(raw)<=length(header))return raw==substr(header,0,length(raw));
    let rest=substr(raw,length(header));if(substr(raw,0,length(header))!=header)return false;
    if(length(rest)<=36)return rest==substr(boot,0,length(rest));
    if(substr(rest,0,37)!=boot+' ')return false;rest=substr(rest,37);
    return rest=='' || match(rest,/^[1-9][0-9]{0,9}$/)!=null ||
        match(rest,/^[1-9][0-9]{0,9} [0-9]{0,20}$/)!=null ||
        match(rest,/^[1-9][0-9]{0,9} [0-9]{1,20}\n$/)!=null;
};

export function describe_operation(kind,id,m,selected,pin) {
    function opid(value){return type(value)=='string' && match(value,/^tx\.[0-9a-f]{32}$/)!=null;}
    function txid(value){return type(value)=='string' && match(value,/^tx\.[A-Za-z0-9]{1,32}$/)!=null;}
    function commit(value){return type(value)=='string' && match(value,/^[0-9a-f]{40}$/)!=null;}
    need(index(['APPLY','ROLLBACK'],kind)>=0 && opid(id) && type(pin)=='string' && match(pin,/^[0-9a-f]{64}$/),'IDENTITY');
    need(type(selected)=='object' && txid(selected.transaction) && commit(selected.source) &&
        (selected.generation=='V1' || opid(selected.generation)) && commit(m.source_commit) && commit(m.baseline_commit),'SELECTION');
    let apply=kind=='APPLY';
    need(selected.source==(apply?m.baseline_commit:m.source_commit),'BASELINE_MISMATCH');
    if(!apply)need(opid(selected.generation) && (selected.parent_generation=='V1' || opid(selected.parent_generation)) &&
        txid(selected.parent_transaction),'ROLLBACK_PARENT');
    return {format:'HG_OWNER_SERIES_OPERATION_V1',id,kind,kit_pin:pin,source_commit:m.source_commit,
        baseline_commit:m.baseline_commit,before_generation:selected.generation,before_transaction:selected.transaction,
        before_source:selected.source,after_generation:apply?id:selected.parent_generation,
        after_transaction:apply?id:selected.parent_transaction,after_source:apply?m.source_commit:m.baseline_commit};
};

export function validate_operation_intent(data,m,pin) {
    need(type(data)=='object' && type(data.before_latest)=='string' &&
        (data.before_latest=='V1' || match(data.before_latest,/^tx\.[0-9a-f]{32}$/)),'INTENT');
    let selected={generation:data.before_generation,transaction:data.before_transaction,source:data.before_source,
        parent_generation:data.after_generation,parent_transaction:data.after_transaction};
    let expected=describe_operation(data.kind,data.id,m,selected,pin);expected.before_latest=data.before_latest;
    need(join(',',sort(keys(data)))==join(',',sort(keys(expected))),'INTENT_FIELDS');
    for(let name in keys(expected))need(type(data[name])=='string' && data[name]==expected[name],'INTENT_VALUE');
    let original='tx.ud2039b6c62da3aa458f720af';
    need(data.before_generation=='V1'?data.before_transaction==original:data.before_generation==data.before_transaction,'INTENT_BEFORE');
    need(data.after_generation=='V1'?data.after_transaction==original:data.after_generation==data.after_transaction,'INTENT_AFTER');return true;
};

export function open_io(root) {
    root??='';open_protocol(root);let owner=root==''?0:fs.lstat(root).uid,group=root==''?0:fs.lstat(root).gid;
    function full(path) {
        need(type(path)=='string' && length(path)<=512 && match(path,/^\/[A-Za-z0-9_./-]+$/) &&
            index(path,'//')<0 && !match(path,/(^|\/)\.\.?($|\/)/) && substr(path,-1)!='/','PATH');
        return root+path;
    }
    function ancestors(path) {
        let actual=full(path),parts=split(actual,'/'),prefix='';
        for(let i=1;i<length(parts)-1;i++) {
            prefix+='/'+parts[i];let st=fs.lstat(prefix);
            need(st?.type=='directory' && (st.uid==0 || st.uid==owner) && (!(st.mode&022)||st.perm.sticky),'PARENT');
        }
    }
    function check(path,kind,mode,limit) {
        ancestors(path);let st=fs.lstat(full(path));
        need(st?.type==kind && st.uid==owner && st.gid==group && st.mode==mode,'METADATA');
        if(kind=='file')need(st.nlink==1 && st.size<=limit,'SIZE_OR_LINK');return st;
    }
    function read(path,mode,limit) {
        let before=check(path,'file',mode,limit),fd=fs.open(full(path),'re');need(fd!=null,'READ');
        let held=fs.stat('/proc/self/fd/'+fd.fileno());need(same(held,before),'READ_CHANGED');
        let data=fd.read(limit+1),closed=fd.close(),after=fs.lstat(full(path));
        need(closed!=null && type(data)=='string' && length(data)==before.size && same(after,before) &&
            after.size==before.size && after.mtime==before.mtime && after.mode==before.mode && after.nlink==1,'READ_CHANGED');return data;
    }
    function exists(path){return fs.lstat(full(path))!=null;}
    function hash(path,mode,limit) {
        let before=check(path,'file',mode,limit),actual=full(path);
        let process=fs.popen('/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -k 1 10 sha256sum '+quote(actual)+' 2>/dev/null','r');
        need(process!=null,'HASH');let raw=process.read(1025),rc=process.close(),after=check(path,'file',mode,limit);
        let match_hash=match(raw??'',/^([0-9a-f]{64})  /);
        need(rc==0 && match_hash!=null && raw==match_hash[1]+'  '+actual+'\n' && same(before,after) &&
            before.size==after.size && before.mtime==after.mtime,'HASH_CHANGED');return match_hash[1];
    }
    function mutable(path) {
        let operation=match(path,/^(\/etc\/home-gateway-owner-series\/generations\/tx\.[0-9a-f]{32})(\/|$)/);
        need(operation==null || fs.lstat(full(operation[1]+'/sealed'))==null,'SEALED');
    }
    function run(args) {
        let p=fs.popen('/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -k 2 30 '+
            join(' ',map(args,quote))+' >/dev/null 2>&1','r');need(p!=null,'PROCESS');return p.close()==0;
    }
    function sync(path) {
        need(run(['/bin/busybox','fsync',full(path)]),'FSYNC');
        let parent=replace(full(path),/\/[^/]+$/,'');
        need(run(['/bin/busybox','fsync',parent==''?'/':parent]),'FSYNC_DIRECTORY');
    }
    function mkdir(path) {
        mutable(path);let actual=full(path),parts=split(actual,'/'),prefix='';
        for(let i=1;i<length(parts);i++) {
            prefix+='/'+parts[i];let before=fs.lstat(prefix);
            if(before==null){need(fs.mkdir(prefix,0700),'MKDIR');need(run(['/bin/busybox','fsync',prefix,replace(prefix,/\/[^/]+$/,'')||'/']),'MKDIR_SYNC');}
            let st=fs.lstat(prefix);
            need(st?.type=='directory' && (st.uid==0 || st.uid==owner) && (!(st.mode&022)||st.perm.sticky),'PARENT');
        }
        check(path,'directory',0700,0);
    }
    function exclusive(path,data,mode) {
        mutable(path);ancestors(path);need(type(data)=='string' && length(data)<=2097152 && !exists(path),'EXCLUSIVE');
        need(index([0600,0644,0700,0755],mode)>=0,'MODE');
        let fd=fs.open(full(path),'wxe',mode);need(fd!=null && fs.chmod(full(path),mode),'OPEN');
        let ok=fd.write(data)==length(data) && fd.flush()!=null,closed=fd.close();
        need(ok && closed!=null,'WRITE');check(path,'file',mode,length(data));sync(path);
    }
    function atomic(path,data,mode) {
        mutable(path);ancestors(path);if(exists(path))check(path,'file',mode,2097152);
        need(!exists(path+'.new'),'PENDING');exclusive(path+'.new',data,mode);
        need(fs.rename(full(path+'.new'),full(path)),'RENAME');sync(path);
    }
    function copy(source,target,mode) {
        mutable(target);let source_stat=fs.lstat(full(source));need(source_stat?.type=='file','COPY_SOURCE');
        let data=read(source,source_stat.mode,262144);exclusive(target,data,mode);
    }
    function lock(path,create) {
        ancestors(path);let before=fs.lstat(full(path));
        if(before==null)need(create==true,'MISSING_LOCK');else check(path,'file',0600,0);
        let fd=fs.open(full(path),before==null?'axe':'re',0600);need(fd!=null,'LOCK_OPEN');
        if(before==null){need(fs.chmod(full(path),0600),'LOCK_MODE');sync(path);}
        let actual=check(path,'file',0600,0),held=fs.stat('/proc/self/fd/'+fd.fileno());
        need(same(actual,held) && fd.lock('xn')!=null,'BUSY');
        need(same(check(path,'file',0600,0),held),'LOCK_CHANGED');return fd;
    }
    function unlink(path) {
        mutable(path);ancestors(path);let st=fs.lstat(full(path));
        need(st!=null && st.uid==owner && st.gid==group && index(['file','link'],st.type)>=0 && st.nlink==1,'UNLINK');
        need(fs.unlink(full(path)),'UNLINK');need(run(['/bin/busybox','fsync',replace(full(path),/\/[^/]+$/,'')]),'UNLINK_SYNC');
    }
    function complete_prefix(path,data,mode) {
        mutable(path);need(type(data)=='string' && length(data)<=2097152,'PREFIX_VALUE');
        let actual=null;
        if(exists(path)) {actual=read(path,mode,2097152);need(actual==substr(data,0,length(actual)),'UNKNOWN_PREFIX');}
        if(exists(path+'.new')) {
            let pending=read(path+'.new',mode,2097152);need(pending==substr(data,0,length(pending)),'UNKNOWN_PREFIX');
            // The complete deterministic value retains every byte of this known
            // prefix. Unknown bytes are never removed or overwritten.
            unlink(path+'.new');
        }
        if(actual!=data)atomic(path,data,mode);
    }
    function rename(source,target,replace_existing) {
        mutable(source);mutable(target);ancestors(source);ancestors(target);
        need(fs.lstat(full(source))!=null && (replace_existing==true || !exists(target)),'RENAME_TARGET');
        need(fs.rename(full(source),full(target)),'RENAME');sync(target);
        need(run(['/bin/busybox','fsync',replace(full(source),/\/[^/]+$/,'')]),'RENAME_SOURCE_SYNC');
    }
    return {root,full,check,read,exists,hash,mkdir,exclusive,atomic,complete_prefix,copy,lock,unlink,rename,sync,run};
};
