import AVFoundation
import Foundation

/// One short-lived delegate captures one immutable operation token. A late completion can only
/// name that token, even if AVFoundation has already reused an audio-player object's address.
nonisolated private final class SpeechAudioDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let token: SpeechPlaybackToken
    let completed: @Sendable (SpeechPlaybackToken, Bool) -> Void
    init(token: SpeechPlaybackToken, completed: @escaping @Sendable (SpeechPlaybackToken, Bool) -> Void) {
        self.token = token
        self.completed = completed
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { completed(token, flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { completed(token, false) }
}

/// The shared controller owns one audio player. System voices play through AVSpeechSynthesizer;
/// endpoint/local WAVs use this player so speed and stop behavior stay consistent between them.
@MainActor
final class SpeechAudioPlayer {
    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)?
    private var player: AVAudioPlayer?
    private var delegate: SpeechAudioDelegate?
    private var token: SpeechPlaybackToken?

    func play(_ data: Data, rate: Double, token: SpeechPlaybackToken) throws {
        stop()
        let player: AVAudioPlayer
        do { player = try AVAudioPlayer(data: data) } catch { throw SpeechError.invalidAudio }
        guard player.duration.isFinite, player.duration > 0, player.duration <= 90 else { throw SpeechError.invalidAudio }
        let delegate = SpeechAudioDelegate(token: token) { [weak self] token, success in
            Task { @MainActor [weak self] in self?.finished(token: token, success: success) }
        }
        self.player = player
        self.delegate = delegate
        self.token = token
        player.delegate = delegate
        player.enableRate = true
        player.rate = Float(rate)
        guard player.play() else { stop(); throw SpeechError.invalidAudio }
        eventHandler?(.started(token))
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        delegate = nil
        token = nil
    }

    private func finished(token: SpeechPlaybackToken, success: Bool) {
        guard self.token == token else { return }
        stop()
        eventHandler?(success ? .finished(token) : .failed(token,
            message: SpeechError.invalidAudio.localizedDescription))
    }
}
