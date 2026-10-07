import Foundation
import Observation

enum AppTab: Hashable {
    case home, live, guide, web, settings
}

enum WebSegment: String, CaseIterable, Identifiable {
    case browser, youtube
    var id: String { rawValue }
    var title: String { self == .browser ? "Browser" : "YouTube" }
}

enum LiveFilter: Hashable {
    case all
    case favorites
    case category(String)

    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .category(let name): name
        }
    }
}

struct YouTubeRequest: Identifiable, Hashable {
    let videoID: String
    let title: String
    var id: String { videoID }
}

/// App-wide navigation state, so deep links (Home → category, playlist YouTube entry →
/// YouTube player, "Browse YouTube" → browser) don't need view-to-view plumbing.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .home
    var webSegment: WebSegment = .browser
    var liveFilter: LiveFilter = .all
    var youtubeRequest: YouTubeRequest?
    var isAddingSource = false
    var pendingBrowserURL: URL?

    func presentYouTube(videoID: String, title: String) {
        youtubeRequest = YouTubeRequest(videoID: videoID, title: title)
    }

    func openInBrowser(_ url: URL) {
        pendingBrowserURL = url
        webSegment = .browser
        selectedTab = .web
    }

    func showCategory(_ name: String) {
        liveFilter = .category(name)
        selectedTab = .live
    }

    func showFavorites() {
        liveFilter = .favorites
        selectedTab = .live
    }
}
