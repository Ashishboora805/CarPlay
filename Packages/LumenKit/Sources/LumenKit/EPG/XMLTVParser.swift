import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum XMLTVError: Error, Equatable, Sendable {
    /// The document couldn't be parsed and no programmes were recovered.
    case malformed(String)
}

/// SAX-style XMLTV parser. Memory stays proportional to the retained programmes (after window
/// filtering), not to the document size, when used with `parse(stream:)`.
public enum XMLTVParser {
    /// Parses an in-memory XMLTV document.
    public static func parse(data: Data, window: DateInterval? = nil) throws -> EPGData {
        try run(XMLParser(data: data), window: window)
    }

    /// Parses from a stream (e.g. a downloaded file) without loading it fully into memory.
    public static func parse(stream: InputStream, window: DateInterval? = nil) throws -> EPGData {
        try run(XMLParser(stream: stream), window: window)
    }

    public static func parse(fileURL: URL, window: DateInterval? = nil) throws -> EPGData {
        guard let stream = InputStream(url: fileURL) else {
            throw XMLTVError.malformed("Unable to open EPG file")
        }
        return try parse(stream: stream, window: window)
    }

    private static func run(_ parser: XMLParser, window: DateInterval?) throws -> EPGData {
        let delegate = XMLTVParserDelegate(window: window)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let succeeded = parser.parse()
        let data = delegate.finish()
        if !succeeded && data.programs.isEmpty {
            let reason = parser.parserError.map { String(describing: $0) } ?? "Unknown XML error"
            throw XMLTVError.malformed(reason)
        }
        // When parsing fails part-way, keep what was recovered (EPG error recovery).
        return data
    }
}

final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private struct RawProgram {
        var channel: String
        var start: Date
        var end: Date?
        var title: String
        var subtitle: String?
        var summary: String?
        var category: String?
    }

    private enum Capture {
        case none, displayName, title, subtitle, desc, category
    }

    private static let maxSummaryLength = 400

    private let window: DateInterval?
    private var displayNames: [String: String] = [:]
    private var raw: [String: [RawProgram]] = [:]

    private var currentChannelID: String?
    private var currentProgram: RawProgram?
    private var capture: Capture = .none
    private var buffer = ""

    init(window: DateInterval?) {
        self.window = window
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "channel":
            currentChannelID = attributeDict["id"]
        case "display-name" where currentChannelID != nil:
            beginCapture(.displayName)
        case "programme":
            guard let channel = attributeDict["channel"], !channel.isEmpty,
                  let startString = attributeDict["start"], let start = XMLTVDate.parse(startString)
            else {
                currentProgram = nil
                return
            }
            let end = attributeDict["stop"].flatMap(XMLTVDate.parse)
            currentProgram = RawProgram(channel: channel, start: start, end: end, title: "")
        case "title" where currentProgram != nil && currentProgram?.title.isEmpty == true:
            beginCapture(.title)
        case "sub-title" where currentProgram != nil && currentProgram?.subtitle == nil:
            beginCapture(.subtitle)
        case "desc" where currentProgram != nil && currentProgram?.summary == nil:
            beginCapture(.desc)
        case "category" where currentProgram != nil && currentProgram?.category == nil:
            beginCapture(.category)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capture != .none else { return }
        if capture == .desc, buffer.count > Self.maxSummaryLength { return }
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "channel":
            currentChannelID = nil
        case "display-name":
            if capture == .displayName {
                let name = takeBuffer()
                if let id = currentChannelID, displayNames[id] == nil, !name.isEmpty { displayNames[id] = name }
            }
        case "title":
            if capture == .title { currentProgram?.title = takeBuffer() }
        case "sub-title":
            if capture == .subtitle { currentProgram?.subtitle = takeBuffer().nilIfEmpty }
        case "desc":
            if capture == .desc {
                var text = takeBuffer()
                if text.count > Self.maxSummaryLength {
                    text = String(text.prefix(Self.maxSummaryLength)) + "…"
                }
                currentProgram?.summary = text.nilIfEmpty
            }
        case "category":
            if capture == .category { currentProgram?.category = takeBuffer().nilIfEmpty }
        case "programme":
            if var program = currentProgram {
                if program.title.isEmpty { program.title = "Untitled" }
                raw[program.channel, default: []].append(program)
            }
            currentProgram = nil
        default:
            break
        }
    }

    private func beginCapture(_ kind: Capture) {
        capture = kind
        buffer = ""
    }

    private func takeBuffer() -> String {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        capture = .none
        return value
    }

    /// Sorts, fills in missing stop times, removes duplicates and applies the time window.
    func finish() -> EPGData {
        var programs: [String: [EPGProgram]] = [:]
        programs.reserveCapacity(raw.count)

        for (channel, list) in raw {
            let sorted = list.sorted { $0.start < $1.start }
            var result: [EPGProgram] = []
            result.reserveCapacity(sorted.count)
            for (index, item) in sorted.enumerated() {
                if let last = result.last, last.start == item.start { continue } // duplicate slot
                let nextStart = index + 1 < sorted.count ? sorted[index + 1].start : nil
                var end = item.end ?? nextStart ?? item.start.addingTimeInterval(3_600)
                if end <= item.start { end = nextStart ?? item.start.addingTimeInterval(3_600) }
                if let window, !(end > window.start && item.start < window.end) { continue }
                result.append(EPGProgram(channelKey: channel, start: item.start, end: end,
                                         title: item.title, subtitle: item.subtitle,
                                         summary: item.summary, category: item.category))
            }
            if !result.isEmpty { programs[channel] = result }
        }
        raw.removeAll()
        return EPGData(displayNames: displayNames, programs: programs)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
