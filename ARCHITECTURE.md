# Architecture: fork additions

How the fork's features plug into upstream Supacode. For upstream's own architecture and conventions, see `AGENTS.md`; for branches and syncing, see `FORK.md`.

## Browser pane (`fork/browser-pane`)
- **Model:** `ContentKind.browser` plus `ContentState.browser(BrowserContentState)` (persists the URL), in `Features/Terminal/Models/PaneLayout.swift`.
- **Content:** `Features/Browser/BrowserContent.swift`.
  - `BrowserContent: TabContent` uses a `WKWebView` renderer on `WKWebsiteDataStore.default()`, so one persistent profile is shared by every tab.
  - The URL bar is a `TabContentToolbar` (`BrowserToolbar`). Title and loading state go through `TabChrome` (`BrowserTabChrome`).
  - The tab never hibernates; `snapshot()` stores the URL.
- **Factory:** the `.browser` case in `TerminalContentBuilder.factory()` (`TerminalSurfaceRecipe.swift`).
- **Entry points:**
  - Deeplinks `tab/new?url=` and `pane/<id>/split?url=` become `Deeplink.browserNew` / `browserSplit`, handled in `AppFeature`.
  - Those send `TerminalClient.Command.createBrowserTab` / `splitPaneWithBrowser`, which `WorktreeTerminalManager.handleBrowserCommand` turns into the existing `createTabAsync` / `splitPane` with `browserURL:`.
  - CLI: `--url` on `tab new` / `pane split`.
  - Menu: "Open Browser in Split" (⌘⇧L), wired through `FocusedAction` `openBrowserSplitAction`.

## Background-work indicator (`fork/background-work`)
- **Signal:** `BackgroundWorkProbe` (`Features/AgentPresence/BusinessLogic/`).
  - Lists `claude` processes and reads `SUPACODE_SURFACE_ID` from their environment (`KERN_PROCARGS2`).
  - Child processes whose argv carries Claude Code's `~/.claude/shell-snapshots/` wrapper count as agent-spawned shell commands. MCP servers, LSPs and `caffeinate` don't match.
  - Injected as `BackgroundWorkClient`: the live app scans; `testValue` returns nothing, because the test host is the live app.
- **State:**
  - `AgentPresenceFeature`'s 2-second liveness sweep probes every surface not in `busySurfaces` (agent working or awaiting input).
  - `backgroundWorkResult` is sent only when the result changes. `State.backgroundWork` maps a surface to its commands.
- **Display:** `RowSnapshot.backgroundCommands` drives `SidebarBackgroundWorkIndicator` (`SidebarItemView.swift`). A row with background work counts as `hasAgent` in `SidebarActiveClassification`, so it stays in Active.
- **Why not presence records alone:**
  - Claude Code reports via OSC 7501 with no pid.
  - It clears its record when a turn ends, so an idle Claude has no record.
  - Supacode's Claude hooks were retired upstream (#939).
- **Known gap:** daemon-hosted sessions (`claude daemon` → `bg-pty-host` → `bg-spare`) don't run under the tab, and their `SUPACODE_SURFACE_ID` goes stale across relaunches. Candidate fix: Claude's session registry, `~/.claude/sessions/<pid>.json` (cwd, status, kind), matched to worktree rows by path.

## No auto-update (`fork/no-auto-update`)
- `UpdaterClient.liveValue` forces Sparkle's automatic checks and downloads off, and makes `checkForUpdates` a no-op.

## Release sync (`fork/tooling`)
- `.fork/sync.sh`: rebase each `fork/*` branch onto the release tag (with `rerere`), regenerate `personal`, run build, lint and test, then install and push.
- `.fork/check.sh`: a weekly launchd check. On a new tag it starts headless Claude with the `supacode-fork-sync` skill.
- Details and exit codes are in `FORK.md`.
