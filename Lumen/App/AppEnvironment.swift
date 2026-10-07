import Foundation
import LumenKit
import SwiftData
import UIKit

/// Composition root. Built once and shared by the iPhone window scene and the CarPlay scene
/// (CarPlay can launch the app without any iPhone UI, so nothing here depends on a window).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let modelContainer: ModelContainer
    let keychain: KeychainStore
    let settings: AppSettings
    let http: HTTPClient
    let network: NetworkMonitor
    let router: AppRouter
    let library: LibraryStore
    let epg: EPGManager
    let playlists: PlaylistManager
    let channels: ChannelRepository
    let player: PlayerManager
    let browser: BrowserManager
    let youtube: YouTubeController
    let images: ImagePipeline

    private var didBootstrap = false
    private var memoryWarningToken: NSObjectProtocol?

    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-UITestMode") }

    private init() {
        let inMemory = Self.isUITesting
        modelContainer = PersistenceFactory.makeContainer(inMemory: inMemory)
        keychain = KeychainStore(service: inMemory ? "app.lumen.secrets.uitest" : "app.lumen.secrets")
        settings = AppSettings(defaults: inMemory ? (UserDefaults(suiteName: "app.lumen.uitest") ?? .standard) : .standard)
        http = HTTPClient()
        network = NetworkMonitor()
        router = AppRouter()
        images = ImagePipeline.shared
        library = LibraryStore(container: modelContainer, keychain: keychain)
        epg = EPGManager(loader: EPGLoader(http: http), settings: settings)
        playlists = PlaylistManager(http: http, cache: ChannelCache())
        channels = ChannelRepository(manager: playlists, library: library, network: network, epg: epg)
        player = PlayerManager(settings: settings, network: network, library: library, epg: epg, router: router)
        browser = BrowserManager(settings: settings)
        youtube = YouTubeController(http: http, keychain: keychain)
    }

    /// Starts background work. Safe to call from both scenes; runs once.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        memoryWarningToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [images] _ in
            images.clearMemory()
        }

        #if DEBUG
        if Self.isUITesting {
            Task { await channels.injectForTesting(UITestFixtures.playlist) }
            return
        }
        #endif

        Task(priority: .userInitiated) { await channels.bootstrap() }
        Task.detached(priority: .background) { [images] in
            try? await Task.sleep(for: .seconds(10))
            await images.trimDisk()
        }
    }

    /// Clears logos, guide data and cached playlists (channels are re-fetched).
    func clearCaches() async {
        await images.clearAll()
        await epg.clearCache()
        await channels.clearCache()
        Task { await channels.refreshAll(force: true) }
    }

    func cacheSize() async -> Int64 {
        await Task.detached(priority: .utility) {
            CacheDirectories.size(of: CacheDirectories.logos)
                + CacheDirectories.size(of: CacheDirectories.epg)
                + CacheDirectories.size(of: CacheDirectories.channels)
        }.value
    }
}

#if DEBUG
/// Deterministic, synthetic channels for UI tests (no network).
enum UITestFixtures {
    static let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    static var playlist: CachedPlaylist {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="demo.news" group-title="News",Demo News
        https://example.com/demo/news.m3u8
        #EXTINF:-1 tvg-id="demo.sports" group-title="Sports",Demo Sports
        https://example.com/demo/sports.m3u8
        #EXTINF:-1 tvg-id="demo.music" group-title="Music",Demo Music
        https://example.com/demo/music.m3u8
        """
        let parsed = (try? M3UParser.parse(text, sourceID: sourceID))?.channels ?? []
        return CachedPlaylist(sourceID: sourceID, channels: parsed, epgURLs: [], fetchedAt: .now)
    }
}
#endif
