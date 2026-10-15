#!/bin/sh
# Delivery A only. No production install, service, UCI, nft, routing or reboot.
set -eu
umask 077
KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
BB=/bin/busybox
if [ "${1:-}" = --test-busybox ]; then BB=$2; shift 2; case "$BB" in /*) ;; *) exit 64;; esac; fi
op=${1:-}; shift || exit 64
case "$op" in
  preflight)
    [ "$BB" = /bin/busybox ] && [ "$#" -eq 0 ] || exit 64
    refuse() { echo "RC_A_PREFLIGHT_REFUSED=$1" >&2; exit 69; }
    grep -q "DISTRIB_RELEASE='25.12.5'" /etc/openwrt_release || refuse OPENWRT_VERSION
    "$BB" ash --help 2>&1 | grep -q 'BusyBox v1.37.0' || refuse BUSYBOX_VERSION
    for tool in ucode timeout sha256sum stat base64 tar; do command -v "$tool" >/dev/null || refuse "MISSING_$tool"; done
    ucode "$KIT/rc-a.uc" "$KIT" check "$BB"
    "$BB" fsync --help >/dev/null 2>&1 || refuse BUSYBOX_FSYNC
    "$BB" flock --help >/dev/null 2>&1 || refuse BUSYBOX_FLOCK
    sh "$KIT/legacy-preflight.sh" 4b1f9ea568167a67f24470615b31efe4b9fd7a68374e666443ad31945e58922e
    echo 'RC_A_PREFLIGHT=PASS GATEWAY_MUTATIONS=0 PRODUCTION_APPLY=BLOCKED'
    ;;
  prepare)
    [ "$#" -eq 0 ] || exit 64
    ucode "$KIT/rc-a.uc" "$KIT" check "$BB"
    ROOT=$(mktemp -d /tmp/hgdeploy2-rc-a.XXXXXX)
    printf 'HGDEPLOY2_RC_A_LAB_V1\n' > "$ROOT/.hg-rc-a-lab"
    printf 'DISPOSABLE\n' > "$ROOT/.hg-deploy-test-root"
    printf 'DISPOSABLE_HG_MIGRATION_LAB\n' > "$ROOT/.hg-migration-lab"
    # Print identity before preparation, including on any subsequent refusal.
    printf 'RC_LAB=%s\n' "$ROOT"
    ucode "$KIT/rc-a.uc" "$KIT" seed "$BB" "$ROOT"
    mkdir -m 700 "$ROOT/tmp" "$ROOT/etc/home-gateway-deploy"
    pin=$(sha256sum "$KIT/legacy.wire"); pin=${pin%% *}
    sh "$KIT/fixture/usr/libexec/home-gateway-deploy/engine.sh" --test-root "$ROOT" apply bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$pin" < "$KIT/legacy.wire"
    ucode "$KIT/rc-a.uc" "$KIT" prepare "$BB" "$ROOT"
    ;;
  apply|verify|rollback)
    [ "$#" -eq 1 ] || exit 64
    exec ucode "$KIT/rc-a.uc" "$KIT" "$op" "$BB" "$1"
    ;;
  *) echo 'RC_A_REFUSED: production apply is unavailable; use preflight or isolated prepare/apply/verify/rollback' >&2; exit 73;;
esac
