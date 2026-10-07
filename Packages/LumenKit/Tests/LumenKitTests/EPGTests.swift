import XCTest
@testable import LumenKit

final class EPGTests: XCTestCase {
    private func date(_ string: String) -> Date { XMLTVDate.parse(string)! }

    private let sampleXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="news.one"><display-name>News One</display-name></channel>
      <channel id="sport.two"><display-name lang="en">Sport Two</display-name><display-name>S2</display-name></channel>
      <programme start="20261007120000 +0000" stop="20261007130000 +0000" channel="news.one">
        <title lang="en">News</title><desc>Midday news &amp; weather.</desc><category>News</category>
      </programme>
      <programme start="20261007130000 +0000" stop="20261007140000 +0000" channel="news.one">
        <title>Business</title><sub-title>Markets</sub-title>
      </programme>
      <programme start="20261007140000 +0000" channel="news.one"><title>World News</title></programme>
      <programme start="20261007150000 +0000" stop="20261007160000 +0000" channel="news.one"><title>Sports</title></programme>
      <programme start="20261007120000 +0200" stop="20261007130000 +0200" channel="sport.two"><title>Match</title></programme>
    </tv>
    """

    func testParsesValidXMLTV() throws {
        let data = try XMLTVParser.parse(data: Data(sampleXML.utf8))
        XCTAssertEqual(data.displayNames["news.one"], "News One")
        XCTAssertEqual(data.displayNames["sport.two"], "Sport Two")

        let news = try XCTUnwrap(data.programs["news.one"])
        XCTAssertEqual(news.map(\.title), ["News", "Business", "World News", "Sports"])
        XCTAssertEqual(news[0].summary, "Midday news & weather.")
        XCTAssertEqual(news[0].category, "News")
        XCTAssertEqual(news[1].subtitle, "Markets")
    }

    func testMissingStopUsesNextProgramStart() throws {
        let news = try XCTUnwrap(XMLTVParser.parse(data: Data(sampleXML.utf8)).programs["news.one"])
        XCTAssertEqual(news[2].end, date("20261007150000 +0000"))
    }

    func testTimezoneConversion() throws {
        let match = try XCTUnwrap(XMLTVParser.parse(data: Data(sampleXML.utf8)).programs["sport.two"]?.first)
        XCTAssertEqual(match.start, date("20261007100000 +0000"))
        XCTAssertEqual(XMLTVDate.parse("20261007100000"), date("20261007100000 +0000"), "No offset means UTC")
        XCTAssertEqual(XMLTVDate.parse("20261007053000 -0430"), date("20261007100000 +0000"))
        XCTAssertEqual(XMLTVDate.parse("202610071000 +0000"), date("20261007100000 +0000"), "Seconds are optional")
        XCTAssertNil(XMLTVDate.parse("2026-10-07"))
        XCTAssertNil(XMLTVDate.parse("20261307100000 +0000"))
    }

    func testDateMatchesFoundationCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let expected = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 23, minute: 59, second: 58))
        XCTAssertEqual(XMLTVDate.parse("20240229235958 +0000"), expected)
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try XMLTVParser.parse(data: Data("<tv><programme start=".utf8))) { error in
            guard case .malformed = error as? XMLTVError else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testPartiallyMalformedXMLRecoversParsedPrograms() throws {
        let xml = """
        <tv><programme start="20261007120000 +0000" stop="20261007130000 +0000" channel="a"><title>Kept</title></programme>
        <programme start="20261007130000 +0000" channel="a"><title>Broken</tit
        """
        let data = try XMLTVParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(data.programs["a"]?.map(\.title), ["Kept"])
    }

    func testProgramsWithoutRequiredAttributesAreIgnored() throws {
        let xml = """
        <tv>
          <programme stop="20261007130000 +0000" channel="a"><title>No start</title></programme>
          <programme start="20261007120000 +0000"><title>No channel</title></programme>
          <programme start="20261007120000 +0000" stop="20261007130000 +0000" channel="a"></programme>
        </tv>
        """
        let data = try XMLTVParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(data.programs["a"]?.map(\.title), ["Untitled"])
    }

    func testWindowFiltering() throws {
        let window = DateInterval(start: date("20261007133000 +0000"), end: date("20261007150000 +0000"))
        let news = try XCTUnwrap(XMLTVParser.parse(data: Data(sampleXML.utf8), window: window).programs["news.one"])
        XCTAssertEqual(news.map(\.title), ["Business", "World News"])
    }

    func testIndexNowNextAndSchedule() throws {
        let index = EPGIndex(data: try XMLTVParser.parse(data: Data(sampleXML.utf8)))
        let at = date("20261007133000 +0000")
        XCTAssertEqual(index.current(for: "news.one", at: at)?.title, "Business")
        XCTAssertEqual(index.next(for: "news.one", after: at)?.title, "World News")
        XCTAssertNil(index.current(for: "news.one", at: date("20261007110000 +0000")))
        XCTAssertEqual(index.next(for: "news.one", after: date("20261007110000 +0000"))?.title, "News")

        let schedule = index.schedule(for: "news.one", from: at, to: date("20261007160000 +0000"))
        XCTAssertEqual(schedule.map(\.title), ["Business", "World News", "Sports"])
        XCTAssertEqual(schedule[0].progress(at: at), 0.5, accuracy: 0.001)
    }

    func testIndexResolvesChannelKeys() throws {
        let index = EPGIndex(data: try XMLTVParser.parse(data: Data(sampleXML.utf8)))
        let source = UUID()
        func channel(name: String, tvgID: String?, tvgName: String? = nil) -> Channel {
            Channel(id: ChannelID(rawValue: name), sourceID: source, name: name,
                    streamURL: URL(string: "https://e.com/\(name.count)")!, tvgID: tvgID, tvgName: tvgName)
        }
        XCTAssertEqual(index.key(for: channel(name: "x", tvgID: "news.one")), "news.one")
        XCTAssertEqual(index.key(for: channel(name: "x", tvgID: "NEWS.ONE")), "news.one")
        XCTAssertEqual(index.key(for: channel(name: "Spört Two", tvgID: nil)), "sport.two")
        XCTAssertEqual(index.key(for: channel(name: "zzz", tvgID: nil, tvgName: "news one")), "news.one")
        XCTAssertNil(index.key(for: channel(name: "Unknown", tvgID: "nope")))
    }

    func testLargeEPGParses() throws {
        var xml = "<tv>"
        let channels = 300
        let perChannel = 100
        let base = date("20261007000000 +0000").timeIntervalSince1970
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        for c in 0..<channels {
            xml += "<channel id=\"c\(c)\"><display-name>Channel \(c)</display-name></channel>"
            for p in 0..<perChannel {
                let start = formatter.string(from: Date(timeIntervalSince1970: base + Double(p) * 1800))
                let stop = formatter.string(from: Date(timeIntervalSince1970: base + Double(p + 1) * 1800))
                xml += "<programme start=\"\(start) +0000\" stop=\"\(stop) +0000\" channel=\"c\(c)\"><title>P\(p)</title><desc>Description \(p)</desc></programme>"
            }
        }
        xml += "</tv>"
        let data = try XMLTVParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(data.programs.count, channels)
        XCTAssertEqual(data.programCount, channels * perChannel)
    }

    func testCodableRoundTripAndPruning() throws {
        let data = try XMLTVParser.parse(data: Data(sampleXML.utf8))
        let encoded = try PropertyListEncoder().encode(data)
        let decoded = try PropertyListDecoder().decode(EPGData.self, from: encoded)
        XCTAssertEqual(decoded.programCount, data.programCount)

        let pruned = decoded.pruned(to: DateInterval(start: date("20261007145900 +0000"), duration: 3600))
        XCTAssertEqual(pruned.programs["news.one"]?.map(\.title), ["World News", "Sports"])
        XCTAssertNil(pruned.programs["sport.two"])
    }
}
