# HGDEPLOY2 RC-B 20261020.2 — owner installation

Source: `62592457237e7f026786c086d1ca6fdd4b6c095d`. Exact-head CI: [39490486354](https://github.com/bsekinaev/cudy-home-gateway/actions/runs/39490486354).

This candidate fixes the ASATA diagnostic rejection of a valid rule behind a proven-safe prefix. It accepts the exact UDP return rule at position 15 only when preceding rules are harmless returns or have a proven nonmatching first predicate. Unknown/intercepting prefixes still fail closed. No nft changes or repair are performed. It provides explicit retirement of the verified RC-B 20261020.1 ROLLED_BACK transaction and never replays its Apply. Keep the old Windows session, old immutable packages, router snapshots, and all owner test labs.

## Downloads and identity

- [Installer bundle](https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/fc6a4c7ffb39bcc7b33ad81ff058664d38f5f356/artifacts/hgdeploy2-rc-b-20261020.2/cudy-hgdeploy2-rc-b-62592457237e7f026786c086d1ca6fdd4b6c095d.tar.gz), SHA256 `599ebe1d46e644bea3465b336ee74b61f5fb802569dd2c17d9bb82cf0603ef42`.
- [owner-b.ps1](https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/fc6a4c7ffb39bcc7b33ad81ff058664d38f5f356/artifacts/hgdeploy2-rc-b-20261020.2/owner-b.ps1), SHA256 `9b2b0ddf2cedf7d59492b94e14e5294d9d4877c02be1456f5ca8eb70947a14ca`.
- [Complete package manifest](https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/fc6a4c7ffb39bcc7b33ad81ff058664d38f5f356/artifacts/hgdeploy2-rc-b-20261020.2/manifest.json): file hashes, UID/GID, modes; includes candidate 20 runtime, 3 receiver and 11 controls.
- [Acceptance report](https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/fc6a4c7ffb39bcc7b33ad81ff058664d38f5f356/artifacts/hgdeploy2-rc-b-20261020.2/acceptance.json): actual exact-source OpenWrt VM reports, CI and review evidence.

- [Installed-file inventory](https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/fc6a4c7ffb39bcc7b33ad81ff058664d38f5f356/artifacts/hgdeploy2-rc-b-20261020.2/install-manifest.json): exact paths, SHA256, UID/GID and octal modes for all 20 runtime + 3 receiver + 11 controls.

## First step: read-only retirement check

Run in Windows PowerShell 5.1 or PowerShell 7. The runner uploads a private kit to /tmp and reads/verifies the restored installation. It does not retire the transaction, prepare a new one, stop Telegram, or apply runtime changes.

```powershell
$ErrorActionPreference = 'Stop'
$Dir = Join-Path $env:USERPROFILE 'CUDY-RC-B-20261020.2'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Set-Location $Dir
Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/fc6a4c7ffb39bcc7b33ad81ff058664d38f5f356/artifacts/hgdeploy2-rc-b-20261020.2/owner-b.ps1' -OutFile '.\owner-b.ps1'
if ((Get-FileHash '.\owner-b.ps1' -Algorithm SHA256).Hash.ToLowerInvariant() -ne '9b2b0ddf2cedf7d59492b94e14e5294d9d4877c02be1456f5ca8eb70947a14ca') {
    throw 'Runner SHA256 mismatch; STOP'
}
$OldSession = Join-Path $env:USERPROFILE 'CUDY-RC-B-20261020.1\rc-b-session.json'
$rc = @{
    Target = 'root@192.168.1.1'
    BundleUrl = 'https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/fc6a4c7ffb39bcc7b33ad81ff058664d38f5f356/artifacts/hgdeploy2-rc-b-20261020.2/cudy-hgdeploy2-rc-b-62592457237e7f026786c086d1ca6fdd4b6c095d.tar.gz'
    BundleSha256 = '599ebe1d46e644bea3465b336ee74b61f5fb802569dd2c17d9bb82cf0603ef42'
    SessionFile = (Join-Path $Dir 'rc-b-session.json')
}
.\owner-b.ps1 @rc -Stage RetireCheck -PreviousSessionFile $OldSession
```

Require `RC_B_ASATA_PREFLIGHT=PASS`, `RC_B_RETIREMENT_CHECK=PASS` and `RC_B_OWNER_STAGE=RetireCheck RESULT=PASS`. The read-only ASATA compatibility check is repeated immediately before untouched Retire and before Prepare. On any refusal stop; preserve all output and both session files. Do not repin files, delete journals/locks, or repeat the old Apply.

## GO / NO-GO before writing

Technical release gates are recorded in the acceptance report. Actual owner GO additionally requires this target's RetireCheck PASS and a working recovery access path available for the entire window. Physical Ethernet availability alone is not confirmed SSH access. `-RecoveryPathConfirmed` is the owner's explicit attestation, not a bypass or an automated Ethernet test. If access/recovery is uncertain, NO-GO for Retire, Prepare and Apply; the read-only stage remains available.

The off-router private backup SHA256 is `986ceab1b0ed4eb06df359adf5f333348f25d929d27d4aed456452c07259ef33`. Inclusion/integrity are confirmed; actual restore is NOT_TESTED. Never upload it or private Gateway data.

## Explicit retirement and new installation

Run one command at a time, checking PASS before the next. Do not set the confirmation switches until the corresponding conditions are actually met.

```powershell
.\owner-b.ps1 @rc -Stage Retire -PreviousSessionFile $OldSession -RetirementConfirmed -RecoveryPathConfirmed
.\owner-b.ps1 @rc -Stage Preflight
.\owner-b.ps1 @rc -Stage Prepare -RecoveryPathConfirmed
.\owner-b.ps1 @rc -Stage Apply -RecoveryPathConfirmed
.\owner-b.ps1 @rc -Stage Verify
```

Retire revalidates old source/package/session, legacy runtime/receiver/journal/latest, private state, Telegram intent and original guard identity. It atomically archives the entire old migration state at `/etc/home-gateway-migration.retired.a7376b1d-2405-440b-9349-e5e94cb88ae6`. It removes only three verified retained migration controls; it preserves the original guard inode and changes no Gateway runtime, receiver, journal/latest, credentials, or running service. A dedicated temporary S07 boot guard keeps HG1 writers fenced until durable retirement completion, then is removed. Unknown state fails closed.

Prepare creates a NEW transaction and durable snapshots, publishes migration controls and quarantines Telegram autostart. Apply coordinates only Gateway Telegram/procd, private state and pinned runtime/receiver publication; it requires full verification and terminal COMMITTED admission. It does not touch PassWall2, Xray, UCI, nftables, routes, VPN or DNS. No router reboot, sysupgrade, restore or bootstrap is part of these instructions. Route/egress UNKNOWN is not a reason to change networking.

After Verify PASS, inspect Gateway status, selftest/doctor, Telegram status response and the existing network services. Report the exact output and new transaction. No fault injection on CUDY.

## Error and recovery

**During Retire:** do not run Prepare or Apply. Keep the NEW session, old session and all router evidence. If /tmp kit was lost, run UploadRecovery, then RetireCheck and explicit Retire again using the original old session:

```powershell
.\owner-b.ps1 @rc -Stage UploadRecovery
.\owner-b.ps1 @rc -Stage RetireCheck -PreviousSessionFile $OldSession
.\owner-b.ps1 @rc -Stage Retire -PreviousSessionFile $OldSession -RetirementConfirmed -RecoveryPathConfirmed
```

UploadRecovery is needed only when the kit was lost. A refusal is not permission to remove any lock or file.

**During the NEW Prepare/Apply/Verify:** never repeat Apply. If the new session captured a transaction, use its explicit rollback, then Verify. UploadRecovery first only if its /tmp kit was lost:

```powershell
.\owner-b.ps1 @rc -Stage UploadRecovery
.\owner-b.ps1 @rc -Stage Rollback
.\owner-b.ps1 @rc -Stage Verify
```

Rollback restores and verifies the snapshotted 18-file runtime, trusted legacy receiver/wrapper/recovery init, original latest/journal/backup, private state and Telegram/procd intent. Terminal ROLLED_BACK remains fenced until a separately verified retirement. Do not clean it manually.

If SSH is unavailable, use the already confirmed recovery access path to reconnect. Boot guards prevent automatic replay; they do not restore SSH or VPN. Do not reboot or reset a working router as an improvised remedy. If the session lacks a captured transaction or recovery refuses unknown/corrupt state, stop and retain evidence for diagnosis rather than guessing a UUID.

## Evidence limits

OpenWrt VM testing is networkless disposable x86 with real procd PID1, BusyBox ash 1.37 and native ucode: 506 checks passed across 15 scenarios on the exact source. SIGKILL/reboot assertions are actual VM tests, not production tests. The real nft kernel fixture verifies position 15 and doctor success, and refusal of an inserted UDP interceptor. Telegram/procd install/commit/rollback, private state and unchanged network configuration/routes/nft are checked.

The owner's RC-B 20261020.1 attempt passed selftest 62/0 but failed ASATA doctor and did not commit. Owner rollback and verification passed (58/0 selftest, 11 OK doctor), transaction `a7376b1d-2405-440b-9349-e5e94cb88ae6`, now ROLLED_BACK. Keep that Windows session. The earlier retired archive `38bd5771-7472-45e7-8e2f-e4a37f7948ab` is preserved. This new candidate has not been installed on CUDY.

Packaging verification: [Actions 39492598521](https://github.com/bsekinaev/cudy-home-gateway/actions/runs/39492598521), deterministic duplicate build, actual PowerShell protocol/parse and native `RC_B_PACKAGE=VERIFIED`. The packaging-only branch changes no accepted installer source. Published source is exactly the tested PR head; merged main has the identical tree.
