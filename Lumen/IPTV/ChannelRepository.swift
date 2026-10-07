import Foundation
import LumenKit
import Observation

/// Main-actor read model of all channels across enabled sources.
///
/// Startup path: cached playlists are read from disk in the background and shown immediately;
/// only stale sources are then refreshed from the network (never while offline).
@MainActor
@Observable
final class ChannelRepository {
    enum SourceStatus: Equatable {
        case idle
        case loading
        case loaded(count: Int)
        case failed(AppError)
    }

    private(set) var snapshot = LibrarySnapshot.empty
    private(set) var status: [UUID: SourceStatus] = [:]
    private(set) var isRefreshing = false
    private(set) var hasLoadedCache = false
    /// Most recent refresh error, shown as a non-blocking banner.
    var bannerError: AppError?

    @ObservationIgnored private var playlists: [UUID: CachedPlaylist] = [:]
    @ObservationIgnored private let manager: PlaylistManager
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let epg: EPGManager
    @ObservationIgnored private var rebuildGeneration = 0

    init(manager: PlaylistManager, library: LibraryStore, network: NetworkMonitor, epg: EPGManager) {
        self.manager = manager
        self.library = library
        self.network = network
        self.epg = epg
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        let ids = library.sources.map(\.id)
        playlists = await manager.loadCached(ids)
        await rebuildSnapshot()
        hasLoadedCache = true
        await refreshAll(force: false)
    }

    /// Refreshes stale (or all, when `force`) enabled sources, then the guide.
    func refreshAll(force: Bool) async {
        // Until the disk cache is loaded every source would look stale; bootstrap() calls this itself.
        guard hasLoadedCache, !isRefreshing else { return }
        let sources = library.descriptors(enabledOnly: true)
        let targets = sources.filter { force || $0.isStale() || playlists[$0.id] == nil }

        if !targets.isEmpty {
            guard network.isConnected else {
                if force { bannerError = .offline }
                for source in targets where playlists[source.id] == nil {
                    status[source.id] = .failed(.offline)
                }
                await refreshGuide(sources: sources, force: false)
                return
            }
            await refresh(targets)
        }
        await refreshGuide(sources: sources, force: force)
    }

    func refresh(sourceID: UUID) async {
        guard let source = library.descriptors(enabledOnly: true).first(where: { $0.id == sourceID }) else {
            await sourcesDidChange()
            return
        }
        await refresh([source])
        await refreshGuide(sources: library.descriptors(enabledOnly: true), force: false)
    }

    /// Call after sources are enabled, disabled or deleted.
    func sourcesDidChange() async {
        let known = Set(library.sources.map(\.id))
        for id in playlists.keys where !known.contains(id) {
            playlists[id] = nil
            status[id] = nil
            await manager.removeCache(for: id)
        }
        // Newly enabled sources without a cache get fetched.
        let missing = library.descriptors(enabledOnly: true).filter { playlists[$0.id] == nil }
        if !missing.isEmpty, network.isConnected {
            await refresh(missing)
        } else {
            await rebuildSnapshot()
        }
        await refreshGuide(sources: library.descriptors(enabledOnly: true), force: false)
    }

    func clearCache() async {
        await manager.clearAll()
        playlists.removeAll()
        status.removeAll()
        await rebuildSnapshot()
    }

    private func refresh(_ targets: [SourceDescriptor]) async {
        isRefreshing = true
        defer { isRefreshing = false }
        for source in targets { status[source.id] = .loading }

        let manager = manager
        var lastError: AppError?
        await withTaskGroup(of: (UUID, Result<CachedPlaylist, AppError>).self) { group in
            for source in targets {
                group.addTask {
                    do {
                        return (source.id, .success(try await manager.refresh(source)))
                    } catch {
                        return (source.id, .failure(AppError.from(error)))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let playlist):
                    playlists[id] = playlist
                    status[id] = .loaded(count: playlist.channels.count)
                    library.markRefreshed(id: id, at: playlist.fetchedAt, channelCount: playlist.channels.count, error: nil)
                case .failure(let error):
                    guard error != .cancelled else { continue }
                    status[id] = .failed(error)
                    lastError = error
                    library.markRefreshed(id: id, at: nil, channelCount: nil, error: error)
                }
            }
        }
        if let lastError { bannerError = lastError }
        await rebuildSnapshot()
    }

    private func refreshGuide(sources: [SourceDescriptor], force: Bool) async {
        var advertised: [UUID: [URL]] = [:]
        for (id, playlist) in playlists where !playlist.epgURLs.isEmpty {
            advertised[id] = playlist.epgURLs
        }
        await epg.refresh(sources: sources, playlistEPGURLs: advertised, force: force)
    }

    private func rebuildSnapshot() async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let ordered = library.sources.filter(\.isEnabled).compactMap { playlists[$0.id] }
        let built = await Task.detached(priority: .userInitiated) {
            LibrarySnapshot.build(playlists: ordered)
        }.value
        guard generation == rebuildGeneration else { return } // a newer rebuild superseded this one
        snapshot = built
        epg.updateChannels(built.channels)
        NotificationCenter.default.post(name: .lumenChannelsDidChange, object: nil)
    }

    // MARK: - Queries

    func channel(id: ChannelID) -> Channel? { snapshot.channel(id) }

    func channel(rawID: String) -> Channel? { snapshot.channel(rawID: rawID) }

    func search(_ query: String) async -> [Channel] {
        let snapshot = snapshot
        return await Task.detached(priority: .userInitiated) {
            snapshot.searchIndex.search(query).compactMap { snapshot.channel($0) }
        }.value
    }

    #if DEBUG
    /// Injects a playlist without networking (UI tests / previews).
    func injectForTesting(_ playlist: CachedPlaylist) async {
        playlists[playlist.sourceID] = playlist
        status[playlist.sourceID] = .loaded(count: playlist.channels.count)
        let built = await Task.detached { LibrarySnapshot.build(playlists: [playlist]) }.value
        snapshot = built
        hasLoadedCache = true
        epg.updateChannels(built.channels)
    }
    #endif
}
