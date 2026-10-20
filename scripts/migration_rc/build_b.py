"""Immutable Delivery B kit. Router code is native ash/ucode only.

Default VM profile cannot run on CUDY. Owner profile requires exact-source
production-root install/rollback and crash acceptance reports; no force flag.
"""
import argparse,hashlib,json,io,gzip,tarfile,re,sys
from pathlib import Path
import importlib.util
_spec=importlib.util.spec_from_file_location("hg_delivery_a",Path(__file__).with_name("build.py"))
delivery_a=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(delivery_a)
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'scripts/openwrt'))
import run_vm as vm_contract
MODULES=('state','snapshot','candidate','runtime','handoff','coordinator','controls','service','terminal')

def validate_acceptance(raw,commit,repo=REPO):
    report=json.loads(raw)
    if report.get('format')!='HG_DELIVERY_B_ACCEPTANCE_V1' or report.get('commit')!=commit:
        raise ValueError('ACCEPTANCE_SOURCE')
    if report.get('ci_head')!=commit or report.get('ci_conclusion')!='success' or report.get('review_blockers')!=0 or not re.fullmatch(r'https://github.com/bsekinaev/cudy-home-gateway/actions/runs/[0-9]+',report.get('ci_url','')):raise ValueError('ACCEPTANCE_CI_REVIEW')
    reports=report.get('reports',{})
    required={'rc-b-root-cycle','rc-b-crash-apply','rc-b-crash-restore','overlay-identity','service-cycle','retirement-reboot'}
    if set(reports)!=required:raise ValueError('ACCEPTANCE_SCENARIOS')
    for name,r in reports.items():
        checks=r.get('checks',{})
        script={'rc-b-root-cycle':'guest-rc-b.sh','rc-b-crash-apply':'guest-rc-b-crash-apply.sh','rc-b-crash-restore':'guest-rc-b-crash-restore.sh','overlay-identity':'guest-overlay.sh','service-cycle':'guest-service-cycle.sh','retirement-reboot':'guest-retirement.sh'}[name]
        expected={n.decode() for n in re.findall(rb'^\s*check ([a-z0-9_]+) ',delivery_a.git(repo,'show',commit+':scripts/openwrt/'+script),re.M)}
        if set(checks)!=expected or r.get('scenario')!=name or r.get('kernel_sha256')!=vm_contract.KERNEL_SHA or r.get('rootfs_sha256')!=vm_contract.ROOTFS_SHA or r.get('package_sha256')!=vm_contract.PACKAGE_SHA:raise ValueError('ACCEPTANCE_COMPLETENESS')
        if (r.get('commit')!=commit or r.get('status')!='PASS' or r.get('failed')!=0 or
            not checks or r.get('total')!=len(checks) or set(checks.values())!={'PASS'} or
            r.get('scope')!='ISOLATED_X86_NOT_CUDY' or r.get('network_devices')!=0):
            raise ValueError('ACCEPTANCE_FAILED: '+name)
        if (name.startswith('rc-b-') or name=='retirement-reboot') and checks.get('production_root_entrypoint')!='PASS':
            raise ValueError('ACCEPTANCE_ROOT')
        if name in ('rc-b-crash-apply','rc-b-crash-restore','overlay-identity','retirement-reboot') and r.get('reboot_mechanism')!='GUEST_REBOOT_SUPERVISED_COLD_BOOT':
            raise ValueError('ACCEPTANCE_REBOOT')
    return report

def content(repo,ref,profile='vm',acceptance=None):
    commit,old,_=delivery_a.content(repo,ref)
    files={p:v for p,v in old.items() if p.startswith(('candidate/','native/')) or p=='legacy-preflight.sh'}
    def source(p):return delivery_a.git(repo,'show',commit+':'+p)
    def put(path,raw,mode=0o600):
        if path in files or len(raw)>262144 or b'\0' in raw or b'\r' in raw:raise ValueError('SOURCE_FILE')
        files[path]=(mode,raw)
    put('native/migration-retirement.uc',source('scripts/deploy/migration-retirement.uc'))
    for n in ('controls','service','terminal'):put('native/migration-'+n+'.uc',source('scripts/deploy/migration-'+n+'.uc'))
    controls={}
    for n in MODULES:
        rel='usr/libexec/home-gateway-deploy/migration-'+n+'.uc';controls[rel]=0o600
        put('controls/'+rel,files['native/migration-'+n+'.uc'][1])
    controls['usr/libexec/home-gateway-deploy/migration-admission.sh']=0o700
    controls['etc/init.d/home-gateway-migration']=0o755
    for src,rel in [('migration-admission.sh','usr/libexec/home-gateway-deploy/migration-admission.sh'),('migration-boot.init','etc/init.d/home-gateway-migration')]:
        put('controls/'+rel,source('scripts/deploy/'+src),controls[rel])
    raw=''.join(hashlib.sha256(files['controls/'+p][1]).hexdigest()+'  '+p+'\n' for p in controls).encode()
    put('controls/controls.sha256',raw)
    for n in ('rc-b.sh','rc-b.uc','owner-b.ps1'):put(n,source('scripts/migration_rc/'+n),0o700 if n.endswith('.sh') else 0o600)
    put('README.md',source('docs/HGDEPLOY2_RC_B.md'))
    if profile=='owner':
        if acceptance is None:raise ValueError('OWNER_ACCEPTANCE_REQUIRED')
        validate_acceptance(acceptance,commit,repo);put('acceptance.json',acceptance)
    elif profile!='vm':raise ValueError('PROFILE')
    manifest=dict(format='HGDEPLOY2_RC_B_V1',delivery='B_OWNER_MANUAL' if profile=='owner' else 'B_VM_ACCEPTANCE',
        production_apply=profile=='owner',source_commit=commit,
        candidate_manifest_sha256=hashlib.sha256(files['candidate/migration.sha256'][1]).hexdigest(),
        controls_manifest_sha256=hashlib.sha256(raw).hexdigest(),legacy_pins=delivery_a.LEGACY_PINS,
        files=[dict(path=p,mode=perm,uid=0,gid=0,size=len(data),sha256=hashlib.sha256(data).hexdigest()) for p,(perm,data) in sorted(files.items())])
    put('manifest.json',(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode())
    return commit,files,manifest

def build(repo,ref,output,profile='vm',acceptance=None):
    commit,files,manifest=content(repo,ref,profile,acceptance)
    timestamp=int(delivery_a.git(repo,'show','-s','--format=%ct',commit))
    parents={str(d) for p in files for d in Path(p).parents if str(d)!='.'};buf=io.BytesIO()
    with gzip.GzipFile(fileobj=buf,mode='wb',filename='',mtime=0) as gz:
        with tarfile.open(fileobj=gz,mode='w',format=tarfile.USTAR_FORMAT) as tar:
            for p in sorted(parents):
                i=tarfile.TarInfo(p+'/');i.type=tarfile.DIRTYPE;i.mode=0o700;i.uid=i.gid=0;i.mtime=timestamp;tar.addfile(i)
            for p,(mode,raw) in sorted(files.items()):
                i=tarfile.TarInfo(p);i.mode=mode;i.size=len(raw);i.uid=i.gid=0;i.mtime=timestamp;tar.addfile(i,io.BytesIO(raw))
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    path=output/f'cudy-hgdeploy2-rc-b-{commit}.tar.gz'
    if path.exists():raise ValueError('OUTPUT_EXISTS')
    path.write_bytes(buf.getvalue());path.with_suffix(path.suffix+'.sha256').write_text(hashlib.sha256(buf.getvalue()).hexdigest()+'  '+path.name+'\n')
    for name in ('manifest.json','owner-b.ps1'):(output/name).write_bytes(files[name][1])
    return path
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ref',default='HEAD');p.add_argument('--output',type=Path,required=True)
    p.add_argument('--profile',choices=['vm','owner'],default='vm');p.add_argument('--acceptance-report',type=Path)
    a=p.parse_args();print(build(REPO,a.ref,a.output,a.profile,a.acceptance_report.read_bytes() if a.acceptance_report else None))
