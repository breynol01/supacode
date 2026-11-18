import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct WorktreeCustomizationView: View {
  @Bindable var store: StoreOf<WorktreeCustomizationFeature>
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case title
    case folder
  }

  var body: some View {
    Form {
      Section {
        TextField("Title", text: $store.title, prompt: Text(store.defaultName))
          .focused($focusedField, equals: .title)
          .onSubmit {
            store.send(.saveButtonTapped)
          }
        LabeledContent("Color") {
          ColorSwatchRow(color: $store.color)
        }
      } header: {
        Text("Customize Appearance")
        Text("Override the sidebar title and tint for `\(store.defaultName)`.")
      }
      .headerProminence(.increased)
      if store.supportsFolder {
        Section {
          TextField("Folder", text: $store.folder, prompt: Text("None"))
            .focused($focusedField, equals: .folder)
            .textInputSuggestions {
              ForEach(store.existingFolders, id: \.self) { name in
                Text(name).textInputCompletion(name)
              }
            }
            .onSubmit {
              store.send(.saveButtonTapped)
            }
            .help("Group this worktree under a named sidebar folder. Leave empty to remove it.")
        } footer: {
          Text("Worktrees with the same folder are grouped together in this repository's section.")
        }
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button("Save") {
          store.send(.saveButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Save (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { focusedField = store.focusesFolderOnAppear ? .folder : .title }
    .dismissSystemColorPanelOnDisappear()
  }
}
