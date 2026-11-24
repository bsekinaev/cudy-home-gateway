# WAN runtime: preparation for relocation

**Goal:** avoid false positives from stale WAN measurements when the uplink changes.

**Baseline:** installed runtime `1fc822c`; read-only diagnostics developed in PR #37.
The runtime changes are kept in a separate development branch. No production
network changes or installation are part of the development tests.

## Tasks

- [x] Runtime route discovery: read main-table defaults without a device filter,
  select a single attributable usable route, accept PPPoE device-only routes,
  reject unsupported protocols and incomplete local paths.
- [x] WAN direct-egress cache: require a fingerprint of the boot, logical and
  actual interface, protocol, address/prefix, selected route and probe endpoints.
  Old three-field caches are ignored. A changed fingerprint prevents both fresh
  and stale reuse. This is an observed identity, not proof that two providers
  with identical addressing and configuration are distinct.
- [x] Check context transitions in the health envelope and MAIN/Torrent caches.
  Cache identity includes the observed WAN path, generated profile configuration,
  SOCKS endpoint, configured node and probe identity. Missing context or config
  prevents reuse; normal live checks still run. Background Torrent policy remains
  unchanged. Health context includes WAN prefix and path fingerprint.
- [ ] Exercise static, DHCP and PPPoE on an isolated network test system; clarify
  unsupported multipath, multiple default routes, IPv6-only and additional tables.
- [ ] Prepare a separate owner package format/admission from `1fc822c` with
  rollback and exact-source review/native CI before deployment.
- [ ] Owner verifies installation, client internet and continued accumulation
  of history; actual provider relocation remains a separate operation.

## Current evidence

Five initial runtime tests reproduced the original failures before implementation;
all eight WAN runtime cases and four existing monitor budget tests passed after
the change. The tests use synthetic command output and no network connectivity.
They do not establish successful real PPPoE connection or production relocation.

The follow-up regression initially reused the previous MAIN/Torrent cache after
WAN context changed and produced an identical health context. Both corrected.
Seven monitor budget/cache tests, nine health tests and eight WAN runtime tests
passed. These tests do not establish external VPN or call availability.

The previous WAN-only commit also passed the complete local repository suite and
a real iproute2 test with an isolated loopback route change (network disabled,
synthetic egress responses).

Additional isolated real-iproute2 check: static default with gateway, then a
device-only default with synthetic PPPoE status, then removal of the default.
Observed OK, OK/fresh probe, DEGRADED/UNKNOWN respectively. This checks route
semantics without a real PPP negotiation, ISP or external traffic.

## Delivery contract for the next milestone

The existing monitor V3 package admits only `62b5c4a` with a V2 parent, so it
cannot be reused for the installed `1fc822c`. Introduce an explicitly separate
owner WAN format rather than widening V3. The immediate parent must be the
accepted immutable monitor archive and its exact source/manifest; keep the
existing 20 runtime and 14 control paths. Allow changes only to network.sh,
health.sh, vpn.sh, torrent.sh for this milestone. All previous V1/V2/V3 admissions,
historical receipts and manifest validation must continue to work as before.

Add a source-bound native scenario that builds and installs the exact V3
baseline, applies the actual WAN candidate, verifies it, rolls back to V3,
checks state preservation and baseline bytes, exercises interruption/recovery
and reboot. A distinct acceptance report must bind the WAN format, installed
baseline, source and executed check inventory. Re-run old format scenarios.
Only after exact-source full CI and review, build an owner package and verify
the archive pins. No installer from the previous baseline is suitable.

First delivery increment: `HG_OWNER_WAN_V4` is admitted by host builder and
target protocol only as VM_ONLY, with exact V3 baseline `1fc822c`, four-path
allowlist and unchanged immutable inventories. OWNER_MANUAL is deliberately
refused until the new native scenario and owner acceptance contract exist.
Old V1/V2/V3 scope and parent restrictions are unchanged. The existing Windows
owner runner does not admit V4. This is development infrastructure, not an
installable release for CUDY.
