# PRD: Supacode personal fork

What the fork sets out to achieve on top of upstream Supacode. Living document.

## Problem
- Work is organized one worktree per issue or task. The reference page for that work (usually the Jira issue) lives in a separate browser, outside the workspace.
- A lot of work is delegated from a Claude Code session to a long-running LangGraph run. When the session goes quiet, the sidebar can't tell "dormant" apart from "waiting on delegated work".
- Upstream ships fast. The fork has to take each release without losing its changes.

## Requirements and status
| Feature | Success criteria | Status |
|---|---|---|
| **Browser pane** (`fork/browser-pane`) | A light browser opens in a split (⌘⇧L, or `supacode pane split --url <url>`); sign-in is shared across worktrees; the tab restores its URL after a relaunch | Split confirmed working. Shared sign-in and URL restore not yet checked. |
| **Background-work indicator** (`fork/background-work`) | A worktree whose Claude session is idle but still has background commands running shows an hourglass (tooltip lists the commands) and stays in Active. It clears when the work ends, and no per-repo or per-graph setup is needed. | Confirmed for normal sessions. Daemon-hosted sessions not covered (see ARCHITECTURE.md). |
| **No auto-update** (`fork/no-auto-update`) | An upstream release never replaces the fork build | Done |
| **Release sync** (`fork/tooling`) | Each new upstream `v*` release is detected weekly, merged, tested and installed, with conflicts resolved against documented intent | Pipeline and conflict replay verified. The first real run will be v0.11.8. |

## Constraints
- Upstream license is FSL-1.1-ALv2: internal use is fine, keep the license file, don't make a competing product.
- The repo is public (a GitHub fork of a public repo).
- Builds are local only: macOS 26, the Metal toolchain, a dev signing identity.
- Prefer changes shaped so upstream could accept them (upstream issue #500 tracks an in-app browser).

## Rollback
- Every sync tags `backup/personal-<date>`. Reinstall from it with `git checkout <tag> && make install-dev-build`.
- To return to stock Supacode, reinstall the official release from supacode.sh. Auto-update is off in the fork build.
