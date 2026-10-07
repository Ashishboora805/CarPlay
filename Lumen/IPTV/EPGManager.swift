import Foundation
import LumenKit
import Observation

/// Main-actor read model for the TV guide. Loading and channel→guide matching run in the
/// background; views only do O(log n) lookups.
@MainActor
@Observable
final class EPGManager {
    private(set) var index = EPGIndex()
    private(set) var isLoading = false
    private(set) var lastError: AppError?
    private(set) var lastUpdated: Date?
    /// Channels (in library order) that have guide data.
    private(set) var guideChannelIDs: [ChannelID] = []

    @ObservationIgnored private var keyByChannel: [ChannelID: String] = [:]
    @ObservationIgnored private var channels: [Channel] = []
    @ObservationIgnored private let loader: EPGLoader
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var mappingTask: Task<Void, Never>?

    init(loader: EPGLoader, settings: AppSettings) {
        self.loader = loader
        self.settings = settings
    }

    // MARK: - Loading

    func refresh(sources: [SourceDescriptor], playlistEPGURLs: [UUID: [URL]], force: Bool) async {
        var seen = Set<URL>()
        var targets: [EPGTarget] = []
        for source in sources {
            if let url = source.epgURL {
                if seen.insert(url).inserted { targets.append(EPGTarget(url: url, credentials: source.credentials)) }
            } else if let url = playlistEPGURLs[source.id]?.first {
                // Header-advertised guides usually live on the same panel and accept the same credentials.
                if seen.insert(url).inserted { targets.append(EPGTarget(url: url, credentials: source.credentials)) }
            }
        }

        guard !targets.isEmpty else {
            index = EPGIndex()
            lastError = nil
            remap()
            return
        }

        loadTask?.cancel()
        isLoading = true
        let maxAge = TimeInterval(settings.epgRefreshHours) * 3600
        let loader = loader
        let task = Task {
            let (newIndex, error) = await loader.loadAll(targets, maxAge: maxAge, force: force)
            guard !Task.isCancelled else { return }
            self.index = newIndex
            self.lastError = newIndex.isEmpty ? (error ?? .epgUnavailable) : error
            self.lastUpdated = .now
            self.isLoading = false
            self.remap()
        }
        loadTask = task
        await task.value
    }

    func clearCache() async {
        await loader.clearAll()
        index = EPGIndex()
        remap()
    }

    /// Called whenever the channel snapshot changes.
    func updateChannels(_ channels: [Channel]) {
        self.channels = channels
        remap()
    }

    private func remap() {
        mappingTask?.cancel()
        let index = index
        let channels = channels
        mappingTask = Task {
            let result = await Task.detached(priority: .utility) { () -> ([ChannelID: String], [ChannelID]) in
                guard !index.isEmpty else { return ([:], []) }
                var map: [ChannelID: String] = [:]
                var ids: [ChannelID] = []
                for channel in channels {
                    if let key = index.key(for: channel) {
                        map[channel.id] = key
                        ids.append(channel.id)
                    }
                }
                return (map, ids)
            }.value
            guard !Task.isCancelled else { return }
            self.keyByChannel = result.0
            self.guideChannelIDs = result.1
        }
    }

    // MARK: - Lookups

    func hasGuide(for channel: Channel) -> Bool {
        keyByChannel[channel.id] != nil
    }

    func current(for channel: Channel, at date: Date = .now) -> EPGProgram? {
        guard let key = keyByChannel[channel.id] else { return nil }
        return index.current(for: key, at: date)
    }

    func next(for channel: Channel, after date: Date = .now) -> EPGProgram? {
        guard let key = keyByChannel[channel.id] else { return nil }
        return index.next(for: key, after: date)
    }

    func schedule(for channel: Channel, from start: Date, to end: Date) -> [EPGProgram] {
        guard let key = keyByChannel[channel.id] else { return [] }
        return index.schedule(for: key, from: start, to: end)
    }
}
