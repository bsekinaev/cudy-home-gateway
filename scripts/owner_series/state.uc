// Internal durable I/O for the series coordinator. Never a bot command surface.
import * as fs from 'fs';
import { open_protocol } from './protocol.uc';
function need(ok,why){if(!ok)die('OWNER_SERIES_STATE_'+why);}
function quote(s){return "'"+replace(s,"'","'\\''")+"'";}
function same(a,b){return a?.inode==b?.inode && a?.dev?.major==b?.dev?.major && a?.dev?.minor==b?.dev?.minor;}

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
    function rename(source,target,replace_existing) {
        mutable(source);mutable(target);ancestors(source);ancestors(target);
        need(fs.lstat(full(source))!=null && (replace_existing==true || !exists(target)),'RENAME_TARGET');
        need(fs.rename(full(source),full(target)),'RENAME');sync(target);
        need(run(['/bin/busybox','fsync',replace(full(source),/\/[^/]+$/,'')]),'RENAME_SOURCE_SYNC');
    }
    return {root,full,check,read,exists,hash,mkdir,exclusive,atomic,copy,lock,unlink,rename,sync,run};
};
