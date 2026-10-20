# RC-B 20261019.2 owner LIVE failure / verified rollback

Evidence source: owner report 2026-10-20, not Work SSH or VM.
Source: `908dd3222b81992d9fee056bd015a1266a0ce8d7`.
Transaction: `38bd5771-7472-45e7-8e2f-e4a37f7948ab`.

- Owner Preflight PASS; Prepare PASS/PREPARED.
- Apply: `MIGRATION_ADMISSION=BLOCKED`; native file stage returned
  `RC_B_STAGE=apply RESULT=PASS PHASE=APPLYING SERVICE_START=CANDIDATE FINISH=COMMIT`.
  SSH stage exit 1. Apply was NOT retried. File-stage PASS is not installation PASS.
- Owner rollback PASS: RESTORING, SERVICE_START=LEGACY/FINISH=ROLLBACK,
  selftest 58 PASS / 0 FAIL, doctor 11 OK / 0 WARN / 0 FAIL,
  complete-rollback and verify PASS / ROLLED_BACK, runner Rollback PASS.
- Separate owner Verify PASS / ROLLED_BACK. Production is restored.
- Windows session and owner evidence must be preserved. Published RC-B bundles
  remain immutable. Owner RC-A directories must not be removed.

## RCA status: specific rejecting predicate UNCONFIRMED

`migration-admission.sh` has one generic require() failure message for every
assertion. The quoted message alone does not identify FD8, ticket, metadata,
fence, hash or handoff-anchor refusal. It is not evidence of a particular cause.

The candidate rc.common path takes/borrows FD8 in hg_start_guard(), then invokes
`--telegram-start --migration-start --held-telegram-guard` in
hg_runtime_admitted(). Provisional admission requires APPLYING plus a matching
service ticket, held guard identity, migration fence and complete verified
23-file runtime/receiver and rollback anchor. service_started() repeats admission
and closes its inherited FD without unlocking the parent's open-file description.

The native apply stage returned its CANDIDATE start intent, so failure is after
file/handoff publication and before terminal commit. Its stdout is captured by
rc-b.sh while stderr is not; output ordering is not a chronology of publication.
The generic admission message is produced by the ucode gate, not by procd process
verification. It does not establish whether the first or second admission call
failed. Successful rollback has changed phase/live paths; a normal admission run
now cannot reproduce the original provisional refusal. Do not invoke service start
or replay Apply to obtain a diagnostic.

No speculative production fix or new RC has been certified. Historical exact-head
CI/VM acceptance remains historical, and does not override this LIVE failure.

## Repeat installation: BLOCKED

Current preflight explicitly requires no `/etc/home-gateway-migration`; terminal
ROLLED_BACK has no transition to PREPARED/APPLYING. There is no accepted retirement
entrypoint. Fresh session/kit alone cannot authorize reinstallation.

Next installer must provide an explicit, tested retirement/archival operation:
under the existing guard, verify exact old transaction/terminal admission,
restored 18+3 runtime/journal/latest, private-state and legacy service, retained
control identities and boot enablement; preserve old state as evidence; handle
interruption/reboot before allowing a NEW transaction. Guard inode must not be
recreated or repinned. Exact legacy SHA mismatch, drift, unknown state or newer
deployment must refuse. This is a requirement, NOT an implemented command.

Never manually remove journals/locks, alter phase/admission, run bootstrap, reuse
old Apply or edit Windows session to reset applyAttempted.

`PRODUCTION_MIGRATION=BLOCKED`
`READY_FOR_OWNER_MANUAL_MIGRATION=NO`
