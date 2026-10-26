import AppKit
import Combine
import Foundation

/// Fixed learning material belongs to this walkthrough, rather than to a live editor capture.
/// The existing card/session/store APIs consume these same domain values in production.
@MainActor
enum HomeLearningDemoFixtures {
    static let source = "请随时告诉我项目的最新进展。"
    static let translation = "Please keep me posted on the project's progress."
    static let ocrSource = "Please keep me posted on the project's progress.\nI'll send an update tomorrow."
    static let ocrTranslation = "请随时告诉我项目的最新进展。\n我明天会发送更新。"
    static let context = "Thanks for your help. " + translation
    static let expression = "keep me posted"
    static let pattern = "keep someone posted"
    static let meaning = "随时告知某人最新进展"
    static let explanation = "keep someone posted 表示持续向某人提供最新消息。这里的 me 是接收消息的人，posted 的意思是 informed；整句是在请对方随时告知项目进展。"
    static let documentID = UUID()
    static var input: LearningExplanationInput { LearningExplanationPolicy.input(capture) }
    static var unit: LearningUnit {
        .init(id: 0, surface: expression, query: pattern, kind: .pattern,
            ranges: capture.example?.ranges.map(\.nsRange) ?? [],
            words: LearningUnitPolicy.words(in: translation, language: .english).filter { word in
                capture.example?.ranges.contains { NSLocationInRange(word.range.location, $0.nsRange) } == true
            })
    }
    static var capture: VocabularyCapture {
        let range = (translation as NSString).range(of: expression)
        let example = VocabularyExample(id: documentID, text: translation, translation: source, translationLanguage: .chinese,
            ranges: [.init(range)], completeness: .sentence, meaning: meaning, meaningLanguage: .chinese, createdAt: Date())
        return .init(expression: expression, dictionaryForm: pattern, language: .english, kind: .pattern,
            meaning: meaning, meaningLanguage: .chinese, example: example)
    }
    static func record(_ input: LearningExplanationInput) -> LearningExplanationRecord {
        let result: LearningExplanationResult
        if input.kind == .sentence {
            result = .init(meaning: input.target == ocrSource ? ocrTranslation : input.language == .english ? source : translation,
                explanation: "这句话礼貌地请求对方持续告知项目进展。Please 表示礼貌请求；keep me posted 是固定表达，on 引出需要持续了解的话题。")
        } else if input.dictionaryForm == pattern || input.target == expression {
            result = .init(meaning: meaning, explanation: explanation)
        } else if input.target == "bank", input.context.contains("river") {
            result = .init(meaning: "河岸", explanation: "这里的 bank 指河流旁的陆地；of the river 明确了它与河流的关系。")
        } else {
            let gloss = gloss(input.target)
            result = .init(meaning: gloss.meaning, explanation: gloss.detail)
        }
        return .init(id: UUID(), input: input, language: .chinese,
            result: result,
            model: String(localized: "AI explanation", table: "Learning"), createdAt: Date())
    }
    nonisolated static func gloss(_ query: String) -> (meaning: String, detail: String) {
        let values: [String: (meaning: String, detail: String)] = [
            "posted": ("获知最新情况", "posted 在 keep someone posted 中表示 informed，不是“邮寄”；这里是在请对方告知项目进展。"),
            "keep": ("使……保持某种状态", "keep + 宾语 + 过去分词表示使某人保持某种状态；keep me posted 即让我持续了解最新情况。"),
            "me": ("我", "me 是人称代词 I 的宾格，在这里作 keep 的宾语，指接收消息的人。"),
            "progress": ("进展", "progress 是不可数名词，这里指项目推进的情况。"),
            "project": ("项目", "project 指正在推进的项目，project's 是所有格，修饰 progress。"),
            "please": ("请", "Please 用于祈使句开头，让请求更礼貌。"),
            "on": ("关于", "on 在这里引出消息涉及的话题，即项目进展。"),
            "the": ("这个／这些（特指）", "定冠词 the 表明双方知道谈论的是哪个项目。"),
            "bank": ("银行", "在 deposited money 的语境中，bank 指提供存款服务的银行。"),
            "keep someone posted": ("随时告知某人最新进展", "Keep someone informed about the latest developments.")
        ]
        let key = query.lowercased().replacingOccurrences(of: "project's", with: "project")
            .replacingOccurrences(of: "keep me posted", with: "keep someone posted")
        return values[key] ?? (query, "此演示仅包含固定示例；实际查词使用你所选择的 AI 和词典来源。")
    }

    static var seedCaptures: [VocabularyCapture] {
        [
            seed("bank", sentence: "She deposited money at the bank.", meaning: "银行，提供存款等金融服务的机构"),
            seed("bank", sentence: "They sat on the bank of the river.", meaning: "河岸，河流边的陆地"),
            seed("look forward to", sentence: "I look forward to seeing you.", meaning: "期待某事或做某事", kind: .expression),
            seed("take a break", sentence: "Let's take a break after this meeting.", meaning: "暂时休息一下", kind: .expression)
        ]
    }
    private static func seed(_ word: String, sentence: String, meaning: String,
                             kind: VocabularyEntry.Kind = .word) -> VocabularyCapture {
        .init(expression: word, dictionaryForm: word, language: .english, kind: kind, meaning: meaning, meaningLanguage: .chinese,
            example: .init(id: UUID(), text: sentence, translation: "", ranges: [.init((sentence as NSString).range(of: word))],
                completeness: .sentence, meaning: meaning, meaningLanguage: .chinese, createdAt: Date()))
    }
}

/// The real explanation session owns cancellation, loading, restore and regenerate behavior.
/// This small provider supplies a reviewed example response without creating a model runtime.
@MainActor
final class HomeDemoExplainer: LearningLookupGenerating {
    let changes = Empty<Void, Never>().eraseToAnyPublisher()
    let language = LearningLanguage.chinese
    let isConfigured = true
    private var saved: [LearningExplanationInput: LearningExplanationRecord] = [:]
    func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        try await Task.sleep(for: .milliseconds(750))
        try Task.checkCancellation()
        let record = HomeLearningDemoFixtures.record(input)
        saved[input] = record
        return record
    }
    func savedRecord(for input: LearningExplanationInput) -> LearningExplanationRecord? { saved[input] }
    func lookup(_ input: LearningLookupInput, requestID: String, refresh: Bool) async throws -> LearningLookupRecord {
        let record = try await generate(input.target, requestID: requestID, refresh: refresh)
        return .init(input: input, language: language,
            result: .init(meaning: record.result.meaning,
                sentenceTranslation: input.target.contextKind == .none ? ""
                    : input.referenceTranslation.isEmpty ? HomeLearningDemoFixtures.source : input.referenceTranslation),
            model: record.model, createdAt: record.createdAt)
    }
    func explainLookup(_ record: LearningLookupRecord, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        let details = try await generate(record.input.target, requestID: requestID, refresh: refresh)
        return .init(id: details.id, input: details.input, language: details.language,
            result: .init(meaning: record.result.meaning, explanation: details.result.explanation),
            model: details.model, createdAt: details.createdAt)
    }
    func recordDisplay(requestID: String) { }
}

/// Source switching uses the production dictionary session and picker. Both sample sources
/// return local material, leaving import, HTTP and system-dictionary process ownership untouched.
nonisolated struct HomeDemoDictionary: LearningDictionaryProviding {
    func lookup(_ query: String, language: LearningLanguage?, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        try await Task.sleep(for: .milliseconds(250))
        let gloss = HomeLearningDemoFixtures.gloss(query)
        if source == .system { return .systemText("\(query)\n\(gloss.meaning)\n\(gloss.detail)") }
        return .entries([.init(id: "home-example", language: "en", headword: query, forms: [],
            senses: [.init(partOfSpeech: expression ? "verb phrase" : "word", definitions: [gloss.meaning, gloss.detail], labels: [])],
            sourceURL: "", examples: ["Please keep me posted on the project's progress."])])
    }
}

/// System-only demonstration playback cannot accidentally construct the local/endpoint generator.
nonisolated struct HomeDemoAudioGenerator: SpeechAudioGenerating {
    func generate(for request: SpeechAudioRequest, receive: @escaping SpeechAudioReceiver) async throws { throw CancellationError() }
    func cancel(_ token: SpeechPlaybackToken) async { }
    func shutdown() async { }
}

/// The real Anki draft, serializer and receipt flow speak their normal protocol to a tiny local
/// sample collection. This keeps Add/Update feedback truthful without implementing another editor.
actor HomeDemoAnki: AnkiConnecting {
    private var notes: [Int64: [String: AnkiValue]] = [:]
    private var media: Set<String> = []
    func perform(_ action: String, params: [String: AnkiValue], connection: AnkiConnection) async throws -> AnkiValue {
        if let value = metadata(action, params: params) { return value }
        switch action {
        case "findNotes":
            return matchingNotes(params["query"]?.string ?? "")
        case "addNote":
            let id = Int64(notes.count + 1)
            notes[id] = params["note"]?.object
            return .number(Double(id))
        case "updateNoteFields":
            if let update = params["note"]?.object, let id = update["id"]?.integer {
                notes[id]?["fields"] = update["fields"]
            }
            return .null
        case "notesInfo":
            return notesInfo(params["notes"]?.array ?? [])
        case "getMediaFilesNames": return .list(media.filter { $0 == params["pattern"]?.string })
        case "storeMediaFile":
            guard let filename = params["filename"]?.string else { return .null }
            media.insert(filename)
            return .string(filename)
        default: return .null
        }
    }
    private func matchingNotes(_ query: String) -> AnkiValue {
        .array(notes.compactMap { id, note in
                guard let identity = note["fields"]?.object?["LingroveID"]?.string,
                      query.contains(identity) else { return nil }
                return .number(Double(id))
            })
    }
    private func notesInfo(_ ids: [AnkiValue]) -> AnkiValue {
        .array(ids.map { value in
                guard let id = value.integer, let note = notes[id] else { return .object([:]) }
                return .object(["noteId": .number(Double(id)), "modelName": note["modelName"] ?? .string(ReviewLayoutPolicy.model),
                    "fields": .object((note["fields"]?.object ?? [:]).mapValues { .object(["value": $0]) })])
            })
    }
    private func metadata(_ action: String, params: [String: AnkiValue]) -> AnkiValue? {
        let fixed: [String: AnkiValue] = [
            "findCards": .array([.number(1)]),
            "cardsInfo": .array([.object(["deckName": .string("Default")])]),
            "guiDeckOverview": .bool(true), "version": .number(6),
            "getActiveProfile": .string("Lingrove Demo"), "deckNames": .list(["Default"]),
            "modelNames": .list([ReviewLayoutPolicy.model, AnkiReviewPolicy.presetName])
        ]
        if let value = fixed[action] { return value }
        switch action {
        case "modelFieldNames": return .list(params["modelName"]?.string == ReviewLayoutPolicy.model
            ? ["LingroveID", "Front", "Back"] : ReviewField.allCases.map(\.rawValue))
        case "modelTemplates": return .object(params["modelName"]?.string == ReviewLayoutPolicy.model
            ? ReviewLayoutPolicy.templates : AnkiNoteTemplate.templates)
        case "modelStyling": return .object(["css": .string(ReviewLayoutPolicy.css)])
        default: return nil
        }
    }

}
