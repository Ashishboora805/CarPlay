import Foundation
import LumenKit

struct CategorySummary: Identifiable, Hashable, Sendable {
    let name: String
    let count: Int
    var id: String { name }
}

/// Immutable, precomputed view of all enabled channels. Built off the main thread whenever
/// sources change, then swapped in atomically, so the UI never indexes or sorts on the main thread.
struct LibrarySnapshot: Sendable {
    let channels: [Channel]
    let categories: [CategorySummary]
    let searchIndex: SearchIndex
    private let indexByID: [ChannelID: Int]
    private let indicesByCategory: [String: [Int]]

    static let empty = LibrarySnapshot(channels: [], categories: [], searchIndex: SearchIndex(),
                                       indexByID: [:], indicesByCategory: [:])

    private init(channels: [Channel], categories: [CategorySummary], searchIndex: SearchIndex,
                 indexByID: [ChannelID: Int], indicesByCategory: [String: [Int]]) {
        self.channels = channels
        self.categories = categories
        self.searchIndex = searchIndex
        self.indexByID = indexByID
        self.indicesByCategory = indicesByCategory
    }

    /// `playlists` must already be in display (source sort) order.
    static func build(playlists: [CachedPlaylist]) -> LibrarySnapshot {
        let total = playlists.reduce(0) { $0 + $1.channels.count }
        var channels: [Channel] = []
        channels.reserveCapacity(total)
        var indexByID: [ChannelID: Int] = [:]
        indexByID.reserveCapacity(total)
        var indicesByCategory: [String: [Int]] = [:]
        var categoryOrder: [String] = []

        for playlist in playlists {
            for channel in playlist.channels where indexByID[channel.id] == nil {
                let index = channels.count
                channels.append(channel)
                indexByID[channel.id] = index
                let category = channel.category
                if indicesByCategory[category] == nil { categoryOrder.append(category) }
                indicesByCategory[category, default: []].append(index)
            }
        }

        let categories = categoryOrder.map { CategorySummary(name: $0, count: indicesByCategory[$0]?.count ?? 0) }
        return LibrarySnapshot(channels: channels, categories: categories,
                               searchIndex: SearchIndex(channels: channels),
                               indexByID: indexByID, indicesByCategory: indicesByCategory)
    }

    var isEmpty: Bool { channels.isEmpty }

    func channel(_ id: ChannelID) -> Channel? {
        indexByID[id].map { channels[$0] }
    }

    func channel(rawID: String) -> Channel? {
        channel(ChannelID(rawValue: rawID))
    }

    func channels(in category: String) -> [Channel] {
        (indicesByCategory[category] ?? []).map { channels[$0] }
    }
}
