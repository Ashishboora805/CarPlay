import Foundation

public struct EPGProgram: Codable, Hashable, Sendable, Identifiable {
    /// XMLTV channel id this programme belongs to.
    public let channelKey: String
    public let start: Date
    public let end: Date
    public let title: String
    public let subtitle: String?
    public let summary: String?
    public let category: String?

    public init(channelKey: String, start: Date, end: Date, title: String,
                subtitle: String? = nil, summary: String? = nil, category: String? = nil) {
        self.channelKey = channelKey
        self.start = start
        self.end = end
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.category = category
    }

    public var id: String { "\(channelKey)|\(start.timeIntervalSince1970)" }

    public func isAiring(at date: Date) -> Bool { start <= date && date < end }

    /// 0...1 progress through the programme at `date`.
    public func progress(at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }
}

/// Parsed XMLTV payload. `programs` values are sorted by start time and non-overlapping
/// where the source allows.
public struct EPGData: Codable, Sendable {
    /// XMLTV channel id → display name.
    public var displayNames: [String: String]
    public var programs: [String: [EPGProgram]]

    public init(displayNames: [String: String] = [:], programs: [String: [EPGProgram]] = [:]) {
        self.displayNames = displayNames
        self.programs = programs
    }

    public var programCount: Int { programs.values.reduce(0) { $0 + $1.count } }

    /// Drops programmes outside `window`. Used to expire old cached data without refetching.
    public func pruned(to window: DateInterval) -> EPGData {
        var copy = self
        for (key, list) in programs {
            let kept = list.filter { $0.end > window.start && $0.start < window.end }
            copy.programs[key] = kept.isEmpty ? nil : kept
        }
        return copy
    }
}
