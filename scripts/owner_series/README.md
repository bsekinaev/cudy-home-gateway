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

## Explicit monitor transition V3

`--delivery monitor` selects `HG_OWNER_MONITOR_V3`; default delivery remains
unchanged V2. The only monitor baseline is installed source
`62b5c4a9f25bc657fa1456eeacdfdc9039648cae`, with its authenticated immediate V2
parent manifest. V3 is a single transition, not permission to widen V2 or to
create subsequent monitor generations. Unknown formats are refused.

The monitor delta is closed to `usr/bin/gateway` and existing `health.sh`,
`network.sh`, `vpn.sh`, `incidents.uc`, `notifications.uc`, and
`telegram-poller.uc`, and `torrent.sh` in `usr/lib/home-gateway`. All 20 runtime paths and 14
original controls remain exact and source-bound. No path is created or removed;
apply, recover, verify and rollback retain the existing inventory transaction.
History remains user data: code rollback does not rewind it or the queue.

Owner acceptance retains all exact-source CI/review/native checks and additionally
requires native report fields `delivery: monitor` and
`package_format: HG_OWNER_MONITOR_V3`. Merely relabelling an observer report does
not supply monitor lifecycle evidence. VM fixtures remain non-executable host
packaging tests and do not authorize owner output.

### Launcher первого мониторинга

Шаблон start-monitor.ps1.in генерируется в release assets с закреплёнными SHA
runner/archive/source. Пункты 1–3: Preflight, Apply, отдельный Verify. Пункт 4
повторяет Verify, сверяет установленный source и отсутствие pending-операции,
затем выполняет единственный фиксированный `gateway notifications configure monitoring`.
Это явное действие владельца: четыре категории включаются, прежние mute и
Telegram retry_after сохраняются. Recover/rollback остаются отдельными пунктами
5/6. Agent не вызывает это действие на рабочем CUDY.
