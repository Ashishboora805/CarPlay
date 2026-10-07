import Foundation

/// Secret part of a source, stored as JSON in the Keychain.
struct SourceSecrets: Codable, Hashable, Sendable {
    var playlistURL: URL
    var epgURL: URL?
    var credentials: SourceCredentials?
}

/// Immutable, thread-safe snapshot of a source used by background loaders.
struct SourceDescriptor: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let playlistURL: URL
    let epgURL: URL?
    let credentials: SourceCredentials?
    let refreshInterval: TimeInterval
    let isEnabled: Bool
    let lastRefreshedAt: Date?

    func isStale(now: Date = .now) -> Bool {
        guard let lastRefreshedAt else { return true }
        return now.timeIntervalSince(lastRefreshedAt) >= refreshInterval
    }
}

extension Notification.Name {
    /// Sources, favorites or history changed (posted on the main thread).
    static let lumenLibraryDidChange = Notification.Name("LumenLibraryDidChange")
    /// The channel snapshot was rebuilt.
    static let lumenChannelsDidChange = Notification.Name("LumenChannelsDidChange")
    /// The current channel or play/pause state changed.
    static let lumenNowPlayingDidChange = Notification.Name("LumenNowPlayingDidChange")
    /// Playback failed permanently. `object` is the `AppError`.
    static let lumenPlaybackFailed = Notification.Name("LumenPlaybackFailed")
    static let lumenNetworkRestored = Notification.Name("LumenNetworkRestored")
}
