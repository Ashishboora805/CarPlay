import Foundation

/// Exponential back-off for automatic stream reconnection.
public struct ReconnectPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Playback that lasted at least this long counts as healthy and resets the attempt counter.
    public var healthyPlaybackDuration: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 16,
                healthyPlaybackDuration: TimeInterval = 20) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.healthyPlaybackDuration = healthyPlaybackDuration
    }

    /// Delay before 1-based `attempt`, or nil when attempts are exhausted.
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        let exponent = Double(attempt - 1)
        return min(maxDelay, baseDelay * pow(2, exponent))
    }

    /// Attempt counter to use for the next failure, given how long the stream played.
    public func nextAttempt(current: Int, playedFor duration: TimeInterval?) -> Int {
        if let duration, duration >= healthyPlaybackDuration { return 1 }
        return current + 1
    }
}
