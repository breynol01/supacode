#!/usr/bin/env bash
# After a browser-pane "Sign in with Chrome" attempt: the bridge trace, then the
# site's cookies in Chrome and in the pane's store side by side. No cookie values.
# Usage: scripts/browser-bridge/diagnose.sh <host> [trace-lines]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
host="${1:?usage: diagnose.sh <host> [trace-lines]}"
lines="${2:-40}"
chrome="$HOME/Library/Application Support/Google/Chrome"
profile="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["profile"].get("last_used") or "Default")' "$chrome/Local State" 2>/dev/null || echo Default)"
work="$(mktemp -d -t supacode-bridge-diag)"
trap 'rm -rf "$work"' EXIT

echo "== bridge trace (~/Library/Logs/Supacode/browser-bridge.log)"
tail -n "$lines" "$HOME/Library/Logs/Supacode/browser-bridge.log" 2>/dev/null || echo "(no trace yet)"

echo; echo "== Chrome ($profile) cookies for $host"
cp "$chrome/$profile/Cookies" "$work/Cookies"
for s in -wal -shm; do [ -f "$chrome/$profile/Cookies$s" ] && cp "$chrome/$profile/Cookies$s" "$work/Cookies$s"; done
sqlite3 -separator '  ' "$work/Cookies" "
  select printf('%-28s', host_key), printf('%-34s', name),
    'updated=' || datetime(last_update_utc/1000000-11644473600, 'unixepoch', 'localtime'),
    'secure=' || is_secure, 'httponly=' || is_httponly, 'samesite=' || samesite
  from cookies where host_key like '%$host' order by last_update_utc desc"

echo; echo "== pane cookies for $host"
python3 -I "$here/binarycookies.py" "$HOME/Library/HTTPStorages/app.supabit.supacode.binarycookies" "$host"
