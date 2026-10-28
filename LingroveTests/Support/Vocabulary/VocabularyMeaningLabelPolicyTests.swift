import Foundation
import Testing
@testable import Lingrove

/// Display fallbacks must never become mutations or language guesses. In particular, an
/// explicit explanation preference and a study-language filter serve different purposes.
struct VocabularyMeaningLabelPolicyTests {
    @Test func displayPreferenceNormalizesRegionsAndKeepsChineseScriptsDistinct() {
        let preferred = VocabularyMeaningLabelPolicy.preferredLanguages(explanation: .japanese,
            interfaceIdentifiers: ["zh_Hant_TW", "en-US", "ja-JP", "pt-BR", "id-ID"])
        #expect(preferred == [.japanese, .traditionalChinese, .english, .portuguese])
        #expect(VocabularyMeaningLabelPolicy.language(for: "zh-Hans-HK") == .chinese)
        #expect(VocabularyMeaningLabelPolicy.language(for: "zh-TW") == .traditionalChinese)
        #expect(VocabularyMeaningLabelPolicy.language(for: "zh") == nil)
        #expect(VocabularyMeaningLabelPolicy.language(for: "unsupported") == nil)
    }

    @Test func existingLabelsFollowThePreferredLanguageBeforeOtherPreferredNames() {
        let node = VocabularyMeaningNode(id: UUID(), labels: [
            .init(text: "Postponement", language: .english),
            .init(text: "推迟安排", language: .chinese),
            .init(text: "Reporter un événement", language: .french, preferred: false)
        ])
        #expect(node.title(in: [.chinese, .english]) == "推迟安排")
        #expect(node.title(in: [.french, .english]) == "Reporter un événement")
        #expect(node.title(in: [.japanese, .chinese]) == "推迟安排")
        #expect(node.title(in: [.traditionalChinese]) == "Postponement")
        #expect(node.labels[0].text == "Postponement")
    }

    @Test func untaggedFallbackKeepsItsActualLanguageAndIdentityDuringAnEdit() throws {
        let original = VocabularyMeaningNode(id: UUID(), labels: [
            .init(text: "既有名称", language: nil), .init(text: "Existing name", language: .english)
        ], definition: "Original description")
        let chosen = try #require(VocabularyMeaningLabelPolicy.label(for: original, languages: [.japanese]))
        #expect(chosen.language == nil)
        let updated = VocabularySemanticEditingPolicy.rename(original, title: "修订名称", definition: original.definition,
            labelID: chosen.id)
        #expect(updated.labels[0].id == chosen.id && updated.labels[0].language == nil)
        #expect(updated.labels[1] == original.labels[1])
    }

    @Test func localizedRenameUpdatesOnlyTheNameActuallyShownToTheUser() throws {
        let original = VocabularyMeaningNode(id: UUID(), labels: [
            .init(text: "Postponement", language: .english), .init(text: "推迟安排", language: .chinese),
            .init(text: "Report", language: .french)
        ])
        let label = try #require(VocabularyMeaningLabelPolicy.label(for: original, languages: [.french, .english]))
        let edited = VocabularySemanticEditingPolicy.rename(original, title: "Report d’un événement", definition: "",
            labelID: label.id)
        #expect(edited.labels[0...1] == original.labels[0...1])
        #expect(edited.labels[2].id == label.id && edited.labels[2].language == .french)
        #expect(edited.title(in: [.french]) == "Report d’un événement")
    }
}
