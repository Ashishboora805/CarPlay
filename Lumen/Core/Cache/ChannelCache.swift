import Foundation
import LumenKit

/// Parsed playlist persisted per source (binary property list). Channel data is stored exactly
/// once per source; favorites and history only reference channel IDs.
struct CachedPlaylist: Codable, Sendable {
    let sourceID: UUID
    let channels: [Channel]
    let epgURLs: [URL]
    let fetchedAt: Date
}

struct ChannelCache: Sendable {
    let directory: URL

    init(directory: URL = CacheDirectories.channels) {
        self.directory = directory
    }

    private func fileURL(for sourceID: UUID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString).plist")
    }

    func load(sourceID: UUID) -> CachedPlaylist? {
        guard let data = try? Data(contentsOf: fileURL(for: sourceID), options: .mappedIfSafe) else { return nil }
        return try? PropertyListDecoder().decode(CachedPlaylist.self, from: data)
    }

    func save(_ playlist: CachedPlaylist) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(playlist).write(to: fileURL(for: playlist.sourceID), options: .lumenCache)
    }

    func remove(sourceID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sourceID))
    }

    func removeAll() {
        CacheDirectories.clear(directory)
    }
}
