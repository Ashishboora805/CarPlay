import Foundation
import LumenKit
import os

/// Downloads and parses playlists off the main thread. Parsing happens line-by-line while the
/// response streams in. Concurrent refreshes of the same source are coalesced.
actor PlaylistManager {
    private static let logger = Logger(subsystem: "app.lumen", category: "playlist")

    private let http: HTTPClient
    private let cache: ChannelCache
    private var inFlight: [UUID: Task<CachedPlaylist, Error>] = [:]

    init(http: HTTPClient, cache: ChannelCache) {
        self.http = http
        self.cache = cache
    }

    func loadCached(_ sourceIDs: [UUID]) -> [UUID: CachedPlaylist] {
        var result: [UUID: CachedPlaylist] = [:]
        for id in sourceIDs {
            if let playlist = cache.load(sourceID: id) { result[id] = playlist }
        }
        return result
    }

    func refresh(_ source: SourceDescriptor) async throws -> CachedPlaylist {
        if let existing = inFlight[source.id] {
            return try await existing.value
        }
        let http = http
        let cache = cache
        let task = Task.detached(priority: .utility) {
            try await Self.fetch(source, http: http, cache: cache)
        }
        inFlight[source.id] = task
        defer { inFlight[source.id] = nil }
        return try await task.value
    }

    func removeCache(for sourceID: UUID) {
        inFlight[sourceID]?.cancel()
        cache.remove(sourceID: sourceID)
    }

    func clearAll() {
        cache.removeAll()
    }

    private static func fetch(_ source: SourceDescriptor, http: HTTPClient, cache: ChannelCache) async throws -> CachedPlaylist {
        let request = HTTPClient.request(source.playlistURL, credentials: source.credentials, timeout: 30)
        let started = Date()
        do {
            let (bytes, _) = try await http.bytes(for: request)
            let playlist = try await M3UParser.parse(lines: bytes.lines, sourceID: source.id)
            let cached = CachedPlaylist(sourceID: source.id, channels: playlist.channels,
                                        epgURLs: playlist.epgURLs, fetchedAt: .now)
            do {
                try cache.save(cached)
            } catch {
                logger.error("Failed to cache playlist: \(error.localizedDescription, privacy: .public)")
            }
            logger.info("Loaded \(playlist.channels.count) channels (\(playlist.skippedEntries) skipped) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            return cached
        } catch {
            let mapped = AppError.from(error)
            logger.error("Playlist refresh failed for \(LogRedactor.redact(source.playlistURL), privacy: .public): \(mapped.title, privacy: .public)")
            throw mapped
        }
    }
}
