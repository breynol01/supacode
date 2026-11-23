import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct RepositoryCustomizationView: View {
  @Bindable var store: StoreOf<RepositoryCustomizationFeature>
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case title
    case group
  }

  var body: some View {
    Form {
      if store.supportsAppearance {
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
      }
      Section {
        TextField("Group", text: $store.group, prompt: Text("None"))
          .focused($focusedField, equals: .group)
          .textInputSuggestions {
            ForEach(store.existingGroups, id: \.self) { name in
              Text(name).textInputCompletion(name)
            }
          }
          .onSubmit {
            store.send(.saveButtonTapped)
          }
          .help("Show this repository under a named sidebar group. Leave empty to remove it.")
      } header: {
        if !store.supportsAppearance {
          Text("Sidebar Group")
          Text("Group `\(store.defaultName)` with related repositories.")
        }
      } footer: {
        Text("Repositories with the same group are listed together under a collapsible header.")
      }
      .headerProminence(.increased)
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
    .task { focusedField = store.focusesGroupOnAppear || !store.supportsAppearance ? .group : .title }
    .dismissSystemColorPanelOnDisappear()
  }
}
