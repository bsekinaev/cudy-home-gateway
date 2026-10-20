# HGDEPLOY2 Delivery B — owner installer contract

This is the Delivery B implementation. A source checkout or a normal runtime
release archive is not an accepted migration installer. Only a published,
SHA256-pinned **B_OWNER_MANUAL** kit with exact-source acceptance may be used.
The default B_VM_ACCEPTANCE build refuses CUDY and requires the disposable x86
VM marker, procd PID1 and no physical network devices.

RC-A owner acceptance is PASS within ISOLATED_TMP at
26bf67104ce9d44ef6ba313964a32283c3c07cd4. Do not repeat it or delete the owner's
/tmp/hgdeploy2-rc-a.BIBaCJ or /tmp/hg-native-main.cPHJib labs.

## GO / NO-GO

Production apply is owner-executed only. Work must never SSH to or modify CUDY.
Before **Prepare**, have a working recovery access path available for the whole
window. Physical Ethernet availability alone is not verification of access.
The runner requires an explicit `-RecoveryPathConfirmed`; this is an owner
attestation, not an automated test or a claim that Ethernet was checked.

The owner-confirmed off-router sysupgrade backup SHA256 is
986ceab1b0ed4eb06df359adf5f333348f25d929d27d4aed456452c07259ef33.
Inclusion of three private Gateway files and archive integrity are PASS;
**actual restoration of that private archive is NOT_TESTED**. Do not upload it,
private configuration or credentials to GitHub.

A usable kit requires all production-root install/rollback, service lifecycle,
crash/reboot, overlay identity, exact-head CI and blocking review gates passed.
Do not replace a mismatch with a new pin. The trusted legacy receiver hashes
remain those of c921c2d, enforced by the native snapshot and read-only preflight.

## Changes during the window

Preflight writes only the uploaded private /tmp kit and reads the current setup.
Prepare creates the 0600 root-owned migration lock and 0700 durable migration
state, verifies/snapshots the original 18 runtime and three receiver files,
legacy transaction/backup/latest, the pinned 20+3 candidate and control closure.
It checkpoints three secrets privately, records procd intent, publishes the
verified control files and S08 recovery link, and quarantines original S95
Telegram autostart. It does not switch runtime or stop the running bot.

Apply installs the guarded Telegram init first, stops/certifies only the Gateway
Telegram procd service, checkpoints current offset/callback state, switches the
remaining pinned runtime/receiver files and HGDEPLOY2 anchor/latest, then starts
exactly two workers only if the original service ran. The parent FD8 lease spans
native children, rc.common start, postchecks and terminal admission. Commit is
published only after complete file, private-state and process verification.
Original Telegram boot enablement returns after terminal admission.

No PassWall2/Xray restart, UCI/nft/DNS/routing change, sysupgrade, production reboot
or bootstrap-over-install is part of this procedure. UNKNOWN route/egress is
not interpreted as permission to change VPN or routing.

## Owner stages (Windows PowerShell 5.1 or 7)

Use the immutable URL, source commit and SHA256 published with the accepted RC.
Verify the separate owner-b.ps1 SHA256 before executing it. Set the release's
literal values in this example; placeholders deliberately do not run:

```powershell
$rc = @{
    Target = 'root@192.168.1.1'
    BundleUrl = 'IMMUTABLE_RC_B_URL'
    BundleSha256 = 'PUBLISHED_BUNDLE_SHA256'
    SessionFile = "$PWD\rc-b-session.json"
}
.\owner-b.ps1 @rc -Stage Preflight
# Only after GO and a WORKING recovery path are confirmed by the owner:
.\owner-b.ps1 @rc -Stage Prepare -RecoveryPathConfirmed
.\owner-b.ps1 @rc -Stage Apply -RecoveryPathConfirmed
.\owner-b.ps1 @rc -Stage Verify
```

There is no All stage. Download, upload, package checking and Preflight never
run Apply. Preserve rc-b-session.json and the downloaded pinned archive on the
Windows machine. Never guess or adopt another transaction nonce.

## Explicit rollback and recovery

```powershell
.\owner-b.ps1 @rc -Stage Rollback
# If /tmp was lost after reboot or the uploaded kit is unavailable:
.\owner-b.ps1 @rc -Stage UploadRecovery
.\owner-b.ps1 @rc -Stage Rollback
```

Stop on any error; there is no automatic rollback or automatic apply retry.
A reboot invalidates prepared Apply admission. APPLYING cannot be replayed.
After lost SSH reconnect using the reserved recovery path, re-upload the SAME
pinned kit if necessary, and perform explicit rollback of the captured nonce.
S08 reconstructs the fence only; it never replays apply or restore. S95 remains
quarantined through interrupted rollback, so legacy init cannot autostart on a
mixed/unadmitted tree.

Rollback preflights runtime drift, snapshots, journal, latest and space before
service stop. A newer deployment, foreign fence, unknown/corrupt snapshot,
wrong metadata or unknown state refuses changes. Known interrupted phase writes
are preserved as evidence and permit explicit rollback only. PREPARING abort
certifies unchanged current HGDEPLOY1 without using partial snapshots to restore
files or fabricating a deployment inventory version.

Verified rollback restores the original 18 runtime files, trusted three receiver
files, original latest and legacy journal. It preserves live private data;
checkpoints NEVER overwrite a newer Telegram offset/callback or rewind private
receipts. Original procd running/stopped intent and boot enablement are restored.
The completion closure stays installed until ROLLED_BACK admission. Final cleanup
keeps the recovery init, state helper and S08 link, the private migration evidence
and the lock; these are deliberate deployment-state additions, not runtime files.
A fresh migration over this retained state is refused pending a separately
reviewed retirement procedure. Do not use bootstrap or delete state manually.

If no transaction was captured, metadata/snapshot validation fails, or the fence
is foreign: STOP. Preserve session and private evidence; do not change pins,
force admission, recursively delete test/state directories or use sysupgrade as
an untested shortcut. A pending Gate is not PASS. Owner LIVE installation and
private backup restoration remain separate acceptance evidence.

## RC-B 20261019.2: TR3000 memory correction

The model's 256MB suffix is NAND flash, not RAM. Cudy specifies 256 MB NAND
and 512 MB DDR3: https://www.cudy.com/ru-ru/products/tr3000-256mb-1-0 .
Owner Preflight evidence: MemTotal=496724 kB, MemFree=207192 kB,
MemAvailable=253116 kB; 20261019.1 refused before Prepare/Apply and did not
replace the working installation. That immutable release is unchanged.

Owner admission now accepts Linux MemTotal 450000..524288 kB for this 512 MiB
RAM class (reserved kernel memory is excluded from MemTotal). The model
allowlist, OpenWrt 25.12.5, BusyBox 1.37.0 and procd PID1 requirements remain;
owner hardware also requires mediatek/filogic. The Preflight MemAvailable
budget remains at least 32768 kB. Missing/malformed fields, other RAM classes,
models or targets refuse. No production input/environment override exists.

Use a NEW Windows directory/session for 20261019.2. Do not edit/reuse the
20261019.1 session, pins or uploaded kit. Preserve old evidence; no target
cleanup, force unlock or manual bypass is required for this Preflight failure.


## Retry after the accepted RC-B 20261019.2 rollback

Use only the newly published candidate and its pinned runner. Preserve the old
Windows directory/session unchanged. The new runner requires a separate session.
No manual journal/lock deletion, old Apply replay or bootstrap is permitted.

1. `-Stage RetireCheck -PreviousSessionFile <old rc-b-session.json>` uploads only
   the new kit to /tmp and performs a read-only check of the old ROLLED_BACK
   transaction. It checks the fixed old source/bundle/manifest identities, 18+3
   restored runtime/receiver, original journal/latest, private checkpoints,
   original Telegram intent and retained controls under FD8. It never restarts
   services or archives anything.
2. Review the PASS result and confirm a working recovery path. Explicit
   `-Stage Retire -PreviousSessionFile <old session> -RetirementConfirmed
   -RecoveryPathConfirmed` rechecks everything, owns the existing marker fence,
   atomically renames state to
   `/etc/home-gateway-migration.retired.<old transaction>`, fsyncs /etc, and
   retires only verified S08 and two retained control files. All original
   control bytes, runtime backups, journal and private checkpoints remain in
   the 0700 archive. The original empty guard inode is retained. No runtime,
   receiver, private file, latest, VPN or service is changed by retirement.
3. Run new Preflight, Prepare, Apply and Verify separately using the NEW session.
   Prepare uses a new kernel UUID. The old Apply remains permanently refused.
   Preflight/Prepare validate the complete archive and refuse incomplete
   retirement, current drift or a newer legacy deployment.

Retirement is resumable, not automatically replayed. After interrupted Retire,
keep both sessions. If /tmp was lost, use new `UploadRecovery`, then explicit
`RetireCheck` and `Retire` with the original PreviousSessionFile. The runner
never invokes Apply as recovery. It refuses unknown fences/partials/archives.
Unknown regular RAM locks are not deleted or adopted. Known interrupted
retirement publications are preserved as bounded interrupted evidence.

Owner production support is deliberately pinned to source 908dd3222b81992d9fee056bd015a1266a0ce8d7
and manifest 67b65f1ceabe1534ff74fba8f6c486e9d02bfce9a7e7999875bd11929df467a1.
A different historical candidate requires separate acceptance; do not repin it.
Owner bundle generation now additionally requires exact-source running-service
and retirement SIGKILL/reboot/fresh-install reports. A code commit or host test
alone does not authorize production retirement or installation.
