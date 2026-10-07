import Foundation
import LumenKit
import os

private struct EPGCacheEntry: Codable {
    let url: URL
    let fetchedAt: Date
    let etag: String?
    let lastModified: String?
    let data: EPGData
}

struct EPGTarget: Hashable, Sendable {
    let url: URL
    let credentials: SourceCredentials?
}

/// Fetches, decompresses and parses XMLTV in the background and caches the parsed result.
///
/// - Fresh cache (younger than `maxAge`) is used without touching the network.
/// - Stale cache is revalidated with `If-None-Match` / `If-Modified-Since`.
/// - Downloads go to disk and are parsed as a stream; `.gz` is decompressed file-to-file.
/// - On failure the last good cache is returned together with the error.
actor EPGLoader {
    private static let logger = Logger(subsystem: "app.lumen", category: "epg")
    static let pastWindow: TimeInterval = 2 * 3600
    static let futureWindow: TimeInterval = 48 * 3600

    private let http: HTTPClient
    private let directory: URL

    init(http: HTTPClient, directory: URL = CacheDirectories.epg) {
        self.http = http
        self.directory = directory
    }

    static func currentWindow(now: Date = .now) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-pastWindow), end: now.addingTimeInterval(futureWindow))
    }

    func loadAll(_ targets: [EPGTarget], maxAge: TimeInterval, force: Bool) async -> (EPGIndex, AppError?) {
        var index = EPGIndex()
        var firstError: AppError?
        for target in targets {
            if Task.isCancelled { break }
            let (data, error) = await load(target, maxAge: maxAge, force: force)
            if let data { index.merge(data) }
            if firstError == nil, let error { firstError = error }
        }
        return (index, firstError)
    }

    func load(_ target: EPGTarget, maxAge: TimeInterval, force: Bool) async -> (EPGData?, AppError?) {
        let file = directory.appendingPathComponent("\(StableHash.hex(target.url.absoluteString)).plist")
        let cached = readEntry(at: file)
        let window = Self.currentWindow()

        if let cached, !force, Date().timeIntervalSince(cached.fetchedAt) < maxAge {
            return (cached.data.pruned(to: window), nil)
        }

        var request = HTTPClient.request(target.url, credentials: target.credentials, timeout: 60)
        if let cached {
            if let etag = cached.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified = cached.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        }

        var temporaryFiles: [URL] = []
        defer { temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        do {
            let (downloaded, response) = try await http.download(for: request)
            temporaryFiles.append(downloaded)

            if response.statusCode == 304, let cached {
                let refreshed = EPGCacheEntry(url: cached.url, fetchedAt: .now, etag: cached.etag,
                                              lastModified: cached.lastModified, data: cached.data.pruned(to: window))
                writeEntry(refreshed, to: file)
                return (refreshed.data, nil)
            }

            var xmlFile = downloaded
            if Gzip.isGzipped(fileAt: downloaded) {
                let decompressed = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xml")
                temporaryFiles.append(decompressed)
                try Gzip.decompress(fileAt: downloaded, to: decompressed)
                xmlFile = decompressed
            }

            let started = Date()
            let data = try XMLTVParser.parse(fileURL: xmlFile, window: window)
            Self.logger.info("Parsed EPG: \(data.programs.count) channels, \(data.programCount) programmes in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")

            if data.programs.isEmpty, let cached {
                return (cached.data.pruned(to: window), .epgUnavailable)
            }
            let entry = EPGCacheEntry(url: target.url, fetchedAt: .now,
                                      etag: response.value(forHTTPHeaderField: "ETag"),
                                      lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                                      data: data)
            writeEntry(entry, to: file)
            return (data, nil)
        } catch {
            let mapped = AppError.from(error)
            Self.logger.error("EPG load failed for \(LogRedactor.redact(target.url), privacy: .public): \(mapped.title, privacy: .public)")
            if let cached { return (cached.data.pruned(to: window), mapped) }
            return (nil, mapped)
        }
    }

    func clearAll() {
        CacheDirectories.clear(directory)
    }

    private func readEntry(at url: URL) -> EPGCacheEntry? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? PropertyListDecoder().decode(EPGCacheEntry.self, from: data)
    }

    private func writeEntry(_ entry: EPGCacheEntry, to url: URL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(entry).write(to: url, options: .lumenCache)
    }
}
