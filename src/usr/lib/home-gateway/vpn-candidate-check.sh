#!/bin/sh
# Check an existing reserve through a temporary loopback-only Xray instance.
set -eu
set -o pipefail

[ "$#" -eq 2 ] || exit 2
renderer="$1"
candidate="$2"
case "$candidate" in ''|*[!a-zA-Z0-9_]*) exit 2 ;; esac
[ "${#candidate}" -le 64 ] || exit 2

umask 077
dir="$(mktemp -d /tmp/hg-candidate.XXXXXX)"
runner=''
cleanup() {
    if [ -n "$runner" ]; then
        kill -TERM "$runner" 2>/dev/null || :
        wait "$runner" 2>/dev/null || :
    fi
    rm -f "$dir/config.json"
    rmdir "$dir"
}
trap cleanup EXIT
trap 'exit 70' HUP INT TERM

port=55182
if netstat -lnt | grep -E "[.:]$port[[:space:]]" >/dev/null; then
    printf 'CANDIDATE_PORT_BUSY\n'
    exit 70
fi

# Credentials move between local processes on stdin, never in argv or diagnostics.
ucode -e '
    import { cursor } from "uci";
    let c = cursor();
    let backups = c.get("passwall2", "socks_P8ART", "autoswitch_backup_node");
    if (type(backups) != "array" || index(backups, ARGV[0]) < 0 ||
        c.get("passwall2", "socks_P8ART", "node") == ARGV[0])
        exit(2);
    let node = c.get_all("passwall2", ARGV[0]);
    if (node == null || node[".type"] != "nodes")
        exit(2);
    for (let field in keys(node))
        if (substr(field, 0, 1) == ".") delete node[field];
    printf("%J", node);
' "$candidate" | ucode "$renderer" "$port" > "$dir/config.json"

timeout -k 2 15 /usr/bin/xray run -c "$dir/config.json" </dev/null >/dev/null 2>&1 &
runner=$!
sleep 1
pid="$(netstat -lntp 2>/dev/null | awk -v addr="127.0.0.1:$port" '
    $4 == addr && $6 == "LISTEN" && $7 ~ /\/xray$/ { split($7, fields, "/"); print fields[1] }
')"
case "$pid" in ''|*[!0-9]*) printf 'CANDIDATE_LISTENER_UNAVAILABLE\n'; exit 70 ;; esac
if ! awk -v expected="$runner" '$1 == "PPid:" && $2 == expected { found=1 } END { exit !found }' "/proc/$pid/status"; then
    printf 'CANDIDATE_LISTENER_NOT_OWNED\n'
    exit 70
fi

result=0
for url in https://www.google.com/generate_204 https://cp.cloudflare.com/; do
    code="$(curl -q --noproxy '' --socks5-hostname "127.0.0.1:$port" \
        --connect-timeout 3 --max-time 4 -s -o /dev/null -w '%{http_code}' "$url")" || code=000
    printf '%s HTTP=%s\n' "$url" "$code"
    [ "$code" = 204 ] || result=70
done
exit "$result"
