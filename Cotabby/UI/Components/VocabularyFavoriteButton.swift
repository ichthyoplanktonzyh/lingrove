import SwiftUI

/// One visual contract for every collection action. The assets preserve the approved fish-tail
/// SVG; template rendering lets the same geometry adapt to card materials and dark appearance.
struct VocabularyFavoriteIcon: View {
    var isSaved = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Image(isSaved ? "FavoriteFishFilled" : "FavoriteFishOutline")
            .resizable().renderingMode(.template).scaledToFit()
            .foregroundStyle(isSaved
                ? (colorScheme == .dark ? Color(red: 10 / 255, green: 132 / 255, blue: 1) : CotabbyBrand.accent)
                : Color.secondary)
            .accessibilityHidden(true)
    }
}

/// The card supplies one immutable capture. A successful disk transaction changes the fish to
/// blue; pending/failed writes never masquerade as saved. Reopening the library is explicit.
struct VocabularyFavoriteButton: View {
    @ObservedObject var store: VocabularyStore
    let capture: VocabularyCapture
    @Environment(\.learningInteraction) private var interact
    @State private var showsActions = false
    @State private var failure: String?
    @Environment(\.learningFavoriteMenu) private var hostedMenu
    private var menu: Binding<Bool> { hostedMenu ?? $showsActions }

    var body: some View {
        Button {
            interact()
            if store.contains(capture) { menu.wrappedValue = true } else {
                Task {
                    await store.save(capture)
                    failure = store.errorMessage
                }
            }
        } label: {
            Group {
                if store.isPending(capture) {
                    ProgressView().controlSize(.mini)
                } else {
                    VocabularyFavoriteIcon(isSaved: store.contains(capture))
                }
            }
            .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .learningAction(.favorite)
        .disabled(store.isPending(capture))
        .help(failure ?? (store.contains(capture)
            ? String(localized: "Saved · Show actions", table: "Vocabulary")
            : String(localized: "Save to vocabulary", table: "Vocabulary")))
        .accessibilityLabel(String(localized: "Save to vocabulary", table: "Vocabulary"))
        .accessibilityValue(store.contains(capture)
            ? String(localized: "Saved", table: "Vocabulary") : String(localized: "Not saved", table: "Vocabulary"))
        .task { store.loadIfNeeded() }
        .popover(isPresented: menu) {
            VStack(alignment: .leading, spacing: 12) {
                Button(String(localized: "Show in vocabulary", table: "Vocabulary")) {
                    menu.wrappedValue = false
                    store.show(capture)
                }
                Button(String(localized: "Remove this saved usage", table: "Vocabulary")) {
                    menu.wrappedValue = false
                    Task { await store.remove(capture); failure = store.errorMessage }
                }
            }.buttonStyle(.plain).padding(14)
        }
        .alert(String(localized: "Could not save vocabulary", table: "Vocabulary"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }
}
