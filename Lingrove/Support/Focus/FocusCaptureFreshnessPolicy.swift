import Foundation

/// Shared rules for avoiding duplicate AX walks. A capture that merely *finished* after a key may
/// still have read its old text, so post-input reuse requires the capture to have *started* after
/// that key, to belong to the same focus identity, and to remain within the retry's freshness bound.
/// Explicit insertion/replacement validation continues to call `refreshNow` unconditionally.
nonisolated enum FocusCaptureFreshnessPolicy {
    static func canReuseAfterInput(
        captureStartedAt: UInt64?, inputAt: UInt64,
        ageMilliseconds: Int?, maxAgeMilliseconds: Int, sameIdentity: Bool
    ) -> Bool {
        guard sameIdentity, let started = captureStartedAt, started >= inputAt,
              let age = ageMilliseconds, age >= 0, age <= maxAgeMilliseconds else { return false }
        return true
    }

    static func shouldSkipTimerCapture(completedAt: UInt64?, now: UInt64, intervalNanoseconds: UInt64) -> Bool {
        guard let completedAt, now >= completedAt else { return false }
        return now - completedAt < intervalNanoseconds
    }
}
