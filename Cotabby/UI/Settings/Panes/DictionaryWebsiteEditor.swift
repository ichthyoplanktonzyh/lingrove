import SwiftUI

/// A disposable draft leaves persisted settings untouched until Save. Editing retains the
/// source identity, priority and explicit enabled state rather than adding a second source.
struct DictionaryWebsiteEditor: View {
    let website: DictionaryWebsite
    let save: (DictionaryWebsite) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ""
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 200 &&
            DictionaryWebsitePolicy.url(template: template, query: "example") != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Lookup website", table: "Learning")).font(.headline)
            Form {
                TextField(String(localized: "Name", table: "Learning"), text: $name)
                TextField(String(localized: "HTTPS URL with {query}", table: "Learning"), text: $template)
                    .autocorrectionDisabled()
            }
            HStack {
                Button(String(localized: "Cancel", table: "Learning")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Save", table: "Learning")) {
                    save(.init(id: website.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), template: template))
                    dismiss()
                }.disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460)
            .onAppear { name = website.name; template = website.template }
    }
}
