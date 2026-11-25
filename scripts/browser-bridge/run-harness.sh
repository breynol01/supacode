#!/usr/bin/env bash
# Builds and runs the Chrome sign-in bridge harness against a local fake site.
# Usage: scripts/browser-bridge/run-harness.sh [port]
#        scripts/browser-bridge/run-harness.sh popup <url>   (trace a real site's popup)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
port="${1:-8766}"
[ "${1:-}" = popup ] && port=8766
work="$(mktemp -d -t supacode-bridge-harness)"
trap 'kill "${server:-0}" 2>/dev/null || true; rm -rf "$work"' EXIT

# Fake site: /login sets a session cookie and bounces to /home after a second.
python3 -I "$here/fake_site.py" "$port" >"$work/server.log" 2>&1 &
server=$!
for _ in $(seq 20); do curl -fs "http://localhost:$port/home" >/dev/null && break; sleep 0.25; done

swiftc -O -o "$work/harness" \
  "$repo/supacode/Features/Browser/ChromeCookieBridge.swift" "$here/main.swift" 2>"$work/build.log" \
  || { cat "$work/build.log"; exit 1; }
if [ "${1:-}" = popup ]; then "$work/harness" popup "${2:?url}"; else "$work/harness" "$port"; fi
