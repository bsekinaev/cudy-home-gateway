# Owner series V2

Repeatable manual HGDEPLOY2 observer updates. Source fb8d9e3 was installed and
independently verified by the owner on 20 November 2026. Older descriptions of
this directory as an unimplemented packaging boundary are obsolete.

- archive.py: bounded, non-extracting gzip/USTAR validation.
- parent.py: authenticate the V1 bootstrap and flat immediate V2 parent.
- build_kit.py: reproducible VM_ONLY or OWNER_MANUAL packages; owner output
  requires exact-source CI/review/native acceptance.
- protocol.uc, state.uc: platform/inventory, receipt, locking and state guards.
- engine.uc, watch.uc, boot.init: transaction, recovery and supervised boot.
- owner.ps1: explicit owner Preflight/Apply/Verify/Recover/Rollback stages.

Each package carries all 20 baseline/candidate runtime paths and the original
14 deployment/migration controls. Only dns.sh, redmi.sh, health.sh, status.sh and
telegram-poller.uc may differ. Changing any other runtime file or adding a new
module needs a separately designed delivery scope; these checks stay closed.
Exactly one unchanged V1 bootstrap and one immediate parent manifest are included;
older packages are not nested recursively. Parent identity is authenticated
against Git and installed immutable receipts, not inferred from a host archive.

New packages require a clean committed source, full CI and native lifecycle
evidence for that same source, and independent review. Host packaging fixtures
remain explicitly non-executable and cannot become owner kits. Native tests use
isolated x86 OpenWrt; they do not establish router installation or client internet.

Read-only preflight does not repair user state. Writer exclusion, action locks,
process ownership, canonical inventories and rollback/recovery contracts remain
mandatory. Code rollback does not rewind the notification queue or user state.

Preserve the installed package, its session and receipts. The next package must
name the actual installed source as its immediate baseline. The owner performs
installation and a separate Verify; agents do not connect to production CUDY.

Tests: python -m unittest discover -s scripts/owner_series -p test_*.py.
Windows-specific runner tests require Windows PowerShell 5.1; native lifecycle
and boot/recovery tests run in the existing GitHub Actions matrix.
