import Foundation

/// Produces log-safe URL strings: removes user-info, masks credential-like query values and
/// the username/password path segments used by common IPTV panels (`/live/<user>/<pass>/…`).
public enum LogRedactor {
    private static let sensitiveQueryNames: Set<String> = [
        "username", "user", "password", "pass", "pwd", "token", "auth", "key", "apikey",
        "api_key", "access_token", "signature", "sig", "session", "secret"
    ]
    private static let credentialPathPrefixes: Set<String> = ["live", "movie", "series", "timeshift"]
    private static let mask = "***"

    public static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid url>"
        }
        components.user = nil
        components.password = nil

        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                sensitiveQueryNames.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: mask)
                    : item
            }
        }

        var segments = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // segments[0] is "" for absolute paths.
        if segments.count >= 4, credentialPathPrefixes.contains(segments[1].lowercased()) {
            segments[2] = mask
            segments[3] = mask
            components.path = segments.joined(separator: "/")
        }

        return components.string?.removingPercentEncoding ?? components.string ?? "<invalid url>"
    }
}
