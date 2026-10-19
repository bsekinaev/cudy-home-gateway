"""Deterministic Delivery A: read-only production preflight + native isolated lab.

Host Python only. Production apply is deliberately unavailable in this package.
"""
import argparse
import base64
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts/deploy'))
from migration_lab import OLD, NEW, RECEIVERS, LEGACY_PINS, mode


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE)


def content(repo, ref):
    commit = git(repo, 'rev-parse', '--verify', '--end-of-options', ref+'^{commit}').decode().strip()
    files = {}
    def put(path, data, perm=0o600):
        if path in files or len(data)>262144 or b'\r' in data or b'\0' in data:
            raise ValueError('INVALID_SOURCE_FILE: '+path)
        files[path]=(perm,data)
    def source(path):
        return git(repo, 'show', commit+':'+path)
    runtime={}
    for row in git(repo,'ls-tree','-rz',commit,'--','src/').split(b'\0'):
        if not row: continue
        header,path=row.split(b'\t',1);perm,kind,oid=header.decode().split()
        rel=path.decode().removeprefix('src/')
        expected='100755' if rel in NEW[:3] else '100644'
        if kind!='blob' or perm!=expected: raise ValueError('RUNTIME_METADATA')
        runtime[rel]=oid
    if set(runtime) != set(NEW): raise ValueError('RUNTIME_INVENTORY')
    for rel in NEW:
        put('candidate/'+rel,source('src/'+rel),mode(rel))
    for name, rel in zip(('engine.sh','wrapper.sh','recovery.init'), RECEIVERS):
        put('candidate/'+rel,source('scripts/deploy/'+name),mode(rel))
    candidate=''.join(hashlib.sha256(files['candidate/'+p][1]).hexdigest()+'  '+p+'\n' for p in (*NEW,*RECEIVERS)).encode()
    put('candidate/migration.sha256',candidate)
    for name in ('migration-state.uc','migration-snapshot.uc','migration-candidate.uc',
                 'migration-runtime.uc','migration-handoff.uc','migration-coordinator.uc'):
        put('native/'+name,source('scripts/deploy/'+name))
    put('legacy-preflight.sh',source('scripts/deploy/legacy-preflight.sh'),0o700)
    for name in ('rc-a.sh','rc-a.uc','owner.ps1'):
        put(name,source('scripts/migration_rc/'+name),0o700 if name.endswith('.sh') else 0o600)
    put('README.md',source('docs/HGDEPLOY2_RC_A.md'))
    # This is explicitly synthetic; never copy installed production config.
    wire=[('HGDEPLOY1 '+'b'*40+'\n').encode()]
    for rel in OLD:
        data=(b'#!/bin/sh\ncase "$1" in running) exit 1;; *) exit 0;; esac\n'
              if rel.startswith('etc/init.d/') else b'// synthetic RC A fixture\n'
              if rel.endswith('.uc') else b'#!/bin/sh\nexit 0\n')
        put('fixture/'+rel,data,mode(rel))
        if rel.endswith('/common.sh'): data += b'# synthetic committed legacy update\n'
        wire += [f'{mode(rel):04o} {len(data)} {hashlib.sha256(data).hexdigest()}\n'.encode(),base64.b64encode(data)+b'\n']
    for name, rel in zip(('legacy-engine-18.sh','legacy-wrapper.sh','legacy-recovery.init'), RECEIVERS):
        data=source('scripts/deploy/fixtures/'+name)
        if hashlib.sha256(data).hexdigest()!=LEGACY_PINS[rel]: raise ValueError('TRUSTED_LEGACY_MISMATCH')
        put('fixture/'+rel,data,mode(rel))
    wire=b''.join(wire)+b'END\n';put('legacy.wire',wire)
    manifest=dict(format='HGDEPLOY2_RC_A_V1',delivery='A_ISOLATED_ONLY',production_apply=False,
                  source_commit=commit,candidate_manifest_sha256=hashlib.sha256(candidate).hexdigest(),
                  legacy_wire_sha256=hashlib.sha256(wire).hexdigest(),
                  files=[dict(path=p,mode=perm,uid=0,gid=0,size=len(data),sha256=hashlib.sha256(data).hexdigest())
                         for p,(perm,data) in sorted(files.items())])
    put('manifest.json',(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode())
    return commit,files,manifest


def build(repo,ref,output):
    commit,files,manifest=content(repo,ref)
    timestamp=int(git(repo,'show','-s','--format=%ct',commit))
    parents=set()
    for p in files:
        for parent in Path(p).parents:
            if str(parent)!='.': parents.add(str(parent))
    data=io.BytesIO()
    with gzip.GzipFile(fileobj=data,mode='wb',filename='',mtime=0) as gz:
        with tarfile.open(fileobj=gz,mode='w',format=tarfile.USTAR_FORMAT) as tar:
            for p in sorted(parents):
                info=tarfile.TarInfo(p+'/');info.type=tarfile.DIRTYPE;info.mode=0o700
                info.uid=info.gid=0;info.mtime=timestamp;tar.addfile(info)
            for p,(perm,raw) in sorted(files.items()):
                info=tarfile.TarInfo(p);info.mode=perm;info.size=len(raw);info.uid=info.gid=0;info.mtime=timestamp
                tar.addfile(info,io.BytesIO(raw))
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    path=output/f'cudy-hgdeploy2-rc-a-{commit}.tar.gz'
    if path.exists(): raise ValueError('OUTPUT_EXISTS')
    path.write_bytes(data.getvalue())
    path.with_suffix(path.suffix+'.sha256').write_text(hashlib.sha256(data.getvalue()).hexdigest()+'  '+path.name+'\n')
    (output/'manifest.json').write_bytes(files['manifest.json'][1])
    (output/'owner.ps1').write_bytes(files['owner.ps1'][1])
    return path


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ref',default='HEAD');p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();print(build(REPO,a.ref,a.output))
