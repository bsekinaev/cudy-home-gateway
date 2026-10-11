# MAIN Transactions — 0.8 work in progress

`gateway main-transaction plan NODE` — read-only observation of the existing UCI
configuration. It accepts a named section of up to 64 alphanumeric/underscore
characters, requires the audited profile mapping `socks_P8ART`, socks/enable=1,
port 1082, global enabled=1, autoswitch explicitly disabled, a candidate section
of type `nodes`, and no pending PassWall2 UCI edits. Read commands use bounded
output and `timeout -k 1 5`; raw errors, config, node IDs and credentials are not
returned. No external vtest command, node process, traffic probe or restart runs.

Even a valid observation returns **70 / PREFLIGHT_ADAPTER_REQUIRED** with
`apply_supported=false`, `preflight_passed=false`, `snapshot_ready=false`.
`same_as_configured_main` compares only configured IDs; it does not prove actual
active egress. Independent UCI reads are not an atomic or generation-consistent
snapshot, and no authorization token/certificate is created. `apply`, `rollback`
and `recover` fail closed without invoking UCI. Telegram has no access to this
command. Runtime inventory remains unchanged (implementation in `vpn.sh`).

## Remaining implementation and acceptance

1. Audit the actual PassWall2 `utils.sh` and `app.sh run_socks` dependencies and
   target version. The supplied vtest calls these privileged helpers but does not
   include their implementation. Never execute an unaudited provider or broad
   `pgrep` cleanup on production.
2. Establish process-owned temporary SOCKS, unique port and hard timeout; actual
   TLS-verified candidate network preflight and owned cleanup, no MAIN changes.
3. Coordinate every UCI/nft/service writer. A private copy and repeated reads
   alone cannot make a snapshot/apply safe against concurrent writers.
4. Snapshot relevant config privately with hashes, durable transaction journal,
   apply intent persisted before change, staged apply, independent post-check,
   commit/rollback and crash/reboot recovery. This is distinct from existing
   control-plane transactional deployment.
5. Verify LAN recovery and Tailscale independently; owner-approved isolated
   tests before any live MAIN apply. Record target rollback and backup evidence.

These capabilities are **not implemented or accepted** yet. Real CUDY remains
unchanged and no v1.0.0 tag may be created from this planner.
