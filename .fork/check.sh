#!/bin/bash
# Weekly check (launchd): if upstream shipped a new release, hand the sync to
# headless Claude and notify with the outcome.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1
cd "$REPO" || exit 1

notify() { osascript -e "display notification \"$2\" with title \"Supacode fork\" subtitle \"$1\"" >/dev/null 2>&1; }
log() { echo "$(date '+%F %T') $*"; }

git fetch -q upstream --tags || { log "fetch failed"; exit 1; }
latest="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if git merge-base --is-ancestor "$latest" personal; then
  log "up to date ($latest)"; exit 0
fi

log "new upstream release $latest; starting Claude sync"
notify "Syncing to $latest" "Upstream released $latest. Merging, testing, installing."
claude -p "Sync the Supacode fork to upstream release $latest. Use the supacode-fork-sync skill and follow FORK.md. Finish with a bullet summary." \
  --permission-mode bypassPermissions 2>&1
log "claude exited $?"

if git merge-base --is-ancestor "$latest" personal; then
  notify "Updated to $latest" "Fork rebuilt and installed. Relaunch Supacode to load it."
else
  notify "Sync needs you" "Couldn't finish syncing to $latest. See ~/Library/Logs/supacode-fork-sync.log"
fi
