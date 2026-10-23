import SwiftUI

/// Expanding this reference area is an explicit dictionary query. It borrows the window's
/// session and the same source picker/renderer used by floating cards; nothing is copied into
/// the vocabulary archive. Collapse and window closure retire outstanding provider work.
struct VocabularyDictionarySection: View {
    let entry: VocabularyEntry
    @ObservedObject var learning: VocabularyNotebookSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var hoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.94)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "character.book.closed")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(expanded ? CotabbyBrand.accent : .secondary)
                    Text(String(localized: "Dictionary", table: "Vocabulary"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if entry.dictionaryForm != entry.expression {
                        Text(entry.dictionaryForm)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringHeader = $0 }
            .background(Color.primary.opacity(hoveringHeader && !expanded ? 0.025 : 0))

            if expanded {
                Divider().opacity(0.5)
                VocabularyLiveDictionaryContent(session: learning.dictionary)
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded { learning.showDictionary(entry) } else { learning.hideDictionary() }
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
