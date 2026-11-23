import ComposableArchitecture
import Foundation
import OrderedCollections
import SupacodeSettingsShared

extension RepositoriesFeature.State {
  struct CustomizeAppearanceSelection {
    let row: SidebarItemFeature.State
    let repositoryID: Repository.ID
    let customizesRow: Bool
    let customizesRepository: Bool
  }

  var customizeAppearanceSelection: CustomizeAppearanceSelection? {
    guard let selectedWorktreeID,
      let row = sidebarItems[id: selectedWorktreeID],
      let repositoryID = repositoryID(containing: selectedWorktreeID)
    else {
      return nil
    }
    return CustomizeAppearanceSelection(
      row: row,
      repositoryID: repositoryID,
      customizesRow: row.isFolder || (!row.isMainWorktree && !row.lifecycle.isPending),
      customizesRepository: repositories[id: repositoryID]?.isGitRepository == true
        && removingRepositoryIDs[repositoryID] == nil
    )
  }

  var customizeSelectedAppearanceRequest: RepositoriesFeature.Action? {
    guard let selection = customizeAppearanceSelection else { return nil }
    if selection.customizesRow {
      return .requestCustomizeWorktree(selection.row.id, selection.repositoryID)
    }
    guard selection.row.isMainWorktree, selection.customizesRepository else { return nil }
    return .requestCustomizeRepository(selection.repositoryID)
  }
}

extension RepositoriesFeature {
  /// Dedicated reducer for the per-worktree customization flow. Lives in its own file so the main
  /// `body` switch stays under the Swift type-checker's complexity limit.
  static var worktreeCustomizationReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .requestCustomizeSelectedAppearance:
        guard state.worktreeCustomization == nil, state.repositoryCustomization == nil,
          let request = state.customizeSelectedAppearanceRequest
        else {
          return .none
        }
        return .send(request)

      case .requestCustomizeWorktree(let worktreeID, let repositoryID),
        .requestNewWorktreeFolder(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees.first(where: { $0.id == worktreeID })
        else {
          repositoriesLogger.warning(
            "requestCustomizeWorktree dropped: unknown wt=\(worktreeID) repo=\(repositoryID)"
          )
          return .none
        }
        // Git main worktree is repository-level (use requestCustomizeRepository instead). The
        // folder synthetic worktree IS the row, so we allow it through.
        if repository.isGitRepository, state.isMainWorktree(worktree) {
          repositoriesLogger.warning(
            "requestCustomizeWorktree dropped: git main worktree is repository-level wt=\(worktreeID)"
          )
          return .none
        }
        let bucket = state.sidebar.currentBucket(of: worktreeID, in: repositoryID)
        let storedItem = bucket.flatMap {
          state.sidebar.sections[repositoryID]?.buckets[$0]?.items[worktreeID]
        }
        // For folder synthetic worktrees, default name = repository name (what the row shows when
        // no override). For git worktrees, default name = branch name.
        let defaultName = repository.isGitRepository ? worktree.name : repository.name
        state.worktreeCustomization = WorktreeCustomizationFeature.State(
          worktreeID: worktreeID,
          repositoryID: repositoryID,
          defaultName: defaultName,
          title: storedItem?.title ?? "",
          color: storedItem?.color,
          supportsFolder: repository.isGitRepository,
          folder: storedItem?.folder ?? "",
          existingFolders: repository.isGitRepository ? state.sidebar.folderNames(in: repositoryID) : [],
          focusesFolderOnAppear: repository.isGitRepository && action.is(\.requestNewWorktreeFolder)
        )
        return .none

      case .worktreeCustomization(.presented(.delegate(.cancel))):
        state.worktreeCustomization = nil
        return .none

      case .worktreeCustomization(
        .presented(.delegate(.save(let worktreeID, let repositoryID, let title, let color, let folder)))
      ):
        // Always overwrite (user save intent); falls back to `.unpinned` when the row hasn't been
        // seeded into a bucket yet (folder synthetic before first reconcile, deeplink/palette).
        let isGit = state.repositories[id: repositoryID]?.isGitRepository == true
        state.$sidebar.withLock { sidebar in
          sidebar.setCustomization(title: title, color: color, worktree: worktreeID, in: repositoryID)
          if isGit { sidebar.setFolder(folder, worktree: worktreeID, in: repositoryID) }
        }
        syncSidebar(&state)
        state.worktreeCustomization = nil
        return .none

      case .worktreeCustomization(.dismiss):
        state.worktreeCustomization = nil
        return .none

      case .setWorktreeAppearance(let worktreeID, let repositoryID, let title, let color):
        state.$sidebar.withLock { sidebar in
          sidebar.setCustomization(title: title, color: color, worktree: worktreeID, in: repositoryID)
        }
        syncSidebar(&state)
        return .none

      case .setWorktreesFolder(let worktreeIDs, let repositoryID, let folder):
        guard state.repositories[id: repositoryID]?.isGitRepository == true else { return .none }
        state.$sidebar.withLock { sidebar in
          for worktreeID in worktreeIDs {
            sidebar.setFolder(folder, worktree: worktreeID, in: repositoryID)
          }
        }
        syncSidebar(&state)
        return .none

      default:
        return .none
      }
    }
  }
}
