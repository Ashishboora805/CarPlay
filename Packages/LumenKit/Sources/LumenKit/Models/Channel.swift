import Foundation

/// Stable identifier for a channel. Derived from the source plus the channel's identity
/// (tvg-id, name and group) rather than the stream URL, so favorites survive providers
/// rotating tokens inside stream URLs.
public struct ChannelID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(sourceID: UUID, identityKey: String) {
        self.rawValue = StableHash.hex("\(sourceID.uuidString)|\(identityKey)")
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct Channel: Identifiable, Hashable, Codable, Sendable {
    public static let uncategorized = "Uncategorized"

    public let id: ChannelID
    public let sourceID: UUID
    public let name: String
    public let streamURL: URL
    public let group: String?
    public let logoURL: URL?
    public let tvgID: String?
    public let tvgName: String?
    public let language: String?
    public let country: String?
    /// Optional per-channel User-Agent (from `#EXTVLCOPT:http-user-agent` or `user-agent=`).
    public let userAgent: String?

    public init(
        id: ChannelID,
        sourceID: UUID,
        name: String,
        streamURL: URL,
        group: String? = nil,
        logoURL: URL? = nil,
        tvgID: String? = nil,
        tvgName: String? = nil,
        language: String? = nil,
        country: String? = nil,
        userAgent: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.streamURL = streamURL
        self.group = group
        self.logoURL = logoURL
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.language = language
        self.country = country
        self.userAgent = userAgent
    }

    /// Category name used for grouping; never empty.
    public var category: String { group ?? Channel.uncategorized }

    /// True when the "stream" is actually a YouTube link. These are played with the official
    /// YouTube embed on iPhone and are never offered on CarPlay.
    public var isYouTube: Bool { YouTubeLinkParser.videoID(from: streamURL) != nil }
}
