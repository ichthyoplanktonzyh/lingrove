import Testing
@testable import Cotabby

struct SpeechPCMPlaybackStateTests {
    @Test func completedGenerationWaitsForAllAudioAndDuplicateCallbackIsHarmless() throws {
        var state = SpeechPCMPlaybackState()
        let first = try state.enqueue(samples: 12_000)
        let second = try state.enqueue(samples: 12_000)
        try state.endInput()
        state.played(first)
        state.played(first)
        #expect(state.queuedSamples == 12_000)
        #expect(!state.isFinished)
        state.played(second)
        #expect(state.isFinished)
        #expect(throws: (any Error).self) { try state.enqueue(samples: 1) }
    }

    @Test func drainedQueueBeforeEndIsNotCompletionAndEmptyStreamFails() throws {
        var state = SpeechPCMPlaybackState()
        #expect(throws: (any Error).self) { try state.endInput() }
        let first = try state.enqueue(samples: 100)
        state.played(first)
        #expect(!state.isFinished)
        let second = try state.enqueue(samples: 200)
        state.played(second)
        try state.endInput()
        #expect(state.isFinished)
    }

    @Test func fasterPlaybackBuffersEnoughAndEndReleasesShortUtterances() throws {
        var state = SpeechPCMPlaybackState()
        _ = try state.enqueue(samples: 15_360)
        #expect(state.canStart(sampleRate: 24_000, rate: 1))
        #expect(!state.canStart(sampleRate: 24_000, rate: 1.5))
        _ = try state.enqueue(samples: 15_360)
        #expect(state.canStart(sampleRate: 24_000, rate: 1.5))
        var short = SpeechPCMPlaybackState()
        _ = try short.enqueue(samples: 1_920)
        #expect(!short.canStart(sampleRate: 24_000, rate: 1))
        try short.endInput()
        #expect(short.canStart(sampleRate: 24_000, rate: 1))
    }
}
