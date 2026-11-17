import ComposableArchitecture
import OrderedCollections
import SupacodeSettingsShared
import SwiftUI

/// Collapsible header for a user-defined repository group. Its member
/// repositories follow as ordinary sections (the structure omits them while
/// collapsed), so this renders a header-only section.
struct SidebarRepositoryGroupHeader: View {
  let name: String
  let isCollapsed: Bool
  /// Member rows feeding the aggregated indicators; empty while expanded.
  let leafIDs: [Worktree.ID]
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    Section {
      EmptyView()
    } header: {
      Button {
        _ = withAnimation(.easeOut(duration: 0.2)) {
          store.send(.repositoryGroupExpansionChanged(name: name, isExpanded: isCollapsed))
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            .animation(.easeInOut(duration: 0.15), value: isCollapsed)
            .accessibilityHidden(true)
          Image(systemName: isCollapsed ? "folder" : "folder.fill")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(name)
            .lineLimit(1)
          Spacer(minLength: 0)
          if isCollapsed, !leafIDs.isEmpty {
            SidebarPathGroupAggregatedIndicators(parentStore: store, leafIDs: leafIDs)
          }
        }
        .appFontInheriting(.subheadline, weight: .semibold)
        .contentShape(.interaction, .rect)
      }
      .buttonStyle(.plain)
      .help(isCollapsed ? "Expand \(name)" : "Collapse \(name)")
      .accessibilityLabel("\(name) group, \(isCollapsed ? "collapsed" : "expanded")")
    }
  }
}

/// "Move to Group" submenu for one or more repositories: existing groups,
/// "New Group…" (single repository only), and "Remove from Group".
struct SidebarRepositoryGroupMenu: View {
  let repositoryIDs: [Repository.ID]
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    let sidebar = store.sidebar
    let groupNames = sidebar.groupNames
    let currentGroups = Set(repositoryIDs.map { sidebar.sections[$0]?.group })
    let sharedGroup: String? = currentGroups.count == 1 ? currentGroups.first ?? nil : nil
    Menu("Move to Group", systemImage: "folder") {
      ForEach(groupNames, id: \.self) { name in
        Button(name) {
          store.send(.setRepositoriesGroup(repositoryIDs, group: name))
        }
        .disabled(name == sharedGroup)
        .help("Show under the \(name) sidebar group")
      }
      if !groupNames.isEmpty { Divider() }
      if repositoryIDs.count == 1, let repositoryID = repositoryIDs.first {
        Button("New Group…", systemImage: "folder.badge.plus") {
          store.send(.requestNewRepositoryGroup(repositoryID))
        }
        .help("Create a sidebar group and move this repository into it")
      }
      if currentGroups.contains(where: { $0 != nil }) {
        Button("Remove from Group", systemImage: "folder.badge.minus") {
          store.send(.setRepositoriesGroup(repositoryIDs, group: nil))
        }
        .help("Take this repository out of its sidebar group")
      }
    }
    .help("Group repositories under a named sidebar header")
  }
}
