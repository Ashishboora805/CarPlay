import Foundation

public enum SearchEngine: String, CaseIterable, Codable, Sendable, Identifiable {
    case google, duckDuckGo, bing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    public var homeURL: URL {
        switch self {
        case .google: URL(string: "https://www.google.com")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com")!
        case .bing: URL(string: "https://www.bing.com")!
        }
    }

    public func searchURL(for query: String) -> URL {
        var components: URLComponents
        switch self {
        case .google: components = URLComponents(string: "https://www.google.com/search")!
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")!
        case .bing: components = URLComponents(string: "https://www.bing.com/search")!
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url ?? homeURL
    }
}

/// Turns address-bar text into a URL: explicit URLs are kept, bare domains get `https://`
/// (HTTPS-first), and everything else becomes a search.
public enum BrowserInput {
    public static func resolve(_ text: String, engine: SearchEngine) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased() == "about:blank" { return URL(string: "about:blank") }

        if let schemeEnd = trimmed.range(of: "://") {
            let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
            if scheme == "http" || scheme == "https", let url = URLValidator.httpURL(from: trimmed) {
                return url
            }
            return engine.searchURL(for: trimmed)
        }

        if !trimmed.contains(where: \.isWhitespace), looksLikeHost(trimmed),
           let url = URLValidator.httpURL(from: "https://" + trimmed) {
            return url
        }
        return engine.searchURL(for: trimmed)
    }

    static func looksLikeHost(_ text: String) -> Bool {
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let host = hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
        if host.lowercased() == "localhost" { return true }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true } // IPv4
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { label in
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

public enum NavigationDecision: Equatable, Sendable {
    case allow
    case openExternally
    case block
}

/// Decides what the in-app browser does with a navigation. Web content may only load
/// http(s)/about/blob; local files and script URLs are blocked; other schemes (tel:, mailto:,
/// app links) are handed to the system, but only when the user tapped a link.
public enum BrowserNavigationPolicy {
    public static func decide(url: URL?, isUserInitiated: Bool) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .block }
        switch scheme {
        case "http", "https", "about", "blob":
            return .allow
        case "file", "javascript", "data":
            return .block
        default:
            return isUserInitiated ? .openExternally : .block
        }
    }
}
