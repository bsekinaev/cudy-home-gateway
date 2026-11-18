# Owner series development

This directory implements the host packaging boundary for repeatable HGDEPLOY2
updates. It does not yet provide a usable router updater or owner release.

- `archive.py`: bounded, non-extracting gzip/USTAR validation.
- `parent.py`: authenticate the immutable d2039b6 V1 bootstrap against Git.
- `build_kit.py`: VM_ONLY V2 package builder and flat parent witness validation.
- `test_*.py`: hostile archive tests and committed host packaging fixtures.

The candidate contains all 20 baseline/candidate runtime paths. Only observer/UI
leaves may differ. Migration/deploy controls retain their original 14 hashes.
Each package includes exactly one unchanged V1 bootstrap archive and the immediate
parent manifest; older packages are not recursively embedded. The supplied parent
archive SHA256 must be independently approved by its caller.

Flat prior manifests are checked against their Git runtime/helper bytes, modes,
inventories, permitted delta, controls and lineage. The digest of their own
`parent.json` is deliberately detached. Future target validation must match these
historical identities against immutable installed receipts; a host package does
not prove that its parent was installed.

All builder code dependencies must match the selected committed source and its
checkout must be clean. Controller files must exist in that source; the current
real branch has no transaction engine/guardian/owner runner yet, so building an
actual installable candidate currently refuses missing controllers. Tests supply
explicitly labeled, non-executable helper fixtures in temporary committed repos.
They prove packaging only, never lifecycle/native acceptance. Fixture ancestry is
retained across subsequent packages.

Owner output unconditionally refuses `OWNER_SERIES_ACCEPTANCE_NOT_IMPLEMENTED`.
This gate remains closed until exact-source CI/review/native lifecycle acceptance
is implemented. No new production package is issued by this stage. The installed
V1 kit, journals, runtime, client state and network configuration remain unchanged.

Local packaging tests: `python -m unittest discover -s scripts/owner_series -p 'test_*.py'`.
The main control-plane CI script also runs this suite. Linux exercises occupied
checksum symlinks; Windows may lack permission to create symlink fixtures.
