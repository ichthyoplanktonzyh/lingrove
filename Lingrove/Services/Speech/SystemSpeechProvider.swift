import AVFoundation
import Foundation

/// Adapts the installed macOS speech voices and one AVSpeechSynthesizer queue to the
/// SpeechProviding boundary. This provider never requests personal-voice authorization; the
/// system's already-available voices are read only after the controller receives an explicit request.
@MainActor
final class SystemSpeechProvider: NSObject, SpeechProviding {
    private struct UtteranceRecord {
        let token: SpeechPlaybackToken
        let utterance: AVSpeechUtterance
    }

    private lazy var synthesizer: AVSpeechSynthesizer = {
        let value = AVSpeechSynthesizer()
        value.delegate = self
        return value
    }()
    private var utterances: [UInt: UtteranceRecord] = [:]
    private var activeUtterance: UtteranceRecord?

    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)?

    func refreshVoices() throws -> [SpeechVoice] {
        let systemVoices = AVSpeechSynthesisVoice.speechVoices()
        let preferredVoiceIDs = Set(LearningLanguage.allCases.compactMap {
            AVSpeechSynthesisVoice(language: $0.rawValue)?.identifier
        })
        return systemVoices.map { voice in
            .init(
                id: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: Self.quality(for: voice.quality),
                isSystemPreferred: preferredVoiceIDs.contains(voice.identifier),
                isNovelty: voice.voiceTraits.contains(.isNoveltyVoice)
            )
        }
    }

    func speak(
        _ text: String, voice: SpeechVoice, rateMultiplier: Double, token: SpeechPlaybackToken
    ) throws {
        guard let systemVoice = AVSpeechSynthesisVoice(identifier: voice.id) else {
            throw SpeechProviderError.voiceUnavailable
        }

        if let activeUtterance { stop(token: activeUtterance.token) }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = systemVoice
        let desiredRate = Double(AVSpeechUtteranceDefaultSpeechRate) * rateMultiplier
        utterance.rate = Float(min(max(
            desiredRate,
            Double(AVSpeechUtteranceMinimumSpeechRate)
        ), Double(AVSpeechUtteranceMaximumSpeechRate)))

        let record = UtteranceRecord(token: token, utterance: utterance)
        // The object-identity map retains each utterance until its callback is consumed. That
        // prevents a delayed callback from being mistaken for a later utterance after id reuse.
        utterances[Self.identity(of: utterance)] = record
        activeUtterance = record
        synthesizer.speak(utterance)
    }

    func stop(token: SpeechPlaybackToken) {
        guard let record = activeUtterance, record.token == token else { return }
        let stopped = synthesizer.stopSpeaking(at: .immediate)
        activeUtterance = nil
        if !stopped {
            utterances[Self.identity(of: record.utterance)] = nil
            eventHandler?(.cancelled(token))
        }
    }

    private func finish(
        utteranceID: UInt, event: (SpeechPlaybackToken) -> SpeechProviderEvent
    ) {
        guard let record = utterances.removeValue(forKey: utteranceID) else { return }
        if activeUtterance?.token == record.token { activeUtterance = nil }
        eventHandler?(event(record.token))
    }

    private func start(utteranceID: UInt) {
        guard let record = utterances[utteranceID] else { return }
        eventHandler?(.started(record.token))
    }

    nonisolated private static func identity(of utterance: AVSpeechUtterance) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(utterance).toOpaque())
    }

    private static func quality(for quality: AVSpeechSynthesisVoiceQuality) -> SpeechVoiceQuality {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }
}

extension SystemSpeechProvider: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceID = Self.identity(of: utterance)
        Task { @MainActor [weak self] in self?.start(utteranceID: utteranceID) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = Self.identity(of: utterance)
        Task { @MainActor [weak self] in
            self?.finish(utteranceID: utteranceID, event: SpeechProviderEvent.finished)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = Self.identity(of: utterance)
        Task { @MainActor [weak self] in
            self?.finish(utteranceID: utteranceID, event: SpeechProviderEvent.cancelled)
        }
    }
}

private enum SpeechProviderError: LocalizedError {
    case voiceUnavailable

    var errorDescription: String? {
        String(localized: "The selected speech voice is no longer available.", table: "Learning")
    }
}
