import Foundation
import LumenKit
import Observation

struct YouTubeVideo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let channelTitle: String?
    let thumbnailURL: URL?
}

/// YouTube on iPhone: search through the official YouTube Data API v3 (only when the user has
/// entered their own API key, kept in the Keychain) and a small list of recently played videos.
/// Playback always uses the official IFrame embed; nothing is downloaded or extracted.
@MainActor
@Observable
final class YouTubeController {
    private(set) var results: [YouTubeVideo] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var recents: [YouTubeVideo] = []
    private(set) var hasAPIKey = false

    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(http: HTTPClient, keychain: KeychainStore, defaults: UserDefaults = .standard) {
        self.http = http
        self.keychain = keychain
        self.defaults = defaults
        hasAPIKey = keychain.string(for: KeychainStore.Keys.youtubeAPIKey)?.isEmpty == false
        if let data = defaults.data(forKey: AppSettings.Keys.youtubeRecents),
           let decoded = try? JSONDecoder().decode([YouTubeVideo].self, from: data) {
            recents = decoded
        }
    }

    // MARK: - API key

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.remove(KeychainStore.Keys.youtubeAPIKey)
        } else {
            keychain.set(trimmed, for: KeychainStore.Keys.youtubeAPIKey)
        }
        hasAPIKey = !trimmed.isEmpty
    }

    // MARK: - Search

    /// Debounced search; cancels the previous query.
    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        guard let key = keychain.string(for: KeychainStore.Keys.youtubeAPIKey), !key.isEmpty else {
            searchError = "Add your YouTube Data API key in Settings to search."
            return
        }
        let http = http
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let videos = try await Self.fetch(query: trimmed, key: key, http: http)
                guard !Task.isCancelled else { return }
                results = videos
                searchError = videos.isEmpty ? "No videos found." : nil
            } catch {
                guard !Task.isCancelled else { return }
                let mapped = AppError.from(error)
                searchError = mapped == .authenticationFailed || mapped == .http(status: 400)
                    ? "YouTube rejected the API key. Check it in Settings."
                    : mapped.title
            }
        }
    }

    private static func fetch(query: String, key: String, http: HTTPClient) async throws -> [YouTubeVideo] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "maxResults", value: "25"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components.url else { throw AppError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        // Lets users restrict their key to this app's bundle ID in Google Cloud Console.
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        let (data, _) = try await http.data(for: request, retries: 0)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.items.compactMap { item in
            guard let id = item.id.videoId, YouTubeLinkParser.isValidID(id) else { return nil }
            return YouTubeVideo(id: id, title: Self.decodeEntities(item.snippet.title),
                                channelTitle: item.snippet.channelTitle,
                                thumbnailURL: item.snippet.thumbnails?.medium?.url ?? item.snippet.thumbnails?.default?.url)
        }
    }

    /// The Data API returns HTML-escaped titles.
    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: - Recents

    func recordPlayed(_ video: YouTubeVideo) {
        recents.removeAll { $0.id == video.id }
        recents.insert(video, at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: AppSettings.Keys.youtubeRecents)
        }
    }

    func clearRecents() {
        recents = []
        defaults.removeObject(forKey: AppSettings.Keys.youtubeRecents)
    }

    // MARK: - Decoding

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct ID: Decodable { let videoId: String? }
            struct Snippet: Decodable {
                struct Thumbnails: Decodable {
                    struct Thumbnail: Decodable { let url: URL? }
                    let `default`: Thumbnail?
                    let medium: Thumbnail?
                }
                let title: String
                let channelTitle: String?
                let thumbnails: Thumbnails?
            }
            let id: ID
            let snippet: Snippet
        }
        let items: [Item]
    }
}
