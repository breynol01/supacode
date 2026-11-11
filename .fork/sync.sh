#!/bin/bash
# Sync the fork to an upstream release: rebase each fork/* branch onto the
# target, regenerate `personal`, build + lint + test, install, push.
# Exit codes: 0 ok/up to date, 1 preflight, 2 rebase conflict, 3 build/lint/test failure.
set -uo pipefail

# Branch switches rewrite this file, so run from a private copy.
if [ -z "${FORK_SYNC_REEXEC:-}" ]; then
  FORK_REPO="${FORK_REPO:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}" || exit 1
  tmp="$(mktemp -t fork-sync).sh"
  cp "$0" "$tmp"
  FORK_SYNC_REEXEC=1 FORK_REPO="$FORK_REPO" exec bash "$tmp" "$@"
fi
cd "$FORK_REPO" || exit 1

target="" rebuild=0 install=1 push=1
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="$2"; shift ;;
    --rebuild) rebuild=1 ;;
    --no-install) install=0 ;;
    --no-push) push=0 ;;
    *) echo "unknown flag: $1"; exit 1 ;;
  esac
  shift
done

log() { echo "[fork-sync] $*"; }
logfile() { echo "/tmp/fork-sync-$(basename "$FORK_REPO")-$1.log"; }

# Preflight.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then log "working tree has changes; commit or stash first"; exit 1; fi
if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] || [ -d "$(git rev-parse --git-dir)/rebase-merge" ]; then
  log "a rebase is in progress; finish it (git rebase --continue) then re-run"; exit 1
fi
git config rerere.enabled true; git config rerere.autoupdate true

branches=()
while IFS= read -r line; do branches+=("$line"); done < <(git show fork/tooling:.fork/branches.txt | sed 's/#.*//' | awk 'NF')
[ ${#branches[@]} -gt 0 ] || { log "no branches in .fork/branches.txt"; exit 1; }

git fetch -q upstream --tags || { log "fetch upstream failed"; exit 1; }
[ -n "$target" ] || target="$(git tag -l 'v*' --sort=-v:refname | head -1)"
git rev-parse -q --verify "$target^{commit}" >/dev/null || { log "unknown target: $target"; exit 1; }

if [ $rebuild -eq 0 ] && git merge-base --is-ancestor "$target" personal 2>/dev/null; then
  log "up to date: personal already contains $target"; exit 0
fi
log "target: $target ($(git rev-parse --short "$target"))"

backup="backup/personal-$(date +%Y%m%d)"
git rev-parse -q --verify "refs/tags/$backup" >/dev/null || git tag "$backup" personal
log "backup tag: $backup"

for b in "${branches[@]}"; do
  log "rebasing $b onto $target"
  if ! git rebase -q "$target" "$b"; then
    if git diff --name-only --diff-filter=U | grep -q . ; then
      log "CONFLICT in $b. Resolve, 'git add', 'git rebase --continue', then re-run this script."
      git diff --name-only --diff-filter=U | sed 's/^/  conflicted: /'
      exit 2
    fi
    # rerere resolved everything; finish the rebase.
    GIT_EDITOR=true git rebase --continue || { log "rebase of $b could not continue"; exit 2; }
  fi
done

log "regenerating personal"
git checkout -q -B personal "$target"
for b in "${branches[@]}"; do
  git merge -q --no-ff --no-edit "$b" || { log "merge of $b into personal conflicted (branches overlap)"; exit 2; }
done

for step in build-app lint test; do
  # A project generated for one step leaves `make test` hanging ("test runner
  # hung before establishing connection"); regenerate before each step.
  rm -f .build/.tuist-generated-stamps/development
  log "make $step"
  make "$step" > "$(logfile "$step")" 2>&1 || { log "make $step failed; see $(logfile "$step")"; exit 3; }
done

if [ $install -eq 1 ]; then
  log "installing to /Applications"
  make install-dev-build > "$(logfile install)" 2>&1 || { log "install failed; see $(logfile install)"; exit 3; }
fi
if [ $push -eq 1 ]; then
  git push -q -f origin "${branches[@]}" personal && git push -q origin "refs/tags/$backup" 2>/dev/null
  log "pushed branches, personal, $backup"
fi
git config fork.lastSynced "$target"
log "done: personal = $target + ${#branches[@]} fork branches"
