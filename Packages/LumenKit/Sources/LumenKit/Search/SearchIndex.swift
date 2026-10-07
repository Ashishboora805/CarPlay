import Foundation

/// In-memory channel search. Matching is case- and diacritic-insensitive; every query token
/// must appear in the channel's name, category, country, language or tvg-name.
///
/// Building the index normalizes each channel once, so a query is a linear scan over
/// precomputed lowercase strings (a few milliseconds for 50k channels).
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let id: ChannelID
        let name: String
        let haystack: String
    }

    private var entries: [Entry] = []

    public init() {}

    public init(channels: [Channel]) {
        entries.reserveCapacity(channels.count)
        for channel in channels {
            let name = Self.normalize(channel.name)
            var parts = [name]
            if let group = channel.group { parts.append(Self.normalize(group)) }
            if let tvgName = channel.tvgName { parts.append(Self.normalize(tvgName)) }
            if let country = channel.country { parts.append(Self.normalize(country)) }
            if let language = channel.language { parts.append(Self.normalize(language)) }
            entries.append(Entry(id: channel.id, name: name, haystack: parts.joined(separator: " \u{1F} ")))
        }
    }

    public var count: Int { entries.count }

    public func search(_ query: String, limit: Int = 300) -> [ChannelID] {
        let normalized = Self.normalize(query)
        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var exactPrefix: [ChannelID] = []
        var wordPrefix: [ChannelID] = []
        var other: [ChannelID] = []

        for entry in entries {
            guard tokens.allSatisfy({ entry.haystack.contains($0) }) else { continue }
            if entry.name.hasPrefix(normalized) {
                exactPrefix.append(entry.id)
            } else if entry.name.contains(" " + tokens[0]) || entry.name.hasPrefix(tokens[0]) {
                wordPrefix.append(entry.id)
            } else {
                other.append(entry.id)
            }
            if exactPrefix.count >= limit { break }
        }
        return Array((exactPrefix + wordPrefix + other).prefix(limit))
    }

    public static func normalize(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
