import Foundation

/// Helpers for providers that use the widespread "Xtream Codes" panel API. Lumen only uses the
/// panel's standard playlist (`get.php`) and guide (`xmltv.php`) exports, so everything else in
/// the app (parser, EPG, player) is unchanged. Nothing here bypasses authentication: the user's
/// own username and password are sent to the user's own provider.
public enum XtreamCodes {
    public struct Account: Hashable, Sendable {
        public let server: URL
        public let username: String
        public let password: String

        public init(server: URL, username: String, password: String) {
            self.server = server
            self.username = username
            self.password = password
        }

        /// `get.php?...&type=m3u_plus&output=m3u8`. `m3u_plus` includes tvg-* attributes and
        /// `output=m3u8` requests HLS stream URLs, which AVPlayer can play (raw `.ts` can't).
        public var playlistURL: URL? {
            endpoint("get.php", extra: [
                URLQueryItem(name: "type", value: "m3u_plus"),
                URLQueryItem(name: "output", value: "m3u8")
            ])
        }

        public var epgURL: URL? {
            endpoint("xmltv.php", extra: [])
        }

        private func endpoint(_ name: String, extra: [URLQueryItem]) -> URL? {
            guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            components.path = path + "/" + name
            components.queryItems = [
                URLQueryItem(name: "username", value: username),
                URLQueryItem(name: "password", value: password)
            ] + extra
            return components.url
        }
    }

    /// Builds an account from user input. The server may be typed as `host`, `host:port` or a
    /// full URL; a missing scheme defaults to `http://` because most panels don't offer TLS.
    public static func account(server input: String, username: String, password: String) -> Account? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !pass.isEmpty else { return nil }

        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        // Users often paste a full get.php / player_api.php link; keep only the panel root.
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        if components.path.lowercased().hasSuffix(".php") {
            components.path = (components.path as NSString).deletingLastPathComponent
        }
        guard let server = components.url else { return nil }
        return Account(server: server, username: user, password: pass)
    }

    /// For Xtream-style live stream URLs (`/live/<user>/<pass>/<id>.ts`) returns the `.m3u8`
    /// variant the same panels serve. AVFoundation cannot play raw MPEG-TS over HTTP, so this
    /// is the only way such channels can play at all. Returns nil for other URLs.
    public static func hlsAlternative(for url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "ts" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        // live/<user>/<pass>/<id>.ts  or  <user>/<pass>/<id>.ts
        guard parts.count == 3 || (parts.count == 4 && parts[0].lowercased() == "live") else { return nil }
        return url.deletingPathExtension().appendingPathExtension("m3u8")
    }
}
