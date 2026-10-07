import Foundation

/// Extracts YouTube video IDs from the URL shapes users paste. No network access, no scraping.
public enum YouTubeLinkParser {
    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com"
    ]
    private static let pathPrefixes = ["embed", "shorts", "live", "v", "e"]

    public static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }

        if host == "youtu.be" || host == "www.youtu.be" {
            return components.first.flatMap(validated)
        }
        guard hosts.contains(host) else { return nil }

        if components.first == "watch" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            return query?.first(where: { $0.name == "v" })?.value.flatMap(validated)
        }
        if components.count >= 2, pathPrefixes.contains(components[0]) {
            return validated(components[1])
        }
        return nil
    }

    /// Accepts a URL string or a bare 11-character video ID.
    public static func videoID(fromString input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidID(trimmed) { return trimmed }
        if let url = URL(string: trimmed), url.host != nil { return videoID(from: url) }
        if let url = URL(string: "https://" + trimmed), url.host != nil { return videoID(from: url) }
        return nil
    }

    public static func isValidID(_ candidate: String) -> Bool {
        guard candidate.utf8.count == 11 else { return false }
        return candidate.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 95 // '-' '_'
        }
    }

    private static func validated(_ candidate: String) -> String? {
        isValidID(candidate) ? candidate : nil
    }
}
