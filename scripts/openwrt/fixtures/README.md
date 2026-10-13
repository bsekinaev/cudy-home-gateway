# Frozen public OpenWrt package index

`packages.adb` is the unchanged signed public x86_64 packages repository index
used for the OpenWrt25.12.5 offline stat/timeout fixture. Source:
https://downloads.openwrt.org/releases/25.12.5/packages/x86_64/packages/packages.adb

SHA256: `d0fe864ac61705f34e401099719ea3cf37625912eb3d54260a7cbcdcc8ae9126`.
It was independently verified with the official25.12.5 rootfs APK3.0.5 and
`/etc/apk/keys/openwrt-25.12.pem` (file SHA256
`27d61d827d64ccf2f46dce5f52aec6279404d4a00686dafb22f52f3b4ee675f8`):
`apk --keys-dir <official-rootfs>/etc/apk/keys verify packages.adb`: OK.
The guest rechecks the vendor signature during normal offline APK installation.
All three APKs have separate fixed SHA256 in `run_vm.py`; no allow-untrusted.

On13October2026 upstream replaced the index with SHA256
`d02d6150da10ef4f910a1ef2a322ee3f1357822b87a9e5d5b6f50aab10f06b53`.
CI correctly refused that changed input. Vendoring preserves the previously
verified bytes and pin instead of silently accepting the new index. This file
is public vendor metadata and contains no owner configuration or private backup.
