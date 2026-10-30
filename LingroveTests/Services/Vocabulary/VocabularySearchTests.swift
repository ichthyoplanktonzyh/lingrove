import Foundation
import Testing
@testable import Lingrove

/// Ordinary tests use keyword fallback and an isolated archive. The explicit model fixture adds
/// actual cross-language recall without downloading weights or touching user settings in CI.
@Suite(.serialized)
@MainActor
struct VocabularySearchTests {
    @Test func keywordFallbackTracksCollectionEditsAndLanguageScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        await store.save(.init(expression: "postpone", dictionaryForm: "postpone", language: .english, kind: .word, meaning: "延期"))
        await store.save(.init(expression: "reporter", dictionaryForm: "reporter", language: .french, kind: .word, meaning: "延期"))
        let search = VocabularySearchController(store: store, directoryURL: directory, cacheURL: nil)
        search.activate()
        defer { search.suspend() }
        search.search("延期", language: .french, tag: "")
        try await settle { !search.isSearching && search.results.count == 1 }
        #expect(search.status == .notInstalled)
        #expect(search.results.first?.document.expression == "reporter")
        await store.save(.init(expression: "remettre", dictionaryForm: "remettre", language: .french, kind: .word, meaning: "延期"))
        try await settle { !search.isSearching && search.results.count == 2 }
        search.search("postpone", language: .english, tag: "missing")
        try await settle { !search.isSearching }
        #expect(search.results.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aNewQueryOrClosureCannotPublishOldResults() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        await store.save(.init(expression: "postpone", dictionaryForm: "postpone", language: .english, kind: .word, meaning: "延期"))
        let search = VocabularySearchController(store: store,
            directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), cacheURL: nil)
        search.activate()
        search.search("延期", language: nil, tag: "")
        search.search("unmatched", language: nil, tag: "")
        try await settle { !search.isSearching }
        #expect(search.results.isEmpty)
        search.search("延期", language: nil, tag: "")
        search.suspend()
        try await Task.sleep(for: .milliseconds(300))
        #expect(search.results.isEmpty)
    }

    @Test func corruptModelFallsBackAndCanBeRemovedWithoutLosingTheCollection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(VocabularySearchCatalog.model.filename)
        try Data("invalid model".utf8).write(to: url)
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        await store.save(.init(expression: "postpone", dictionaryForm: "postpone", language: .english, kind: .word, meaning: "延期"))
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let downloads = ModelDownloadManager(runtimeDirectoryURL: directory, assetCatalog: [VocabularySearchCatalog.model],
            taskAssignments: .init(defaults: defaults))
        let search = VocabularySearchController(store: store, directoryURL: directory, cacheURL: nil, downloads: downloads)
        search.activate()
        defer { search.suspend() }
        search.search("延期", language: nil, tag: "")
        try await settle {
            if case .failed = search.status { return !search.isSearching && search.results.count == 1 }
            return false
        }
        await search.removeModel()
        try await settle { search.status == .notInstalled && !search.isSearching && search.results.count == 1 }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.entries.count == 1)
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_SEARCH_MODEL_PATH"] != nil))
    func realModelRetrievesAcrossEveryStudyLanguageAndReusesCache() async throws {
        let path = try #require(LingroveCompatibility.processEnvironment["LINGROVE_SEARCH_MODEL_PATH"])
        let modelURL = URL(fileURLWithPath: path)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cacheURL = folder.appendingPathComponent("vectors.json")
        let index = VocabularySearchIndex(cacheURL: cacheURL)
        let entries = Self.multilingualEntries()
        let documents = VocabularySearchPolicy.documents(entries: entries, semantics: .init())
        try await index.reconcile(documents, modelURL: modelURL) { _, _ in }
        let queries = ["把原来定好的事情往后挪一些", "Do the planned event at a later date",
            "予定をもっと後の日にずらしたい", "Déplacer un événement prévu à une date ultérieure",
            "تأجيل الموعد إلى وقت لاحق", "तय कार्यक्रम को बाद की तारीख पर करना"]
        let unrelated = ["形容火山正在喷发", "A bright red sunset over the ocean", "鳥が南へ渡っていく",
            "Décrire le parfum des fleurs", "وصف الموسيقى الهادئة", "रेगिस्तान की गर्म रेत का वर्णन"]
        for (position, language) in LearningLanguage.allCases.enumerated() {
            let scoped = documents.filter { $0.language == language }
            #expect(scoped.count == 3)
            let expected = try #require(scoped.first?.id)
            let hits = try await index.search(queries[position % queries.count], documents: scoped, modelURL: modelURL)
            #expect(hits.first?.id == expected, "Cross-language recall failed for \(language.rawValue)")
            let absent = try await index.search(unrelated[position % unrelated.count], documents: scoped, modelURL: modelURL)
            #expect(absent.isEmpty, "Unrelated cross-language query was admitted for \(language.rawValue)")
        }
        let now = Date()
        let idioms = [("sleep on it", "Delay making a decision until after a night's rest"),
            ("keep me posted", "Continue telling someone about new developments in an ongoing situation"),
            ("rule out", "Exclude a possibility from consideration"),
            ("on the fence", "Undecided between alternatives"),
            ("on the same page", "Share an understanding or agreement")].map { expression, meaning in
                VocabularyEntry(id: UUID(), expression: expression, dictionaryForm: expression, language: .english,
                    kind: .expression, senses: [.init(id: UUID(), meaning: meaning, createdAt: now, updatedAt: now)],
                    createdAt: now, updatedAt: now)
            }
        let idiomDocuments = VocabularySearchPolicy.documents(entries: idioms, semantics: .init())
        try await index.reconcile(documents + idiomDocuments, modelURL: modelURL) { _, _ in }
        // The ambiguous paraphrase is retained in the relevance corpus with its results
        // reported. A top-ranked vector alone no longer qualifies as a successful retrieval.
        let descriptions = [("这个决定等一晚再说", "sleep on it"),
            ("有啥新消息记得跟我说", "keep me posted"), ("目前可以排除这种可能性", "rule out"),
            ("まだどちらにするか決められない", "on the fence"),
            ("Tiens-moi au courant de l'évolution de la situation", "keep me posted")]
        for (query, expected) in descriptions {
            let hits = try await index.search(query, documents: idiomDocuments, modelURL: modelURL)
            #expect(hits.first?.document.expression == expected, "Natural description recall failed: \(query)")
        }
        await index.unload()
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        // Restoring a complete cache needs no model load. A missing model URL would fail if
        // reconciliation accidentally tried to re-embed unchanged documents after relaunch.
        let restored = VocabularySearchIndex(cacheURL: cacheURL)
        try await restored.reconcile(documents + idiomDocuments, modelURL: folder.appendingPathComponent("missing.gguf")) { _, _ in }
        let changed = Array(documents.dropFirst())
        try await restored.reconcile(changed, modelURL: modelURL) { _, _ in }
        let data = try Data(contentsOf: cacheURL)
        #expect(!String(decoding: data, as: UTF8.self).contains("postpone"))
        let snapshot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vectors = try #require(snapshot["vectors"] as? [String: Any])
        #expect(vectors[documents[0].fingerprint] == nil)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(25))
            if condition() { return }
        }
        Issue.record("Search did not settle")
    }

    private static func multilingualEntries() -> [VocabularyEntry] {
        let meanings: [LearningLanguage: [String]] = [
            .english: ["postpone: move a scheduled event to a later time", "cancel: decide a planned event will not happen", "approve: agree to a proposal"],
            .chinese: ["延期：将原定的事情推迟到以后进行", "取消：使原定的事情不再进行", "批准：同意某项提议"],
            .traditionalChinese: ["延期：將原定的事情推遲到以後進行", "取消：使原定的事情不再進行", "批准：同意某項提議"],
            .japanese: ["延期する：予定の行事を後の日に延ばす", "中止する：予定の行事を行わないことにする", "承認する：提案に同意する"],
            .korean: ["연기하다: 예정된 일을 더 나중에 하다", "취소하다: 예정된 일을 하지 않기로 하다", "승인하다: 제안에 동의하다"],
            .french: ["reporter : déplacer un événement prévu à une date ultérieure", "annuler : décider qu'un événement prévu n'aura pas lieu", "approuver : accepter une proposition"],
            .german: ["verschieben: eine geplante Veranstaltung auf einen späteren Zeitpunkt verlegen", "absagen: eine geplante Veranstaltung nicht stattfinden lassen", "genehmigen: einem Vorschlag zustimmen"],
            .spanish: ["posponer: trasladar un evento previsto a una fecha posterior", "cancelar: decidir que un evento no se celebrará", "aprobar: aceptar una propuesta"],
            .italian: ["rinviare: spostare un evento previsto a una data successiva", "annullare: decidere che un evento non avrà luogo", "approvare: accettare una proposta"],
            .portuguese: ["adiar: mudar um evento previsto para uma data posterior", "cancelar: decidir que um evento não acontecerá", "aprovar: aceitar uma proposta"],
            .dutch: ["uitstellen: een geplande gebeurtenis naar een later tijdstip verplaatsen", "annuleren: besluiten dat een gebeurtenis niet doorgaat", "goedkeuren: instemmen met een voorstel"],
            .russian: ["отложить: перенести запланированное событие на более позднее время", "отменить: решить, что событие не состоится", "одобрить: согласиться с предложением"],
            .hindi: ["स्थगित करना: तय कार्यक्रम को बाद की तारीख पर करना", "रद्द करना: तय कार्यक्रम न करने का फैसला करना", "मंजूरी देना: प्रस्ताव से सहमत होना"],
            .arabic: ["تأجيل: نقل حدث مقرر إلى وقت لاحق", "إلغاء: اتخاذ قرار بعدم إقامة حدث مقرر", "موافقة: قبول اقتراح"]
        ]
        let now = Date()
        return LearningLanguage.allCases.flatMap { language in
            (meanings[language] ?? []).map { meaning in
                VocabularyEntry(id: UUID(), expression: meaning.components(separatedBy: CharacterSet(charactersIn: ":：")).first ?? meaning,
                    dictionaryForm: "", language: language, kind: .word,
                    senses: [.init(id: UUID(), meaning: meaning, createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
            }
        }
    }
}
