# Fork maintenance (breynol01/supacode)

A personal fork of [supabitapp/supacode](https://github.com/supabitapp/supacode) (FSL-1.1, internal use).
Canon: `AGENTS.md` (upstream's guidance plus a **Fork** section at the end), `CLAUDE.md` (pointer to `AGENTS.md`), `PRD.md`, `ARCHITECTURE.md`, `MEMORY.md`. This file is the maintenance runbook.

## Public repo
`breynol01/supacode` is **public**: GitHub forks of public repos can't be private. Never commit secrets, 1Password secret references, tokens, home paths, or client/work names or data.
A local `pre-push` hook (`.git/hooks/pre-push`, not versioned) blocks pushes that match those markers or that gitleaks flags. Machine-specific config (the skill, the launchd plist) stays outside the repo.

## Policy
- Follow **upstream releases only**: `v*` tags. Never sync to `tip` or `main`.
- Build on Supacode's own mechanisms (OSC 7501 program status, `AgentPresenceFeature`, the sidebar row snapshot, the kind-agnostic `TabContent` layer) before inventing a parallel path.
- Each fork change lives on its own `fork/*` branch, small enough to offer upstream as a PR.

## Branches
| Branch | Purpose |
|---|---|
| `main` | Mirror of `upstream/main`. Never commit here. |
| `fork/*` | One fork change each, rebased onto the current release tag. Listed in `.fork/branches.txt`, merged in that order. |
| `personal` | Build/install branch. **Regenerated** on every sync (release tag + every `fork/*`). Never edit it directly. |
| `backup/personal-<date>` (tag) | Snapshot taken before each sync. |

## Fork changes
- `fork/tooling`: this file plus `.fork/`.
  - `sync.sh` signs builds with the local `Apple Development` identity when the keychain has one. Ad-hoc signatures change every rebuild, so macOS drops privacy grants (the repeating "access files in your Documents folder" prompt). Set `XCODEBUILD_FLAGS` to override. One-time per machine: let codesign use the key without a prompt (`security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db`, asks for the login password); otherwise codesign fails with `errSecInternalComponent`.
- `fork/no-auto-update`: Sparkle never checks or installs, so an upstream release can't replace the fork build.
- `fork/browser-pane`: a `browser` `ContentKind` (`supacode/Features/Browser/BrowserContent.swift`). WKWebView on the default persistent data store, so one sign-in is shared across worktrees. Adds `--url` on `supacode tab new` / `pane split`, the `url=` deeplink param, and "Open Browser in Split" (⌘⇧L). It plugs into upstream's `TabContent` / `TabContentToolbar` / `TabChrome` protocols. Upstream wants a browser too (issue #500); prefer their design if they ship one.
- `fork/background-work`: a sidebar hourglass, and the row counts as Active, when an idle Claude session still has background shell commands running.
  - `BackgroundWorkProbe` finds `claude` processes by `SUPACODE_SURFACE_ID` and looks for children carrying Claude Code's `~/.claude/shell-snapshots/` wrapper.
  - The probe is injected as `BackgroundWorkClient`; its `testValue` is empty, because the test host is the live app.
  - Known gap: daemon-hosted Claude sessions (`claude daemon` / `bg-spare`) aren't under the tab and their surface ID goes stale. The fallback idea is `~/.claude/sessions/*.json`.

## Syncing to a new upstream release
- Automatic: a launchd agent (`com.breynol01.supacode-fork-check`, Mondays 09:00) runs `.fork/check.sh`. When a new `v*` tag exists, it starts headless Claude with the `supacode-fork-sync` skill and posts a macOS notification with the result. The log is at `~/Library/Logs/supacode-fork-sync.log`.
- Manual: `bash .fork/sync.sh` (`--target <ref>`, `--rebuild`, `--no-install`, `--no-push`). From a branch without `.fork/`: `git show fork/tooling:.fork/sync.sh > /tmp/fork-sync.sh && FORK_REPO=$PWD bash /tmp/fork-sync.sh`.
- Exit codes:
  - 0: synced and installed, or already up to date.
  - 2: rebase conflict. The rebase is left paused.
  - 3: build, lint or test failure.
  - 1: preflight problem.
- `git rerere` is on, so a conflict resolved once is re-applied automatically next time.

## Resolving conflicts
- Keep upstream's behavior and re-apply the fork's intent on top of it (see "Fork changes").
- `AGENTS.md` / `CLAUDE.md` conflicts (both live on `fork/tooling`): take upstream's new `AGENTS.md` body, re-append our `## Fork (breynol01/supacode)` section at the end, and keep `CLAUDE.md` as the one-line pointer. Upstream's `CLAUDE.md` duplicates its `AGENTS.md`, so nothing is lost. rerere usually replays this.
- If upstream now does what a fork change did, shrink or drop that branch, and remove it from `.fork/branches.txt` when it's empty.
- After `git rebase --continue`, re-run `bash .fork/sync.sh`. Finished branches rebase as no-ops.
- Build gotcha: clear `.build/.tuist-generated-stamps/development` before `make test` (and after switching branches). `make build-app` followed by `make test` otherwise hangs with "test runner hung before establishing connection". The sync script clears it before every step.

## Starting new fork work
1. `git checkout -b fork/<name> $(git tag -l 'v*' --sort=-v:refname | head -1)` (or the current base).
2. Commit, and add the branch to `.fork/branches.txt` (on `fork/tooling`).
3. `bash .fork/sync.sh --rebuild` to regenerate `personal`, build, test and install.
