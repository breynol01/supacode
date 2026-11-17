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

## Lessons (non-obvious)
- **Claude Code presence:** Claude reports status itself via OSC 7501 (it probes the terminal at startup) and sends `state=clear` when a turn ends. An idle Claude therefore has *no* presence record. Supacode's Claude hooks were retired upstream (#939), so "Install" in Settings writes no hooks. That's by design.
- **Daemon-hosted sessions:** resuming can leave a session running under Claude's background daemon. It isn't a child of the tab, its `SUPACODE_SURFACE_ID` is stale, and drag-and-drop images into it fail (they work in a fresh tab).
- **Process probes in tests:** the test host is the live app, so a real system scan leaks actions into unrelated tests ("@Dependency(\.date) … test context"). Probes must be dependencies with an empty `testValue`.
- **"Test runner hung before establishing connection":** caused by a stale Tuist-generated project, not the code. Clear `.build/.tuist-generated-stamps/development` before `make test`.
- **Shortcut hints hide badges:** holding ⌘ shows the sidebar's ⌃N shortcut hints, which make row badges transparent. Screenshots taken with ⌘⇧4 never show badges.
- **Logging:** `SupaLogger` only prints to stdout in Debug builds. For a temporary diagnostic in an installed Debug build, use `os.Logger` and read it with `log show`.
- **Toolchain:** the Metal toolchain installs without sudo: `xcodebuild -downloadComponent MetalToolchain`.
- **Shared state:** the Debug build shares its bundle id and `~/.config/supacode` with the release. Never run both at once.
