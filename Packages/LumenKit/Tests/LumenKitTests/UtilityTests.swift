import XCTest
@testable import LumenKit
#if canImport(Compression)
import Compression
#endif

final class SearchIndexTests: XCTestCase {
    private let source = UUID()

    private func channel(_ name: String, group: String? = nil, country: String? = nil, tvgName: String? = nil) -> Channel {
        Channel(id: ChannelID(rawValue: name), sourceID: source, name: name,
                streamURL: URL(string: "https://e.com/s.m3u8")!, group: group,
                tvgName: tvgName, country: country)
    }

    func testMatchesNameCategoryCountryAndTvgName() {
        let index = SearchIndex(channels: [
            channel("BBC News", group: "News", country: "UK"),
            channel("Canal Sport", group: "Sports", country: "FR"),
            channel("Movie Max", group: "Films", tvgName: "Cinema One")
        ])
        XCTAssertEqual(index.search("bbc").map(\.rawValue), ["BBC News"])
        XCTAssertEqual(index.search("sports").map(\.rawValue), ["Canal Sport"])
        XCTAssertEqual(index.search("uk").map(\.rawValue), ["BBC News"])
        XCTAssertEqual(index.search("cinema").map(\.rawValue), ["Movie Max"])
        XCTAssertTrue(index.search("   ").isEmpty)
    }

    func testDiacriticAndCaseInsensitiveWithMultipleTokens() {
        let index = SearchIndex(channels: [channel("Télé Música", group: "Música"), channel("Tele Other")])
        XCTAssertEqual(index.search("TELE MUSICA").map(\.rawValue), ["Télé Música"])
    }

    func testPrefixMatchesRankFirst() {
        let index = SearchIndex(channels: [channel("World Sport"), channel("Sport 1"), channel("Eurosport")])
        XCTAssertEqual(index.search("sport").map(\.rawValue), ["Sport 1", "World Sport", "Eurosport"])
    }

    func testLimit() {
        let index = SearchIndex(channels: (0..<100).map { channel("Channel \($0)") })
        XCTAssertEqual(index.search("channel", limit: 10).count, 10)
    }
}

final class YouTubeLinkParserTests: XCTestCase {
    func testRecognizesCommonURLShapes() {
        let id = "dQw4w9WgXcQ"
        let inputs = [
            "https://www.youtube.com/watch?v=\(id)&t=42s",
            "https://m.youtube.com/watch?feature=share&v=\(id)",
            "https://youtu.be/\(id)?si=abc",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube.com/live/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "youtube.com/watch?v=\(id)",
            id
        ]
        for input in inputs {
            XCTAssertEqual(YouTubeLinkParser.videoID(fromString: input), id, input)
        }
    }

    func testRejectsNonYouTubeAndInvalidIDs() {
        XCTAssertNil(YouTubeLinkParser.videoID(fromString: "https://example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubeLinkParser.videoID(fromString: "https://www.youtube.com/watch?v=short"))
        XCTAssertNil(YouTubeLinkParser.videoID(fromString: "https://www.youtube.com/channel/UC123"))
        XCTAssertNil(YouTubeLinkParser.videoID(fromString: "<script>alert(1)</script>"))
        XCTAssertFalse(YouTubeLinkParser.isValidID("abc'def\"ghi"))
    }
}

final class BrowserInputTests: XCTestCase {
    func testExplicitURLsAreKept() {
        XCTAssertEqual(BrowserInput.resolve("https://apple.com/iphone", engine: .google)?.absoluteString, "https://apple.com/iphone")
        XCTAssertEqual(BrowserInput.resolve("http://example.com", engine: .google)?.absoluteString, "http://example.com")
    }

    func testBareDomainsUpgradeToHTTPS() {
        XCTAssertEqual(BrowserInput.resolve("apple.com", engine: .google)?.absoluteString, "https://apple.com")
        XCTAssertEqual(BrowserInput.resolve("news.example.co.uk/path?q=1", engine: .google)?.absoluteString, "https://news.example.co.uk/path?q=1")
        XCTAssertEqual(BrowserInput.resolve("192.168.1.10:8080", engine: .google)?.absoluteString, "https://192.168.1.10:8080")
    }

    func testSearchTerms() {
        let url = BrowserInput.resolve("swift concurrency tutorial", engine: .google)
        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "swift concurrency tutorial")
        XCTAssertEqual(BrowserInput.resolve("hello", engine: .duckDuckGo)?.host, "duckduckgo.com")
        XCTAssertEqual(BrowserInput.resolve("file.txt1", engine: .bing)?.host, "www.bing.com", "Numeric TLD is not a domain")
    }

    func testInvalidInputs() {
        XCTAssertNil(BrowserInput.resolve("   ", engine: .google))
        // Non-web schemes typed into the address bar become searches, never navigations.
        XCTAssertEqual(BrowserInput.resolve("file:///etc/passwd", engine: .google)?.host, "www.google.com")
        XCTAssertEqual(BrowserInput.resolve("javascript://alert(1)", engine: .google)?.host, "www.google.com")
    }

    func testNavigationPolicy() {
        XCTAssertEqual(BrowserNavigationPolicy.decide(url: URL(string: "https://a.com"), isUserInitiated: false), .allow)
        XCTAssertEqual(BrowserNavigationPolicy.decide(url: URL(string: "http://a.com"), isUserInitiated: false), .allow)
        XCTAssertEqual(BrowserNavigationPolicy.decide(url: URL(string: "file:///private/var"), isUserInitiated: true), .block)
        XCTAssertEqual(BrowserNavigationPolicy.decide(url: URL(string: "tel:123"), isUserInitiated: true), .openExternally)
        XCTAssertEqual(BrowserNavigationPolicy.decide(url: URL(string: "itms-apps://x"), isUserInitiated: false), .block)
        XCTAssertEqual(BrowserNavigationPolicy.decide(url: nil, isUserInitiated: true), .block)
    }

    func testUserURLNormalization() {
        XCTAssertEqual(URLValidator.userURL(from: "iptv.example.com/list.m3u")?.absoluteString, "https://iptv.example.com/list.m3u")
        XCTAssertNil(URLValidator.userURL(from: "ftp://example.com/list.m3u"))
        XCTAssertNil(URLValidator.userURL(from: "not a url"))
        XCTAssertNil(URLValidator.userURL(from: ""))
    }
}

final class LogRedactorTests: XCTestCase {
    func testRedactsCredentials() {
        let url = URL(string: "http://user:secret@panel.example.com/get.php?username=alice&password=hunter2&type=m3u")!
        let redacted = LogRedactor.redact(url)
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertTrue(redacted.contains("type=m3u"))
    }

    func testRedactsXtreamPathCredentials() {
        let redacted = LogRedactor.redact(URL(string: "http://panel.example.com/live/alice/hunter2/123.ts")!)
        XCTAssertEqual(redacted, "http://panel.example.com/live/***/***/123.ts")
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testExponentialBackoffWithCap() {
        let policy = ReconnectPolicy(maxAttempts: 6, baseDelay: 1, maxDelay: 10)
        XCTAssertEqual((1...6).compactMap(policy.delay(forAttempt:)), [1, 2, 4, 8, 10, 10])
        XCTAssertNil(policy.delay(forAttempt: 7))
        XCTAssertNil(policy.delay(forAttempt: 0))
    }

    func testHealthyPlaybackResetsAttempts() {
        let policy = ReconnectPolicy(healthyPlaybackDuration: 20)
        XCTAssertEqual(policy.nextAttempt(current: 3, playedFor: 25), 1)
        XCTAssertEqual(policy.nextAttempt(current: 3, playedFor: 2), 4)
        XCTAssertEqual(policy.nextAttempt(current: 0, playedFor: nil), 1)
    }
}

#if canImport(Compression)
final class GzipTests: XCTestCase {
    /// Builds a gzip member using raw deflate from the Compression framework.
    private func gzip(_ input: Data) -> Data {
        let capacity = input.count + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = input.withUnsafeBytes { raw in
            compression_encode_buffer(&output, capacity, raw.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        var data = Data([0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0, 0xff])
        data.append(contentsOf: Array("guide.xml".utf8) + [0]) // FNAME
        data.append(contentsOf: output[0..<written])
        data.append(contentsOf: [UInt8](repeating: 0, count: 8)) // CRC32 + ISIZE (not verified)
        return data
    }

    func testRoundTripInMemory() throws {
        let original = Data(String(repeating: "<programme>EPG</programme>\n", count: 20_000).utf8)
        let compressed = gzip(original)
        XCTAssertTrue(Gzip.isGzipped(compressed))
        XCTAssertEqual(try Gzip.decompress(compressed), original)
    }

    func testRoundTripFileStreaming() throws {
        let original = Data(String(repeating: "abcdefghij", count: 100_000).utf8)
        let dir = FileManager.default.temporaryDirectory
        let source = dir.appendingPathComponent(UUID().uuidString + ".gz")
        let destination = dir.appendingPathComponent(UUID().uuidString + ".xml")
        try gzip(original).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        XCTAssertTrue(Gzip.isGzipped(fileAt: source))
        try Gzip.decompress(fileAt: source, to: destination, chunkSize: 4096)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testRejectsInvalidHeader() {
        XCTAssertThrowsError(try Gzip.decompress(Data("plain text".utf8)))
    }
}
#endif
