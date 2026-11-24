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
