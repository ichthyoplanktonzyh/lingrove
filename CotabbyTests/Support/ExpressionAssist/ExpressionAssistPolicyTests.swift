import CoreGraphics
import Foundation
import Testing
@testable import Cotabby

struct ExpressionAssistPolicyTests {
    @Test
    func observingHostRequiresTheOriginalAppOrOurOwnedInputAndRestorationNeverFollowsAnAppSwitch() {
        #expect(ExpressionAssistFocusPolicy.permitsHostRead(frontmost: 10, host: 10, inputOwner: 20, inputOwnsKeyboard: false))
        #expect(ExpressionAssistFocusPolicy.permitsHostRead(frontmost: 20, host: 10, inputOwner: 20, inputOwnsKeyboard: true))
        #expect(!ExpressionAssistFocusPolicy.permitsHostRead(frontmost: 20, host: 10, inputOwner: 20, inputOwnsKeyboard: false))
        #expect(!ExpressionAssistFocusPolicy.permitsHostRead(frontmost: 30, host: 10, inputOwner: 20, inputOwnsKeyboard: true))
        #expect(!ExpressionAssistFocusPolicy.permitsHostRead(frontmost: nil, host: 10, inputOwner: 20, inputOwnsKeyboard: true))
        #expect(ExpressionAssistFocusPolicy.shouldRestoreHost(frontmost: 20, host: 10, inputOwner: 20, inputOwnsKeyboard: true))
        #expect(!ExpressionAssistFocusPolicy.shouldRestoreHost(frontmost: 30, host: 10, inputOwner: 20, inputOwnsKeyboard: true))
        #expect(!ExpressionAssistFocusPolicy.shouldRestoreHost(frontmost: 20, host: 10, inputOwner: 20, inputOwnsKeyboard: false))
    }

    @Test(arguments: ["??", ";;", "@@", "？？", "✨✨"])
    func customTriggersAcceptLiteralUnicodeSymbols(_ trigger: String) {
        #expect(ExpressionAssistPolicy.triggerError(trigger) == nil)
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: "We mean " + trigger, configured: trigger) == trigger)
    }

    @Test(arguments: ["", "?", "hello", "? ?", "\n??", "/?", ":?", "?????????"])
    func invalidOrReservedTriggersAreRejected(_ trigger: String) {
        #expect(ExpressionAssistPolicy.triggerError(trigger) != nil)
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: " " + trigger, configured: trigger) == nil)
    }

    @Test
    func fullWidthAliasDoesNotBroadenCustomTriggers() {
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: "（？？", configured: "??") == "？？")
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: "word??", configured: "??") == "??")
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: "word ??", configured: ";;") == nil)
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: ";;", configured: ";;") == ";;")
    }

    @Test(arguments: ["", "word", "文字", "123", "😀", "e\u{301}", " ", "。", "\n"])
    func triggerIsRecognizedAtEveryCaretBoundary(_ prefix: String) {
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: prefix + "??", configured: "??") == "??")
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: prefix + "？？", configured: "??") == "？？")
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: prefix + ";;", configured: ";;") == ";;")
        #expect(ExpressionAssistPolicy.matchedTrigger(beforeCaret: prefix + "??x", configured: "??") == nil)
    }

    @Test
    func literalRangesPermitEmptyInsertionsAndRejectPartialGraphemes() throws {
        #expect(try EditorTextRangePolicy.text("Hi 😀", range: NSRange(location: 5, length: 0)).isEmpty)
        #expect(try EditorTextRangePolicy.text("Hi 😀", range: NSRange(location: 3, length: 0)).isEmpty)
        #expect(try EditorTextRangePolicy.text("We can  do it", range: NSRange(location: 7, length: 0)).isEmpty)
        #expect(throws: (any Error).self) { try EditorTextRangePolicy.text("e\u{301}", range: NSRange(location: 1, length: 0)) }
        #expect(try EditorTextRangePolicy.text("??", range: NSRange(location: 0, length: 2)) == "??")
        #expect(throws: (any Error).self) { try EditorTextRangePolicy.text("😀", range: NSRange(location: 1, length: 1)) }
        #expect(throws: (any Error).self) { try EditorTextRangePolicy.text("e\u{301}", range: NSRange(location: 0, length: 1)) }
        #expect(throws: (any Error).self) { try EditorTextRangePolicy.text("Hi", range: NSRange(location: .max, length: 2)) }
    }

    @Test
    func requestExcludesUnrelatedParagraphsAndPreservesBothSides() throws {
        let value = "PRIVATE EARLIER PARAGRAPH\nWe still can't ?? yet.\nUNRELATED LATER PARAGRAPH"
        let range = (value as NSString).range(of: "??")
        let request = try ExpressionAssistPolicy.request(query: "排除缓存是原因", value: value, range: range,
            target: .english, explanation: .chinese)
        #expect(request.leftContext == "We still can't ")
        #expect(request.rightContext == " yet.")
        #expect(request.targetLanguage == "en" && request.explanationLanguage == "zh-Hans")
        let prompt = try ExpressionAssistPrompt.render(request, total: 8_192, output: 768)
        #expect(prompt.contains("排除缓存是原因"))
        #expect(!prompt.contains("PRIVATE") && !prompt.contains("UNRELATED"))
    }

    @Test
    func parsedCandidatesAreCompleteAndDuplicateChoicesAreRemoved() throws {
        let request = try fixture()
        let result = try ExpressionAssistPrompt.parse("""
        {"candidates":[{"text":"rule out caching","hint":"排除缓存"},
        {"text":" rule out caching ","hint":"相同选项"}],"clarification":null}
        """, request: request)
        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.text == "rule out caching")
    }

    @Test
    func intentionalEdgeSpacesRemainPartOfTheExactInsertion() throws {
        let request = try ExpressionAssistPolicy.request(query: "排除", value: "We can rule??.",
            range: NSRange(location: 11, length: 2), target: .english, explanation: .chinese)
        let result = try ExpressionAssistPrompt.parse(
            "{\"candidates\":[{\"text\":\" out\",\"hint\":\"排除\"}]}", request: request)
        #expect(result.candidates.first?.text == " out")
        #expect(request.leftContext + (result.candidates.first?.text ?? "") + request.rightContext == "We can rule out.")
    }

    @Test
    func ambiguityIsDisplayedAsAQuestionWithoutAnInsertableAnswer() throws {
        let result = try ExpressionAssistPrompt.parse(
            "{\"candidates\":[],\"clarification\":\"指心理感受还是管理现象？\"}", request: fixture())
        #expect(result.candidates.isEmpty)
        #expect(result.clarification == "指心理感受还是管理现象？")
    }

    @Test(arguments: [
        "{\"candidates\":[]}",
        "{\"candidates\":[{\"text\":\"unfinished\"}]}",
        "{\"candidates\":[{\"text\":\"line\\nline\",\"hint\":\"hint\"}]}",
        "{\"candidates\":[{\"text\":\"We still cannot rule out caching\",\"hint\":\"hint\"}]}"
    ])
    func malformedOrContextEchoingOutputIsNotInsertable(_ raw: String) throws {
        #expect(throws: (any Error).self) { try ExpressionAssistPrompt.parse(raw, request: fixture()) }
    }

    @Test
    func boundedContextsKeepUnicodeCharactersWhole() throws {
        let prefix = String(repeating: "😀", count: 1_000)
        let value = prefix + "??" + String(repeating: "界", count: 900)
        let request = try ExpressionAssistPolicy.request(query: "测试", value: value,
            range: NSRange(location: prefix.utf16.count, length: 2), target: .english, explanation: .chinese)
        #expect(request.leftContext.count == 700 && request.rightContext.count == 500)
        #expect(!request.leftContext.contains("�"))
        #expect(throws: (any Error).self) { try ExpressionAssistPrompt.render(request, total: 128, output: 64) }
    }

    @Test
    func placementKeepsTheHostBaselineAndMovesCandidatesAboveAtScreenBottom() throws {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let anchor = ExpressionAssistLayout.Anchor(caret: CGRect(x: 120, y: 180, width: 1, height: 18),
            hostBaseline: 14, nativeBaseline: 13)
        let input = try #require(ExpressionAssistLayout.input(anchor: anchor,
            size: CGSize(width: 250, height: 18), screen: screen, inline: true))
        #expect(input.minX == 120)
        #expect(input.maxY - 13 == 184)
        let candidates = try #require(ExpressionAssistLayout.candidates(input: CGRect(x: 100, y: 5, width: 200, height: 20),
            size: CGSize(width: 300, height: 100), screen: screen))
        #expect(candidates.minY == 29)
        #expect(screen.contains(candidates))
        #expect(ExpressionAssistLayout.input(anchor: anchor, size: CGSize(width: 900, height: 20), screen: screen,
            inline: true) == nil)
    }

    private func fixture() throws -> ExpressionAssistRequest {
        try ExpressionAssistPolicy.request(query: "排除缓存", value: "We still cannot ?? yet.",
            range: NSRange(location: 16, length: 2), target: .english, explanation: .chinese)
    }
}
