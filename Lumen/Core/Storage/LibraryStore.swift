import Foundation
import LumenKit
import Observation
import SwiftData
import SwiftUI // Array.move(fromOffsets:toOffset:)

/// Main-actor façade over SwiftData for sources, favorites and watch history.
/// Used by both the iPhone UI and the CarPlay scene so there is a single source of truth.
@MainActor
@Observable
final class LibraryStore {
    static let historyLimit = 50

    private(set) var sources: [SourceEntity] = []
    private(set) var favoriteChannels: [FavoriteEntity] = []
    private(set) var favoriteCategories: [FavoriteEntity] = []
    private(set) var history: [HistoryEntity] = []

    @ObservationIgnored private var favoriteChannelKeys: Set<String> = []
    @ObservationIgnored private var favoriteCategoryKeys: Set<String> = []
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let keychain: KeychainStore

    init(container: ModelContainer, keychain: KeychainStore) {
        self.context = container.mainContext
        self.keychain = keychain
        reloadAll()
    }

    // MARK: - Loading

    func reloadAll() {
        sources = (try? context.fetch(FetchDescriptor<SourceEntity>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        ))) ?? []
        reloadFavorites()
        reloadHistory()
    }

    private func reloadFavorites() {
        let all = (try? context.fetch(FetchDescriptor<FavoriteEntity>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        ))) ?? []
        favoriteChannels = all.filter { $0.kind == .channel }
        favoriteCategories = all.filter { $0.kind == .category }
        favoriteChannelKeys = Set(favoriteChannels.map(\.key))
        favoriteCategoryKeys = Set(favoriteCategories.map(\.key))
    }

    private func reloadHistory() {
        var descriptor = FetchDescriptor<HistoryEntity>(sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)])
        descriptor.fetchLimit = Self.historyLimit
        history = (try? context.fetch(descriptor)) ?? []
    }

    private func commit(reloadSources: Bool = false, favorites: Bool = false, history reload: Bool = false) {
        do {
            try context.save()
        } catch {
            context.rollback()
        }
        if reloadSources {
            sources = (try? context.fetch(FetchDescriptor<SourceEntity>(
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
            ))) ?? []
        }
        if favorites { reloadFavorites() }
        if reload { reloadHistory() }
        NotificationCenter.default.post(name: .lumenLibraryDidChange, object: nil)
    }

    // MARK: - Sources

    var hasSources: Bool { !sources.isEmpty }

    func secrets(for id: UUID) -> SourceSecrets? {
        keychain.value(SourceSecrets.self, for: KeychainStore.Keys.source(id))
    }

    func descriptors(enabledOnly: Bool = true) -> [SourceDescriptor] {
        sources.compactMap { entity in
            guard !enabledOnly || entity.isEnabled, let secrets = secrets(for: entity.id) else { return nil }
            return SourceDescriptor(
                id: entity.id,
                name: entity.name,
                playlistURL: secrets.playlistURL,
                epgURL: secrets.epgURL,
                credentials: secrets.credentials,
                refreshInterval: TimeInterval(max(1, entity.refreshIntervalHours)) * 3600,
                isEnabled: entity.isEnabled,
                lastRefreshedAt: entity.lastRefreshedAt
            )
        }
    }

    func source(id: UUID) -> SourceEntity? {
        sources.first { $0.id == id }
    }

    /// Creates or updates a source. Returns its id.
    @discardableResult
    func saveSource(id: UUID?, name: String, secrets: SourceSecrets, refreshIntervalHours: Int, isEnabled: Bool) -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? (secrets.playlistURL.host ?? "Playlist") : trimmedName
        let entity: SourceEntity
        if let id, let existing = source(id: id) {
            entity = existing
            let previous = self.secrets(for: id)
            if previous?.playlistURL != secrets.playlistURL || previous?.credentials != secrets.credentials {
                entity.lastRefreshedAt = nil // force a refresh with the new URL
            }
            entity.name = displayName
            entity.refreshIntervalHours = refreshIntervalHours
            entity.isEnabled = isEnabled
        } else {
            entity = SourceEntity(name: displayName, displayHost: "", refreshIntervalHours: refreshIntervalHours,
                                  isEnabled: isEnabled, sortOrder: (sources.map(\.sortOrder).max() ?? -1) + 1)
            context.insert(entity)
        }
        entity.displayHost = secrets.playlistURL.host ?? ""
        entity.usesInsecureConnection = !URLValidator.isSecure(secrets.playlistURL)
        entity.hasCustomEPG = secrets.epgURL != nil
        keychain.set(value: secrets, for: KeychainStore.Keys.source(entity.id))
        commit(reloadSources: true)
        return entity.id
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let entity = source(id: id), entity.isEnabled != enabled else { return }
        entity.isEnabled = enabled
        commit(reloadSources: true)
    }

    func deleteSource(id: UUID) {
        guard let entity = source(id: id) else { return }
        context.delete(entity)
        keychain.remove(KeychainStore.Keys.source(id))
        commit(reloadSources: true)
    }

    func moveSources(from offsets: IndexSet, to destination: Int) {
        var reordered = sources
        reordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, entity) in reordered.enumerated() { entity.sortOrder = index }
        commit(reloadSources: true)
    }

    func markRefreshed(id: UUID, at date: Date?, channelCount: Int?, error: AppError?) {
        guard let entity = source(id: id) else { return }
        if let date { entity.lastRefreshedAt = date }
        if let channelCount { entity.channelCount = channelCount }
        entity.lastErrorMessage = error.map { "\($0.title). \($0.message)" }
        commit(reloadSources: true)
    }

    // MARK: - Favorites

    func isFavorite(_ channelID: ChannelID) -> Bool {
        favoriteChannelKeys.contains(channelID.rawValue)
    }

    func isFavoriteCategory(_ name: String) -> Bool {
        favoriteCategoryKeys.contains(name)
    }

    func toggleFavorite(_ channel: Channel) {
        if let existing = favoriteChannels.first(where: { $0.key == channel.id.rawValue }) {
            context.delete(existing)
        } else {
            let order = (favoriteChannels.map(\.sortOrder).max() ?? -1) + 1
            context.insert(FavoriteEntity(kind: .channel, key: channel.id.rawValue, title: channel.name,
                                          subtitle: channel.group, logoURLString: channel.logoURL?.absoluteString,
                                          sortOrder: order))
        }
        commit(favorites: true)
    }

    func toggleFavoriteCategory(_ name: String) {
        if let existing = favoriteCategories.first(where: { $0.key == name }) {
            context.delete(existing)
        } else {
            let order = (favoriteCategories.map(\.sortOrder).max() ?? -1) + 1
            context.insert(FavoriteEntity(kind: .category, key: name, title: name, subtitle: nil,
                                          logoURLString: nil, sortOrder: order))
        }
        commit(favorites: true)
    }

    func moveFavorites(_ kind: FavoriteKind, from offsets: IndexSet, to destination: Int) {
        var list = kind == .channel ? favoriteChannels : favoriteCategories
        list.move(fromOffsets: offsets, toOffset: destination)
        for (index, entity) in list.enumerated() { entity.sortOrder = index }
        commit(favorites: true)
    }

    func removeFavorites(_ kind: FavoriteKind, at offsets: IndexSet) {
        let list = kind == .channel ? favoriteChannels : favoriteCategories
        for index in offsets where list.indices.contains(index) {
            context.delete(list[index])
        }
        commit(favorites: true)
    }

    // MARK: - History

    func recordWatch(_ channel: Channel) {
        if let existing = history.first(where: { $0.channelKey == channel.id.rawValue }) {
            existing.lastWatchedAt = .now
            existing.title = channel.name
            existing.logoURLString = channel.logoURL?.absoluteString
        } else {
            context.insert(HistoryEntity(channelKey: channel.id.rawValue, title: channel.name,
                                         groupName: channel.group, logoURLString: channel.logoURL?.absoluteString,
                                         sourceID: channel.sourceID))
            if history.count >= Self.historyLimit {
                for stale in history.suffix(from: Self.historyLimit - 1) { context.delete(stale) }
            }
        }
        commit(history: true)
    }

    func clearHistory() {
        try? context.delete(model: HistoryEntity.self)
        commit(history: true)
    }
}
