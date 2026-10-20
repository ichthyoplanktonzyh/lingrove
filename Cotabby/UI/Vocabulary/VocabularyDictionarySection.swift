import SwiftUI

/// Expanding this reference area is an explicit dictionary query. It borrows the window's
/// session and the same source picker/renderer used by floating cards; nothing is copied into
/// the vocabulary archive. Collapse and window closure retire outstanding provider work.
struct VocabularyDictionarySection: View {
    let entry: VocabularyEntry
    @ObservedObject var learning: VocabularyNotebookSession
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(String(localized: "Dictionary", table: "Vocabulary"), isExpanded: $expanded) {
            VocabularyLiveDictionaryContent(session: learning.dictionary)
                .padding(.top, 8)
        }
        .onChange(of: expanded) { _, expanded in
            if expanded { learning.showDictionary(entry) } else { learning.hideDictionary() }
        }
        .onChange(of: entry.dictionaryForm) { _, _ in if expanded { learning.showDictionary(entry) } }
        .onDisappear {
            if learning.dictionary.documentID == entry.id { learning.hideDictionary() }
        }
    }
}

/// The notebook's normal window supplies its available width. A bounded viewport uses the
/// existing measurement policy so switching dictionary sources keeps the first settled height.
private struct VocabularyLiveDictionaryContent: View {
    @ObservedObject var session: LearningDictionarySession
    @State private var viewport = LearningDictionaryViewport()
    @State private var measuredHTML: UUID?

    var body: some View {
        let query = session.query, requestID = session.requestIdentity
        let resolved: Bool = switch session.content {
        case .result(.article(let article)): article.html.isEmpty || measuredHTML == requestID
        case .result(.entries), .result(.systemText): true
        default: false
        }
        VStack(alignment: .leading, spacing: 10) {
            LearningDictionarySourcePicker(session: session)
            ScrollView {
                LearningDictionaryDefinitionView(session: session, measured: { measuredHTML = $0 })
                    .id(requestID)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard session.requestIdentity == requestID else { return }
                        viewport.measure(height, query: query, resolved: resolved)
                    }
            }.frame(height: viewport.height(for: query))
            LearningDictionaryAttribution(session: session).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
