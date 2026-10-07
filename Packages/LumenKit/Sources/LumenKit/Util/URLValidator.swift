import Foundation

public enum URLValidator {
    private static let allowedSchemes: Set<String> = ["http", "https"]

    /// Parses an absolute http(s) URL with a host. Tolerates unescaped spaces and other
    /// characters commonly found in hand-written playlists.
    public static func httpURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = URL(string: trimmed)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.init(charactersIn: "#%"))).flatMap(URL.init(string:))
        guard let url = candidate,
              let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme),
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Stream URLs accepted by the player (AVFoundation handles http/https; HLS is preferred).
    public static func streamURL(from input: String) -> URL? {
        httpURL(from: input)
    }

    /// Normalizes user-typed playlist / EPG URLs. Adds `https://` when the scheme is missing.
    public static func userURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.contains("://") {
            return httpURL(from: trimmed)
        }
        return httpURL(from: "https://" + trimmed)
    }

    public static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }
}
