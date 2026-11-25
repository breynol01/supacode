# MEMORY: fork decisions and history

Durable facts and records of completed work. Historical; for current policy, `AGENTS.md` wins.

## 2026-11-11: fork created
- Forked supabitapp/supacode at upstream `main` (2026-11-07). Built the browser pane, the background-work indicator, and turned off auto-update.
- Policy: follow upstream **releases only** (`v*`). The fork stays public, guarded by a local pre-push hook. GitHub Actions is disabled on the fork.
- Release sync is automated (`FORK.md`). The full pipeline (3842 tests) and the rerere conflict replay were both verified.

## 2026-11-17: sidebar repository groups
- Added `fork/sidebar-groups`: repos can be tagged with a group (e.g. Work / Personal / Music) and render under collapsible headers. Design: `docs/superpowers/specs/2026-11-17-sidebar-project-groups-design.md` on that branch.
- Called "Group" in code and UI because "folder" already means two things: a non-git directory opened as a project (`SidebarStructure.Section.folder`) and the worktree folders from `fork/sidebar-folders`.
- Groups sort A-Z with ungrouped repos last; there is no manual group order. A group is a tag on each repo, not a container, so the persisted repo order and `.repositoriesMoved` are unchanged. `SidebarStructure.repositoryMove` only rejects drops that cross a group boundary.
- Collapsed-group members are dropped from `expandedRepositoryIDs`, so hotkeys and arrow navigation skip them the same way they skip a collapsed repo.

## 2026-11-25: passkeys in browser panes (Chrome sign-in bridge)
- Passkeys and 1Password can't work inside a `WKWebView` without Apple's restricted browser entitlement. Benjamin declined to request it.
- The first fallback (an "Open in Browser" hand-off) was rejected: the session has to end up inside the pane.
- Shipped a Chrome popup plus cookie import on `fork/browser-pane` (see `ARCHITECTURE.md` › Browser pane). QA'd on GitHub and on a HubSpot record list: the pane stayed signed in across navigation and a relaunch.
- Not yet QA'd: a fresh passkey sign-in through 1Password in the popup. Chrome was already signed in on both runs.
- Follow-up: the bridge only reads the last-used Chrome profile (https://github.com/breynol01/supacode/issues/9).

## Lessons (non-obvious)
- **Claude Code presence:** Claude reports status itself via OSC 7501 (it probes the terminal at startup) and sends `state=clear` when a turn ends. An idle Claude therefore has *no* presence record. Supacode's Claude hooks were retired upstream (#939), so "Install" in Settings writes no hooks. That's by design.
- **Daemon-hosted sessions:** resuming can leave a session running under Claude's background daemon. It isn't a child of the tab, its `SUPACODE_SURFACE_ID` is stale, and drag-and-drop images into it fail (they work in a fresh tab).
- **Process probes in tests:** the test host is the live app, so a real system scan leaks actions into unrelated tests ("@Dependency(\.date) … test context"). Probes must be dependencies with an empty `testValue`.
- **"Test runner hung before establishing connection":** caused by a stale Tuist-generated project, not the code. Clear `.build/.tuist-generated-stamps/development` before `make test`.
- **Shortcut hints hide badges:** holding ⌘ shows the sidebar's ⌃N shortcut hints, which make row badges transparent. Screenshots taken with ⌘⇧4 never show badges.
- **Logging:** `SupaLogger` only prints to stdout in Debug builds. For a temporary diagnostic in an installed Debug build, use `os.Logger` and read it with `log show`.
- **Chrome cookie write-back:** Chrome saves cookie changes to its SQLite file in batches (2–30s). Reading right after a sign-in returns stale rows, which made the first bridge QA reload signed out.
- **WKWebView and passkeys:** `isUserVerifyingPlatformAuthenticatorAvailable()` and `isConditionalMediationAvailable()` return `false`, so most sites hide passkey sign-in and never call `navigator.credentials`.
- **The test host writes to the real home directory:** anything a unit test triggers that writes files (like the bridge trace) lands in `~/Library`. Gate it on `XCTestConfigurationFilePath`.
- **Client data in tests:** the fork is public. Use placeholder IDs in tests and fixtures, never a real client's portal or record ID; one had to be scrubbed from history once.
- **Toolchain:** the Metal toolchain installs without sudo: `xcodebuild -downloadComponent MetalToolchain`.
- **Shared state:** the Debug build shares its bundle id and `~/.config/supacode` with the release. Never run both at once.
