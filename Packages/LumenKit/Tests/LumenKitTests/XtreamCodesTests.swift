import XCTest
@testable import LumenKit

final class XtreamCodesTests: XCTestCase {
    func testBuildsPlaylistAndGuideURLs() throws {
        let account = try XCTUnwrap(XtreamCodes.account(server: "panel.example.com:8080", username: "alice", password: "p@ss word"))
        XCTAssertEqual(account.server.absoluteString, "http://panel.example.com:8080")
        XCTAssertEqual(account.playlistURL?.absoluteString,
                       "http://panel.example.com:8080/get.php?username=alice&password=p@ss%20word&type=m3u_plus&output=m3u8")
        XCTAssertEqual(account.epgURL?.absoluteString,
                       "http://panel.example.com:8080/xmltv.php?username=alice&password=p@ss%20word")
    }

    func testAcceptsFullLinksAndKeepsScheme() throws {
        let fromGet = try XCTUnwrap(XtreamCodes.account(server: "https://panel.example.com/get.php?username=x&password=y&type=m3u",
                                                       username: "u", password: "p"))
        XCTAssertEqual(fromGet.server.absoluteString, "https://panel.example.com")
        XCTAssertEqual(fromGet.playlistURL?.scheme, "https")

        let withBase = try XCTUnwrap(XtreamCodes.account(server: "http://host.example.com/iptv/", username: "u", password: "p"))
        XCTAssertEqual(withBase.epgURL?.absoluteString, "http://host.example.com/iptv/xmltv.php?username=u&password=p")
    }

    func testRejectsInvalidInput() {
        XCTAssertNil(XtreamCodes.account(server: "", username: "u", password: "p"))
        XCTAssertNil(XtreamCodes.account(server: "panel.example.com", username: "", password: "p"))
        XCTAssertNil(XtreamCodes.account(server: "panel.example.com", username: "u", password: " "))
        XCTAssertNil(XtreamCodes.account(server: "ftp://panel.example.com", username: "u", password: "p"))
        XCTAssertNil(XtreamCodes.account(server: "not a host", username: "u", password: "p"))
    }

    func testHLSAlternativeForRawTSStreams() {
        XCTAssertEqual(XtreamCodes.hlsAlternative(for: URL(string: "http://p.example.com:8080/live/u/p/123.ts")!)?.absoluteString,
                       "http://p.example.com:8080/live/u/p/123.m3u8")
        XCTAssertEqual(XtreamCodes.hlsAlternative(for: URL(string: "http://p.example.com/u/p/123.ts")!)?.absoluteString,
                       "http://p.example.com/u/p/123.m3u8")
        XCTAssertNil(XtreamCodes.hlsAlternative(for: URL(string: "http://p.example.com/live/u/p/123.m3u8")!))
        XCTAssertNil(XtreamCodes.hlsAlternative(for: URL(string: "http://cdn.example.com/some/deep/path/file.ts")!))
        XCTAssertNil(XtreamCodes.hlsAlternative(for: URL(string: "https://example.com/stream.ts")!), "Not an Xtream path shape")
    }
}
