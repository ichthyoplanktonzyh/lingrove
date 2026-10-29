import Foundation
import Testing
@testable import Lingrove

/// Locale routing is tested independently of the host Mac's language. Category descriptions
/// follow interface locales; lexical examples, source references and stable identities do not.
@MainActor
struct VocabularyCategoryLocalizationTests {
    private func category() -> VocabularyCategory {
        .init(id: UUID(), axis: .content, labels: [.init(text: "原名", language: .chinese)], definition: "原文定义",
            examples: [.init(text: "not", language: "en")], scopeNote: "原文范围", localizations: [
                .init(language: "en", name: "Negation", definition: "Denies a proposition.", scopeNote: "Different from refusal."),
                .init(language: "fr", name: "Négation"),
                .init(language: "zh-Hant", name: "否定", definition: "否定某個命題。"),
                .init(language: "id", name: "Penyangkalan"),
                .init(language: "tr", name: "Olumsuzlama"),
                .init(language: "pt-BR", name: "Negação")])
    }

    @Test func bundledCatalogCoversEveryInterfaceLocaleWithoutChangingExamples() throws {
        let catalog = try VocabularyClassificationCatalog.bundled()
        let required = Set(InterfaceLanguage.allCases.map(\.rawValue))
        #expect(catalog.version == 3)
        for category in catalog.categories {
            let rows = try #require(category.localizations)
            #expect(Set(rows.map(\.language)) == required)
            #expect(rows.count == required.count)
            for row in rows {
                #expect(!(row.name ?? "").isEmpty && !(row.definition ?? "").isEmpty && !(row.scopeNote ?? "").isEmpty)
            }
        }
        var index = VocabularyClassificationIndex()
        try catalog.install(in: &index, nodes: [])
        let category = try #require(index.categories.first { $0.key == "content.motion.arrival" })
        for language in InterfaceLanguage.allCases {
            let before = category.examples
            let resolved = VocabularyClassificationPolicy.presentation(category, in: index, interfaceIdentifiers: [language.rawValue])
            let authored = try #require(category.localizations.first { $0.language == language.rawValue })
            #expect(resolved.name == authored.name && resolved.definition == authored.definition && resolved.scopeNote == authored.scopeNote)
            #expect(category.examples == before)
        }
    }

    @Test func fieldsFallBackFromInterfaceToEnglishThenOriginal() {
        let category = category()
        let french = VocabularyCategoryLocalizationPolicy.presentation(category, identifiers: ["fr-CA", "zh-Hant"])
        #expect(french.name == "Négation")
        #expect(french.definition == "Denies a proposition." && french.scopeNote == "Different from refusal.")
        let unknown = VocabularyCategoryLocalizationPolicy.presentation(category, identifiers: ["zz"])
        #expect(unknown.name == "Negation")
        var originalOnly = category
        originalOnly.localizations = []
        #expect(VocabularyCategoryLocalizationPolicy.presentation(originalOnly, identifiers: ["de"]).definition == "原文定义")
        var partial = category
        partial.localizations[1].definition = ""
        #expect(VocabularyCategoryLocalizationPolicy.presentation(partial, identifiers: ["fr"]).definition.isEmpty)
    }

    @Test func regionAliasesAndInterfaceOnlyLanguagesResolveWithoutStudyLanguageCoercion() {
        let category = category()
        for (tag, expected) in [("zh_TW", "否定"), ("id-ID", "Penyangkalan"), ("tr-TR", "Olumsuzlama"), ("pt_BR", "Negação")] {
            #expect(VocabularyCategoryLocalizationPolicy.presentation(category, identifiers: [tag]).name == expected)
        }
        #expect(VocabularyCategoryLocalizationPolicy.editingLanguage(["tr-TR"]) == "tr")
        #expect(VocabularyCategoryLocalizationPolicy.editingLanguage(["zh-TW"]) == "zh-Hant")
        #expect(VocabularyCategoryLocalizationPolicy.matches(category, term: "Penyangkalan"))
        #expect(category.examples == [.init(text: "not", language: "en")])
    }

    @Test func legacyAndPerLanguageOverridesRetainAuthoredText() {
        let category = category()
        var index = VocabularyClassificationIndex(categories: [category], overrides: [
            .init(categoryID: category.id, definition: "旧的本地定义", localizations: [
                .init(language: "fr", definition: "Définition locale.")])])
        let french = VocabularyClassificationPolicy.presentation(category, in: index, interfaceIdentifiers: ["fr"])
        #expect(french.definition == "Définition locale.")
        #expect(french.name == "Négation")
        #expect(VocabularyClassificationPolicy.presentation(category, in: index, interfaceIdentifiers: ["en"]).definition == "旧的本地定义")
        index.overrides[0].localizations = nil
        index.overrides[0].definition = nil
        #expect(VocabularyClassificationPolicy.presentation(category, in: index, interfaceIdentifiers: ["fr"]).definition == "Denies a proposition.")
    }

    @Test func editingOneLanguagePreservesOtherTranslationsAndSourceExamples() throws {
        let category = category(), index = VocabularyClassificationIndex(categories: [category])
        let unchanged = VocabularyCategoryLocalizationPolicy.edited(category, in: index, language: "fr",
            name: "Négation", definition: "Denies a proposition.")
        #expect(unchanged.overlay == nil)
        let edited = VocabularyCategoryLocalizationPolicy.edited(category, in: index, language: "fr",
            name: "Nom local", definition: "Définition locale.")
        #expect(edited.category == category)
        var saved = index
        saved.overrides = [try #require(edited.overlay)]
        #expect(VocabularyClassificationPolicy.presentation(category, in: saved, interfaceIdentifiers: ["fr"]).name == "Nom local")
        #expect(VocabularyClassificationPolicy.presentation(category, in: saved, interfaceIdentifiers: ["en"]).name == "Negation")
        #expect(VocabularyClassificationPolicy.effective(category, in: saved).examples == category.examples)
        let restored = VocabularyCategoryLocalizationPolicy.edited(category, in: saved, language: "fr",
            name: "Négation", definition: "Denies a proposition.", restoringDefaults: true)
        #expect(restored.overlay == nil)
    }

    @Test func newCustomCategoryKeepsInterfaceLanguageWithoutChangingStudyLanguages() throws {
        let original = VocabularyCategory(id: UUID(), axis: .content, labels: [.init(text: "")])
        var result = VocabularyCategoryLocalizationPolicy.edited(original, in: .init(), language: "tr",
            name: "Özel kategori", definition: "Yerel tanım.")
        #expect(result.category.labels.first?.language == nil)
        result.category.examples = [.init(text: "değil", language: "tr"), .init(text: "tidak", language: "id")]
        #expect(result.category.localizations.first?.language == "tr")
        try VocabularyClassificationPolicy.validate(.init(categories: [result.category]), nodes: [])
    }

    @Test func duplicateLocalesAndEmptyTranslationRowsAreRejected() throws {
        var category = category()
        category.localizations += [.init(language: "EN", name: "Duplicate")]
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyClassificationPolicy.validate(.init(categories: [category]), nodes: [])
        }
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyCategoryLocalizationPolicy.validate([.init(language: "../en", name: "Invalid")])
        }
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyCategoryLocalizationPolicy.validate([.init(language: "en")])
        }
    }
}
