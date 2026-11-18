import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

@Reducer
struct RepositoryCustomizationFeature {
  @ObservableState
  struct State: Equatable {
    let repositoryID: Repository.ID
    let defaultName: String
    var title: String
    var color: RepositoryColor?
    /// Whether the sheet offers Title / Color. `false` for folder-kind
    /// repositories, whose appearance lives on their row, so the sheet only
    /// edits the group.
    var supportsAppearance: Bool = true
    /// Sidebar group input; blank means "ungrouped".
    var group: String = ""
    /// Group names already in use, offered as suggestions.
    var existingGroups: [String] = []
    /// Focus the Group field instead of Title when the sheet appears
    /// ("New Group…" from the menu).
    var focusesGroupOnAppear: Bool = false
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case saveButtonTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case save(repositoryID: Repository.ID, title: String?, color: RepositoryColor?, group: String? = nil)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .saveButtonTapped:
        let trimmed = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve verbatim; typing the default name locks it in as an override.
        let resolvedTitle = trimmed.isEmpty ? nil : trimmed
        return .send(
          .delegate(
            .save(
              repositoryID: state.repositoryID,
              title: resolvedTitle,
              color: state.color,
              group: SidebarFolderName.normalized(state.group)
            )
          )
        )

      case .delegate:
        return .none
      }
    }
  }
}
