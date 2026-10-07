import Foundation

/// Read-optimized EPG lookup structure. Value type, cheap to copy (copy-on-write storage),
/// safe to build off the main thread and hand to the UI.
public struct EPGIndex: Sendable {
    public private(set) var programs: [String: [EPGProgram]] = [:]
    /// Lowercased XMLTV id → original id.
    private var idLookup: [String: String] = [:]
    /// Normalized display name → XMLTV id.
    private var nameLookup: [String: String] = [:]

    public init() {}

    public init(data: EPGData) {
        merge(data)
    }

    public var isEmpty: Bool { programs.isEmpty }
    public var channelCount: Int { programs.count }

    public mutating func merge(_ data: EPGData) {
        for (key, list) in data.programs where programs[key] == nil || programs[key]!.isEmpty {
            programs[key] = list
            idLookup[key.lowercased()] = key
        }
        for (key, name) in data.displayNames where programs[key] != nil {
            let normalized = Self.normalize(name)
            if nameLookup[normalized] == nil { nameLookup[normalized] = key }
        }
    }

    /// Resolves the XMLTV key for a channel: exact tvg-id, case-insensitive tvg-id, then
    /// display-name match on tvg-name / channel name.
    public func key(for channel: Channel) -> String? {
        if let tvgID = channel.tvgID {
            if programs[tvgID] != nil { return tvgID }
            if let key = idLookup[tvgID.lowercased()] { return key }
        }
        if let tvgName = channel.tvgName, let key = nameLookup[Self.normalize(tvgName)] { return key }
        return nameLookup[Self.normalize(channel.name)]
    }

    public func current(for key: String, at date: Date = Date()) -> EPGProgram? {
        guard let list = programs[key], let index = Self.lastIndex(startingAtOrBefore: date, in: list) else {
            return nil
        }
        let program = list[index]
        return program.isAiring(at: date) ? program : nil
    }

    public func next(for key: String, after date: Date = Date()) -> EPGProgram? {
        guard let list = programs[key] else { return nil }
        let index = (Self.lastIndex(startingAtOrBefore: date, in: list) ?? -1) + 1
        return index < list.count ? list[index] : nil
    }

    public func schedule(for key: String, from start: Date, to end: Date) -> [EPGProgram] {
        guard let list = programs[key] else { return [] }
        let first = Self.lastIndex(startingAtOrBefore: start, in: list) ?? 0
        var result: [EPGProgram] = []
        for program in list[first...] {
            if program.start >= end { break }
            if program.end > start { result.append(program) }
        }
        return result
    }

    /// Binary search for the last programme whose start is <= `date`.
    static func lastIndex(startingAtOrBefore date: Date, in list: [EPGProgram]) -> Int? {
        var low = 0
        var high = list.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if list[mid].start <= date {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
