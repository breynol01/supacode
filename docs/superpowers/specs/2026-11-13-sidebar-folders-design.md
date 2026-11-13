# Custom sidebar folders for worktrees

## Context
Benjamin wants to resume work in existing worktrees (Claude Code session history is keyed by directory, so reusing a worktree keeps `claude --resume` history). Finding the right worktree (e.g. task-manager iOS widgets) is hard: the only grouping today is the View-menu "Nest Worktrees by Branch" toggle, which derives `fix/` / `feat/` headers from branch names. Users can't create, name, or manage groups. Goal: user-defined, named folders in the sidebar.

## Design (short; approved approach A)
- **Intent:** let the user put any worktree into a named folder inside its repo section so related work is findable regardless of branch name.
- **Goals:** create/assign/rename-by-reassign/clear a folder per worktree; folders render as collapsible headers with the same aggregated indicators (agent, notification, script dots) as branch groups; works with Nest-by-Branch on or off; survives archive/unarchive and app restart.
- **Non-goals:** drag-into-folder, manual folder ordering, cross-repo folders, tags, sidebar search, nested folders.
- **Anti-goals:** touching move/reorder/pin bucket logic; per-row invalidation fan-out (sidebar perf rule).
- **Approaches considered:** (A, picked) folder is a forced top-level component in the existing `SidebarBranchNesting` trie; (B) first-class folder containers with DnD, rejected as 3–4x scope rewriting fragile move/pin logic; (C) global cross-repo Folders section, rejected as duplicating Pinned for a single-repo use case.
- **Builder's calls (mine, correctable):**
  - Folder stored as `folder: String?` on `SidebarState.Item` (beside `title`/`color`), persisted in `~/.supacode/sidebar.json`; backward-compatible decode.
  - Folder names: trimmed, no `/`, case-sensitive; empty clears.
  - Folders sort alphabetically, before un-foldered rows; a folder header renders even with a single member (unlike branch groups' 2+ rule) and never chain-collapses into child branch prefixes.
  - With Nest-by-Branch off, rows inside a folder are flat (full branch name); with it on, branch prefixes nest inside the folder.
  - Collapse state reuses `collapsedBranchPrefixes` with a namespaced key (`folder:<name>`) so a folder named `fix` can't collide with the `fix/` branch group.
  - As with branch nesting today, drag-reorder is suppressed in a bucket while it's grouped (i.e. when any row in it has a folder).
  - Assign via a Folder field in the Customize Appearance sheet (combo with existing folder names in that repo) and a right-click "Move to Folder" submenu (existing folders, "New Folder…", "Remove from Folder").

