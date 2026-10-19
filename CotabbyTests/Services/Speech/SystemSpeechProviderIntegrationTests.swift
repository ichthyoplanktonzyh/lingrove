import XCTest
@testable import Cotabby

/// Verifies the native delegate bridge and utterance-token lifetime against an installed system
/// voice. This uses no microphone, screen recording, personal-voice authorization, or audio file.
@MainActor
final class SystemSpeechProviderIntegrationTests: XCTestCase {
    func testInstalledEnglishVoiceReportsStartAndFinish() async throws {
        let provider = SystemSpeechProvider()
        let catalog = try provider.refreshVoices()
        guard let voice = SpeechVoicePolicy.select(
            from: catalog, language: .english, preferredVoiceID: nil
        ) else {
            throw XCTSkip("No installed English system voice is available")
        }

        let token = SpeechPlaybackToken()
        let didStart = expectation(description: "System speech began")
        let didFinish = expectation(description: "System speech finished")
        var received: [SpeechProviderEvent] = []
        provider.eventHandler = { event in
            guard event.token == token else { return }
            received.append(event)
            switch event {
            case .started: didStart.fulfill()
            case .finished: didFinish.fulfill()
            case .prepared, .cancelled, .failed: break
            }
        }

        try provider.speak("Ready.", voice: voice, rateMultiplier: 1, token: token)
        defer { provider.stop(token: token) }
        await fulfillment(of: [didStart, didFinish], timeout: 15)

        XCTAssertEqual(received, [.started(token), .finished(token)])
    }
}
