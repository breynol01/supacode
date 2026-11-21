# Sidebar project groups (Work / Personal / Music)

## Context
The user has many repos open in Supacode, spanning company work, personal projects, and music (several Bitwig repos). Every repo is a flat top-level sidebar section, so related projects are scattered. Goal: user-named **groups** that collect repos under collapsible headers (e.g. MUSIC holds the Bitwig repos), so he can fold away whole areas of his life.

The existing `fork/sidebar-folders` feature groups *worktrees inside one repo*; this is the next level up: grouping *repos*.

## Design (short; approved approach A, collapsible headers)
- **Intent:** tag any repo with a group name; the sidebar renders a collapsible group header above that group's repos.
- **Goals:** create / assign / clear a repo's group; collapsed header shows aggregated indicators (agent, notification, script dots) of its member repos; survives restart; works with Manual and By Name section sort.
- **Non-goals:** drag-into-group, drag-reordering groups, manual group order, nested groups, CLI/deeplink support, a filter/switcher view.
- **Anti-goals:** reworking the repo `.onMove` / `repositoriesMoved` persisted-order logic beyond a guard; per-row invalidation fan-out (AGENTS.md sidebar perf rule); breaking `sidebar.json` back-compat.
- **Approaches considered:** (A, picked) `group: String?` tag on each repo's `SidebarState.Section` + a header section emitted in `SidebarStructure`; (B) first-class ordered group containers with DnD, rejected as 2–3× scope touching fragile reorder + persistence migration; (C) color-as-group, rejected (no collapse).
- **Builder's calls (mine, correctable):**
  - Named **Group** in code and UI ("Move to Group") to avoid colliding with `Section.folder` (non-git folder projects) and worktree folders. Header shows the name uppercased-style like other sidebar section headers.
  - Name rules reuse `SidebarFolderName.normalized` (trim, no `/`, empty clears).
  - Groups render A–Z (case-insensitive) after the global Pinned/Active sections; ungrouped repos render after all groups. Within a group, repos keep the current section sort (manual persisted order or By Name).
  - Collapse state: new `collapsedGroups: Set<String>` on `SidebarState` (decodeIfPresent → `[]`). Pruned when no repo uses that name.
  - Collapsed group omits member repo sections entirely, so hotkey slots / arrow navigation skip them automatically (they walk `sections`).
  - Reveal/deeplink/selection of a worktree in a collapsed group uncollapses the group (same place the reducer already sets `sections[repo].collapsed = false`).
  - Drag-reorder: allowed only when source and destination are in the same group (or both ungrouped); cross-group drops are rejected. Group headers are `.moveDisabled(true)`.
  - Highlight rows (Pinned/Active) stay global; no group tag on them.
  - Assign via repo header context menu "Move to Group" submenu (existing groups, "New Group…", "Remove from Group") and a Group field in Customize Repository sheet (combo of existing group names).

## Branch
`fork/sidebar-groups`, branched from `fork/sidebar-folders` (reuses `SidebarFolderName`, the folder header styling, and touches the same files, so stacking avoids conflicts). Add to `.fork/sync.sh` branch list so it merges into `personal`.
