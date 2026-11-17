import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureCustomizationTests {
  private let repoID: RepositoryID = "/tmp/customize-repo"

  private func makeInitialState(
    isGitRepository: Bool = true,
  ) -> RepositoriesFeature.State {
    let worktree = Worktree(
      id: WorktreeID("\(repoID)/main"),
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: repoID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "customize-repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree]),
      isGitRepository: isGitRepository,
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    // Production seeds every cache on the roster load; without this the state
    // under test starts stale (an empty open-action map, a placeholder structure)
    // for a non-empty roster.
    state.applyCacheRecomputes(.all)
    return state
  }

  @Test func requestCustomizeRepositorySeedsPromptFromStoredSidebarSection() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID] = .init(
        title: "Pretty",
        color: .blue,
      )
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeRepository(repoID)) {
      $0.repositoryCustomization = RepositoryCustomizationFeature.State(
        repositoryID: self.repoID,
        defaultName: "customize-repo",
        title: "Pretty",
        color: .blue,
      )
    }
  }

  @Test func requestCustomizeRepositoryNoOpsForFolderRepos() async {
    // Folder repos render through `SidebarFolderRow` and have no
    // section header to tint. The reducer must reject the request
    // even if a future deeplink or palette entry tries to invoke
    // it.
    let store = TestStore(initialState: makeInitialState(isGitRepository: false)) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeRepository(repoID))
    // No state mutation expected — `repositoryCustomization` stays nil.
  }

  @Test func saveDelegatePersistsTitleAndColorToSidebar() async {
    var initial = makeInitialState()
    initial.repositoryCustomization = RepositoryCustomizationFeature.State(
      repositoryID: repoID,
      defaultName: "customize-repo",
      title: "",
      color: nil,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryCustomization(
        .presented(
          .delegate(
            .save(repositoryID: repoID, title: "Renamed", color: .red),
          ))),
    ) {
      $0.repositoryCustomization = nil
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID, default: .init()].title = "Renamed"
        sidebar.sections[self.repoID, default: .init()].color = .red
      }
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func explicitRemovalDropsCustomizationFromSidebar() async {
    // `preserveOrphanSections` keeps customized tombstones across
    // transient drops (filesystem flutter), but an explicit "Remove
    // Repository" must purge `sidebar.sections[id]` so re-adding the
    // same path doesn't silently restore the user's old title /
    // color.
    var initial = makeInitialState()
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID] = .init(
        title: "Pretty",
        color: .blue,
      )
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.repositoryPersistence.pruneRepositoryConfigs = { _ in }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.repositoriesRemoved([repoID], selectionWasRemoved: false))
    await store.skipReceivedActions()

    #expect(store.state.sidebar.sections[repoID] == nil)
  }

  @Test func cancelDelegateClearsPresentedState() async {
    var initial = makeInitialState()
    initial.repositoryCustomization = RepositoryCustomizationFeature.State(
      repositoryID: repoID,
      defaultName: "customize-repo",
      title: "",
      color: nil,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryCustomization(.presented(.delegate(.cancel))),
    ) {
      $0.repositoryCustomization = nil
    }
  }

  // MARK: - Repository groups.

  @Test func setRepositoriesGroupAssignsAndClears() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }

    await store.send(.setRepositoriesGroup([repoID], group: "  Music ")) {
      $0.$sidebar.withLock { $0.sections[self.repoID, default: .init()].group = "Music" }
      $0.applyPostReduceCacheRecomputes()
    }
    #expect(store.state.sidebarStructure.sections.first?.id == .repositoryGroup("Music"))

    await store.send(.setRepositoriesGroup([repoID], group: nil)) {
      $0.$sidebar.withLock { $0.sections[self.repoID]?.group = nil }
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func setRepositoriesGroupIgnoresUnknownRepositories() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }

    await store.send(.setRepositoriesGroup(["/tmp/unknown"], group: "Music"))
  }

  @Test func groupExpansionTogglesCollapseAndRejectsUnknownNames() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { $0.setGroup("Music", for: [self.repoID]) }
    initial.applyCacheRecomputes(.all)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.repositoryGroupExpansionChanged(name: "Music", isExpanded: false)) {
      $0.$sidebar.withLock { _ = $0.collapsedGroups.insert("Music") }
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }
    #expect(store.state.sidebarStructure.sections.map(\.id) == [.repositoryGroup("Music")])

    await store.send(.repositoryGroupExpansionChanged(name: "Ghost", isExpanded: false))

    await store.send(.repositoryGroupExpansionChanged(name: "Music", isExpanded: true)) {
      $0.$sidebar.withLock { _ = $0.collapsedGroups.remove("Music") }
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }
  }

  @Test func clearingLastMemberPrunesCollapsedGroup() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock {
      $0.setGroup("Music", for: [self.repoID])
      $0.collapsedGroups = ["Music"]
    }
    initial.applyCacheRecomputes(.all)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.setRepositoriesGroup([repoID], group: nil)) {
      $0.$sidebar.withLock {
        $0.sections[self.repoID]?.group = nil
        $0.collapsedGroups = []
      }
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func requestNewRepositoryGroupFocusesGroupField() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { $0.setGroup("Work", for: ["/tmp/other"]) }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestNewRepositoryGroup(repoID)) {
      $0.repositoryCustomization = RepositoryCustomizationFeature.State(
        repositoryID: self.repoID,
        defaultName: "customize-repo",
        title: "",
        color: nil,
        existingGroups: ["Work"],
        focusesGroupOnAppear: true
      )
    }
  }

  @Test func requestNewRepositoryGroupOpensGroupOnlySheetForFolderRepos() async {
    let store = TestStore(initialState: makeInitialState(isGitRepository: false)) {
      RepositoriesFeature()
    }

    await store.send(.requestNewRepositoryGroup(repoID)) {
      $0.repositoryCustomization = RepositoryCustomizationFeature.State(
        repositoryID: self.repoID,
        defaultName: "customize-repo",
        title: "",
        color: nil,
        supportsAppearance: false,
        focusesGroupOnAppear: true
      )
    }
  }

  @Test func groupOnlySaveLeavesAppearanceUntouched() async {
    var initial = makeInitialState(isGitRepository: false)
    initial.repositoryCustomization = RepositoryCustomizationFeature.State(
      repositoryID: repoID,
      defaultName: "customize-repo",
      title: "",
      color: nil,
      supportsAppearance: false
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryCustomization(
        .presented(.delegate(.save(repositoryID: repoID, title: nil, color: nil, group: "Music"))))
    ) {
      $0.repositoryCustomization = nil
      $0.$sidebar.withLock { $0.sections[self.repoID, default: .init()].group = "Music" }
      $0.applyPostReduceCacheRecomputes()
    }
    #expect(store.state.sidebar.sections[repoID]?.title == nil)
  }

  @Test func revealUncollapsesContainingGroup() async {
    var initial = makeInitialState()
    let mainID = WorktreeID("\(repoID)/main")
    initial.$sidebar.withLock {
      $0.setGroup("Music", for: [self.repoID])
      $0.collapsedGroups = ["Music"]
    }
    initial.selection = .worktree(mainID)
    initial.applyCacheRecomputes(.all)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.revealSelectedWorktreeInSidebar)

    #expect(store.state.sidebar.collapsedGroups.isEmpty)
  }

  @Test func expandAllClearsCollapsedGroups() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock {
      $0.setGroup("Music", for: [self.repoID])
      $0.collapsedGroups = ["Music"]
    }
    initial.applyCacheRecomputes(.all)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.setAllSidebarGroupsExpanded(true))

    #expect(store.state.sidebar.collapsedGroups.isEmpty)
  }
}
