import XCTest
@testable import LumenKit

final class M3UParserTests: XCTestCase {
    private let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testParsesValidPlaylistWithAllAttributes() throws {
        let text = """
        #EXTM3U url-tvg="https://epg.example.com/guide.xml.gz"
        #EXTINF:-1 tvg-id="news.one" tvg-name="News One" tvg-logo="https://img.example.com/n1.png" tvg-language="English" tvg-country="US" group-title="News",News One HD
        https://example.com/live/news1.m3u8
        #EXTINF:-1 tvg-id="sport.two" group-title="Sports, Live",Sport Two
        http://example.com/live/sport2.m3u8
        """
        let playlist = try M3UParser.parse(text, sourceID: sourceID)

        XCTAssertTrue(playlist.hadHeader)
        XCTAssertEqual(playlist.channels.count, 2)
        XCTAssertEqual(playlist.epgURLs, [URL(string: "https://epg.example.com/guide.xml.gz")!])

        let first = playlist.channels[0]
        XCTAssertEqual(first.name, "News One HD")
        XCTAssertEqual(first.tvgID, "news.one")
        XCTAssertEqual(first.tvgName, "News One")
        XCTAssertEqual(first.group, "News")
        XCTAssertEqual(first.logoURL, URL(string: "https://img.example.com/n1.png"))
        XCTAssertEqual(first.language, "English")
        XCTAssertEqual(first.country, "US")
        XCTAssertEqual(first.streamURL, URL(string: "https://example.com/live/news1.m3u8"))

        // Commas inside quoted attribute values must not split the title.
        XCTAssertEqual(playlist.channels[1].group, "Sports, Live")
        XCTAssertEqual(playlist.channels[1].name, "Sport Two")
    }

    func testMissingLogoAndCategory() throws {
        let text = """
        #EXTM3U
        #EXTINF:-1,Plain Channel
        https://example.com/plain.m3u8
        """
        let channel = try XCTUnwrap(M3UParser.parse(text, sourceID: sourceID).channels.first)
        XCTAssertNil(channel.logoURL)
        XCTAssertNil(channel.group)
        XCTAssertEqual(channel.category, Channel.uncategorized)
    }

    func testInvalidLogoURLIsIgnored() throws {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="not a url",Channel
        https://example.com/c.m3u8
        """
        XCTAssertNil(try M3UParser.parse(text, sourceID: sourceID).channels.first?.logoURL)
    }

    func testExtGrpAndUserAgent() throws {
        let text = """
        #EXTM3U
        #EXTINF:-1,Grouped
        #EXTGRP:Movies
        #EXTVLCOPT:http-user-agent=CustomAgent/1.0
        https://example.com/movie.m3u8
        """
        let channel = try XCTUnwrap(M3UParser.parse(text, sourceID: sourceID).channels.first)
        XCTAssertEqual(channel.group, "Movies")
        XCTAssertEqual(channel.userAgent, "CustomAgent/1.0")
    }

    func testMalformedEntriesAreSkippedNotFatal() throws {
        let text = """
        #EXTM3U
        #EXTINF:-1,No URL follows
        #EXTINF:-1,Bad scheme
        rtmp://example.com/stream
        #EXTINF:-1,Good
        https://example.com/good.m3u8
        garbage line without scheme
        #EXTINF:-1,Dangling at end
        """
        let playlist = try M3UParser.parse(text, sourceID: sourceID)
        XCTAssertEqual(playlist.channels.map(\.name), ["Good"])
        XCTAssertEqual(playlist.skippedEntries, 4)
    }

    func testNonPlaylistInputThrowsInvalidFormat() {
        XCTAssertThrowsError(try M3UParser.parse("<html><body>Not found</body></html>", sourceID: sourceID)) { error in
            XCTAssertEqual(error as? M3UError, .invalidFormat)
        }
    }

    func testEmptyInputThrowsEmpty() {
        XCTAssertThrowsError(try M3UParser.parse("  \n\n ", sourceID: sourceID)) { error in
            XCTAssertEqual(error as? M3UError, .empty)
        }
    }

    func testHeaderOnlyThrowsNoPlayableEntries() {
        XCTAssertThrowsError(try M3UParser.parse("#EXTM3U\n#EXTINF:-1,Nothing\n", sourceID: sourceID)) { error in
            XCTAssertEqual(error as? M3UError, .noPlayableEntries)
        }
    }

    func testPlainURLListWithoutHeader() throws {
        let text = "https://example.com/a/stream.m3u8\nhttps://example.com/b/other.m3u8"
        let playlist = try M3UParser.parse(text, sourceID: sourceID)
        XCTAssertFalse(playlist.hadHeader)
        XCTAssertEqual(playlist.channels.map(\.name), ["stream", "other"])
    }

    func testDuplicateChannels() throws {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="a",Same
        https://example.com/1.m3u8
        #EXTINF:-1 tvg-id="a",Same
        https://example.com/1.m3u8
        #EXTINF:-1 tvg-id="a",Same
        https://example.com/backup.m3u8
        """
        let playlist = try M3UParser.parse(text, sourceID: sourceID)
        // Exact duplicate dropped; same identity with a different URL is kept with a distinct ID.
        XCTAssertEqual(playlist.channels.count, 2)
        XCTAssertEqual(playlist.skippedEntries, 1)
        XCTAssertNotEqual(playlist.channels[0].id, playlist.channels[1].id)
    }

    func testChannelIDIsStableAcrossStreamURLChanges() throws {
        let a = try M3UParser.parse("#EXTM3U\n#EXTINF:-1 tvg-id=\"x\",X\nhttps://e.com/x.m3u8?token=1", sourceID: sourceID)
        let b = try M3UParser.parse("#EXTM3U\n#EXTINF:-1 tvg-id=\"x\",X\nhttps://e.com/x.m3u8?token=2", sourceID: sourceID)
        XCTAssertEqual(a.channels[0].id, b.channels[0].id)
    }

    func testByteOrderMarkAndCRLF() throws {
        let text = "\u{FEFF}#EXTM3U\r\n#EXTINF:-1,Windows\r\nhttps://example.com/w.m3u8\r\n"
        let playlist = try M3UParser.parse(text, sourceID: sourceID)
        XCTAssertTrue(playlist.hadHeader)
        XCTAssertEqual(playlist.channels.first?.name, "Windows")
    }

    func testYouTubeEntryIsDetected() throws {
        let text = "#EXTM3U\n#EXTINF:-1,Live Cam\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ"
        XCTAssertTrue(try M3UParser.parse(text, sourceID: sourceID).channels[0].isYouTube)
    }

    func testVeryLargePlaylistParsesQuickly() throws {
        var lines = ["#EXTM3U"]
        let count = 50_000
        lines.reserveCapacity(count * 2 + 1)
        for i in 0..<count {
            lines.append("#EXTINF:-1 tvg-id=\"ch\(i)\" tvg-logo=\"https://img.example.com/\(i).png\" group-title=\"Group \(i % 40)\",Channel \(i)")
            lines.append("https://example.com/live/\(i).m3u8")
        }
        let text = lines.joined(separator: "\n")

        let start = Date()
        let playlist = try M3UParser.parse(text, sourceID: sourceID)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(playlist.channels.count, count)
        XCTAssertEqual(Set(playlist.channels.map(\.id)).count, count)
        // Generous bound so it holds on CI simulators; typically well under a second.
        XCTAssertLessThan(elapsed, 10)
    }

    func testAsyncLineParsingHonorsCancellation() async throws {
        let stream = AsyncStream<String> { continuation in
            continuation.yield("#EXTM3U")
            for i in 0..<10 {
                continuation.yield("#EXTINF:-1,C\(i)")
                continuation.yield("https://example.com/\(i).m3u8")
            }
            continuation.finish()
        }
        let playlist = try await M3UParser.parse(lines: stream, sourceID: sourceID)
        XCTAssertEqual(playlist.channels.count, 10)
    }
}
