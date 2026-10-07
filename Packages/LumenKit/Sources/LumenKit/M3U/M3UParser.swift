import Foundation

public struct M3UPlaylist: Sendable {
    public var channels: [Channel]
    /// EPG URLs advertised in the header (`url-tvg` / `x-tvg-url`).
    public var epgURLs: [URL]
    /// Entries that were dropped (invalid URL, unsupported scheme, `#EXTINF` without URL, exact duplicates).
    public var skippedEntries: Int
    public var hadHeader: Bool
}

public enum M3UError: Error, Equatable, Sendable {
    /// The input contained no content at all.
    case empty
    /// The input doesn't look like an M3U playlist.
    case invalidFormat
    /// The playlist parsed, but contained no playable entries.
    case noPlayableEntries
}

/// Incremental M3U / M3U8 (extended M3U) parser.
///
/// Feed it one line at a time with `consume(_:)` and call `finish()` at the end. This lets the
/// app parse while the playlist downloads, keeping peak memory proportional to the channel list
/// rather than the raw text. The parser does no I/O and is safe to run on any thread.
public struct M3UParser: Sendable {
    public let sourceID: UUID

    private struct PendingEntry: Sendable {
        var title: String
        var attributes: [String: String]
    }

    private var pending: PendingEntry?
    private var pendingGroup: String?
    private var pendingUserAgent: String?
    private var channels: [Channel] = []
    private var identityCounts: [String: Int] = [:]
    private var exactKeys: Set<String> = []
    private var epgURLs: [URL] = []
    private var skipped = 0
    private var sawHeader = false
    private var sawContent = false
    private var isFirstLine = true

    public init(sourceID: UUID) {
        self.sourceID = sourceID
    }

    // MARK: - Convenience entry points

    public static func parse(_ text: String, sourceID: UUID) throws -> M3UPlaylist {
        var parser = M3UParser(sourceID: sourceID)
        text.enumerateLines { line, _ in parser.consume(line) }
        return try parser.finish()
    }

    /// Parses lines as they arrive (e.g. `URLSession.AsyncBytes.lines`). Honors task cancellation.
    public static func parse<Lines: AsyncSequence>(
        lines: Lines,
        sourceID: UUID
    ) async throws -> M3UPlaylist where Lines.Element == String {
        var parser = M3UParser(sourceID: sourceID)
        var counter = 0
        for try await line in lines {
            parser.consume(line)
            counter += 1
            if counter % 2_000 == 0 { try Task.checkCancellation() }
        }
        return try parser.finish()
    }

    // MARK: - Incremental API

    public mutating func consume<S: StringProtocol>(_ rawLine: S) {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFirstLine {
            isFirstLine = false
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        }
        guard !line.isEmpty else { return }
        sawContent = true

        if line.hasPrefix("#") {
            consumeDirective(line)
        } else {
            consumeURL(line)
        }
    }

    public func finish() throws -> M3UPlaylist {
        guard sawContent else { throw M3UError.empty }
        if channels.isEmpty {
            throw sawHeader ? M3UError.noPlayableEntries : M3UError.invalidFormat
        }
        return M3UPlaylist(
            channels: channels,
            epgURLs: epgURLs,
            skippedEntries: skipped + (pending == nil ? 0 : 1),
            hadHeader: sawHeader
        )
    }

    // MARK: - Line handling

    private mutating func consumeDirective(_ line: String) {
        if line.hasPrefix("#EXTM3U") {
            sawHeader = true
            let attributes = M3UAttributes.parse(Substring(line.dropFirst("#EXTM3U".count)))
            for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                guard let value = attributes[key] else { continue }
                for part in value.split(separator: ",") {
                    if let url = URLValidator.httpURL(from: String(part)), !epgURLs.contains(url) {
                        epgURLs.append(url)
                    }
                }
            }
        } else if line.hasPrefix("#EXTINF:") {
            if pending != nil { skipped += 1 }
            pending = Self.parseExtInf(line.dropFirst("#EXTINF:".count))
        } else if line.hasPrefix("#EXTGRP:") {
            let group = line.dropFirst("#EXTGRP:".count).trimmingCharacters(in: .whitespaces)
            pendingGroup = group.isEmpty ? nil : group
        } else if line.hasPrefix("#EXTVLCOPT:") {
            let option = line.dropFirst("#EXTVLCOPT:".count)
            if let eq = option.firstIndex(of: "="),
               option[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "http-user-agent" {
                let value = option[option.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                pendingUserAgent = value.isEmpty ? nil : value
            }
        }
        // Other directives (#EXTVLCOPT variants, #KODIPROP, comments) are ignored.
    }

    private mutating func consumeURL(_ line: String) {
        defer {
            pending = nil
            pendingGroup = nil
            pendingUserAgent = nil
        }
        guard let url = URLValidator.streamURL(from: line) else {
            skipped += 1
            return
        }

        let attributes = pending?.attributes ?? [:]
        let tvgID = attributes["tvg-id"].nonEmpty
        let tvgName = attributes["tvg-name"].nonEmpty
        let title = pending?.title.nonEmpty
        let name = title ?? tvgName ?? Self.fallbackName(for: url)
        let group = attributes["group-title"].nonEmpty ?? pendingGroup
        let logo = (attributes["tvg-logo"].nonEmpty ?? attributes["logo"].nonEmpty).flatMap(URLValidator.httpURL(from:))
        let userAgent = pendingUserAgent ?? attributes["user-agent"].nonEmpty ?? attributes["http-user-agent"].nonEmpty

        let identity = "\(tvgID ?? "")|\(name)|\(group ?? "")"
        let exactKey = "\(identity)|\(url.absoluteString)"
        guard exactKeys.insert(exactKey).inserted else {
            skipped += 1 // exact duplicate
            return
        }
        let occurrence = identityCounts[identity, default: 0]
        identityCounts[identity] = occurrence + 1
        let identityKey = occurrence == 0 ? identity : "\(identity)#\(occurrence + 1)"

        channels.append(Channel(
            id: ChannelID(sourceID: sourceID, identityKey: identityKey),
            sourceID: sourceID,
            name: name,
            streamURL: url,
            group: group,
            logoURL: logo,
            tvgID: tvgID,
            tvgName: tvgName,
            language: attributes["tvg-language"].nonEmpty,
            country: attributes["tvg-country"].nonEmpty,
            userAgent: userAgent
        ))
    }

    /// Splits `-1 key="value" key2="a, b",Display Name` at the first comma outside quotes.
    private static func parseExtInf(_ body: Substring) -> PendingEntry {
        var inQuotes = false
        var splitIndex: Substring.Index?
        var index = body.startIndex
        while index < body.endIndex {
            let char = body[index]
            if char == "\"" {
                inQuotes.toggle()
            } else if char == ",", !inQuotes {
                splitIndex = index
                break
            }
            index = body.index(after: index)
        }
        let attributePart: Substring
        let title: String
        if let splitIndex {
            attributePart = body[..<splitIndex]
            title = body[body.index(after: splitIndex)...].trimmingCharacters(in: .whitespaces)
        } else {
            attributePart = body
            title = ""
        }
        return PendingEntry(title: title, attributes: M3UAttributes.parse(attributePart))
    }

    private static func fallbackName(for url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host ?? "Unknown Channel"
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
