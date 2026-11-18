# Repeatable owner updates implementation plan

Spec: ../specs/2026-11-18-owner-update-generations-design.md
Base: 4193b5364c36cad21873a4b189da3904e68b939e.
Execute inline. No production connections or installation by the agent.
V1 package, runtime controls, evidence and guards remain immutable.

## Task 1: Strict archive boundary

Status: implemented at 8361835; 10 archive tests PASS, independently reviewed.

Files: scripts/owner_series/archive.py, test_archive.py.
Interface: read_archive(raw, expected_sha256) returns path -> (mode, bytes).
Validate digest before decompression, compressed/expanded budgets, strict USTAR,
checksums, modes, path closure, duplicates, metadata and complete termination.
Write hostile archive tests first and watch RED; implement; run full module.
Expected: valid deterministic archive accepted; malformed variants rejected.
Commit the archive boundary with passing tests.

## Task 2: Source-bound package and parent lineage

Status: V1 bootstrap authentication implemented at 8361835; 9 parent tests PASS.
Actual accepted OWNER_MANUAL archive also validated against the pinned manifest
and Git source. V2 builder and subsequent-generation parent validation pending.

Files: scripts/owner_series/build_kit.py, test_build.py.
Consumes Task 1 validated parent package; produces V2 manifest and deterministic
USTAR package. Full 20 runtime paths + 14 immutable control pins; observer delta
allowlist; parent manifest pin and V1 bootstrap witness. VM_ONLY by default;
OWNER_MANUAL requires exact source CI/review/native report, no source fixtures.
Tests first: real d203 parent, drift, wrong profile/source, changed controls,
unknown paths, oversized inputs, zero delta, V2 parent chain, reproducibility.
Expected: all boundaries pass; V1 builder tests still pass unchanged.

## Task 3: Read-only target protocol

Files: scripts/owner_series/protocol.uc, engine.uc, native protocol tests.
Consumes Task 2 manifest. Validate full live parent/control/history inventories,
hardware/profile, action policy/state without actions show, worker identities,
space, closed immutable receipts, active/current/latest pointers.
Tests first against native pinned ucode; unknown/drift always refuses unchanged.
Expected: read-only preflight has zero persistent/runtime writes.

## Task 4: Transaction, guardian and boot guard

Files: engine.uc, watch.uc, boot.init; crash tests.
Persist caller UUID before RPC. Acquire serial/actions locks; authenticated RAM
lease; recoverable PREPARING; full backup; PREPARED guard+active before writes.
Quarantine and FD8 drain; worker quiescence; owned sibling publication; explicit
raw active for startup; immutable terminal operations; separate rollback receipt.
Recover restores only authenticated before state; terminal recovery only cleans
accepted outcome. No automatic replay, history rewrite or private-data restore.
Expected: cuts at every write/start/pointer boundary fence safely and recover;
unknown bytes refuse; multi-rollback preserves every previous receipt hash.

## Task 5: Windows owner runner

Files: scripts/owner_series/owner.ps1 and transport helpers/tests.
Consumes strict package and protocol. PowerShell 5.1 + ssh/scp/.NET only;
Preflight/Apply/Verify/Rollback/Recover, durable session/operation identity,
exact local archive validation before extraction/RPC, proper UTF-8 output.
Expected: parser and transport/session fault tests pass; no credential logging.

## Task 6: Native lifecycle and exact-source CI

Files: scripts/openwrt/guest-owner-series.sh, run_vm.py, CI workflow.
Start with original migration and exact d203 V1 in isolated OpenWrt25.12.5.
Test real candidate A and deterministic VM_ONLY source fixture B, successive
updates/rollback/reapply, all crash cuts, reboot recovery, PID reuse/manual start,
space/action/foreign-lock/drift refusal. Assert network config/nft/routes and
private cursors unchanged. Preserve existing 81-case V1 regressions.
Use attempt-specific artifact names and enough setup budget for cold CI workers.
Expected: complete named native report bound to exact commit; all CI jobs pass.

## Task 7: Independent review and owner handoff

One fresh whole-branch review; reproduce blocking findings RED then fix once,
rerun relevant suite and exact-source CI. OWNER_MANUAL build only from accepted
source/report/review, verify archive pin and source closure. Update roadmap and
owner instructions. Owner performs staged rollout; no live success claim before
separate Verify and client confirmation.
