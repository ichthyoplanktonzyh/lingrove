import SwiftUI

/// One visual contract for every collection action. The assets preserve the approved fish-tail
/// SVG; template rendering lets the same geometry adapt to card materials and dark appearance.
struct VocabularyFavoriteIcon: View {
    var isSaved = false
    var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Image(isSaved ? "FavoriteFishFilled" : "FavoriteFishOutline")
            .resizable().renderingMode(.template).scaledToFit()
            .foregroundStyle(isSaved
                ? (colorScheme == .dark ? Color(red: 10 / 255, green: 132 / 255, blue: 1) : LingroveBrand.accent)
                : (isHovered ? Color.primary : Color.secondary))
            .accessibilityHidden(true)
    }
}

/// The card supplies one immutable capture. A successful disk transaction changes the fish to
/// blue; pending/failed writes never masquerade as saved. Once saved, the menu only opens
/// the library. Sense/example deletion belongs to the explicit notebook detail editor.
struct VocabularyFavoriteButton: View {
    @ObservedObject var store: VocabularyStore
    let capture: VocabularyCapture
    @Environment(\.learningInteraction) private var interact
    @State private var showsActions = false
    @State private var failure: String?
    @State private var hovering = false
    @State private var saved: Bool?
    @Environment(\.learningFavoriteMenu) private var hostedMenu
    private var menu: Binding<Bool> { hostedMenu ?? $showsActions }

    var body: some View {
        Button {
            interact()
            if saved == true { menu.wrappedValue = true } else {
                Task { [scope = store.operationScope] in
                    await store.save(capture, scope: scope)
                    failure = store.errorMessage
                    saved = await store.savedStatus(capture)
                }
            }
        } label: {
            Group {
                if store.isPending(capture) || saved == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    VocabularyFavoriteIcon(isSaved: saved == true, isHovered: hovering)
                }
            }
            .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(LearningIconActionButtonStyle(hovering: hovering, isEnabled: !store.isPending(capture)))
        .onHover { hovering = $0 }
        .learningAction(.favorite)
        .disabled(store.isPending(capture) || saved == nil)
        .help(failure ?? (saved == true
            ? String(localized: "Saved · Show actions", table: "Vocabulary")
            : String(localized: "Save to vocabulary", table: "Vocabulary")))
        .accessibilityLabel(String(localized: "Save to vocabulary", table: "Vocabulary"))
        .accessibilityValue(saved == nil ? String(localized: "Loading") : saved == true
            ? String(localized: "Saved", table: "Vocabulary") : String(localized: "Not saved", table: "Vocabulary"))
        .task(id: statusIdentity) {
            // Unknown is visibly pending, never "not saved" merely because its page is absent.
            saved = nil
            let result = await store.savedStatus(capture)
            guard !Task.isCancelled else { return }
            saved = result
        }
        .onChange(of: store.scopeIdentity) { _, _ in menu.wrappedValue = false; failure = nil }
        .popover(isPresented: menu) {
            VStack(alignment: .leading, spacing: 12) {
                Button(String(localized: "Show in vocabulary", table: "Vocabulary")) {
                    menu.wrappedValue = false
                    store.show(capture)
                }
            }.buttonStyle(.plain).padding(14)
        }
        .alert(String(localized: "Could not save vocabulary", table: "Vocabulary"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }

    private var statusIdentity: String {
        store.scopeIdentity.uuidString + store.contentRevision.uuidString + store.savedStatusRevision.uuidString
            + VocabularyPolicy.captureKey(capture) + (capture.senseID?.uuidString ?? "")
    }
}
