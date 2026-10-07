import CarPlay
import LumenKit
import UIKit

/// Builds the CarPlay template hierarchy:
///
///     CPTabBarTemplate
///      ├─ Favorites   (CPListTemplate)          → tap plays audio → CPNowPlayingTemplate
///      ├─ Recent      (CPListTemplate, optional)
///      └─ Browse      (CPListTemplate of categories → CPListTemplate of channels)
///
/// Driver-distraction rules: list lengths respect the system limits, there is no text entry,
/// no configuration, no video, no browser and no YouTube. YouTube entries in playlists are
/// filtered out because they can only be played through YouTube's video embed on iPhone.
@MainActor
final class CarPlayCoordinator: NSObject {
    private let interfaceController: CPInterfaceController
    private let channels: ChannelRepository
    private let library: LibraryStore
    private let player: PlayerManager
    private let epg: EPGManager
    private let settings: AppSettings
    private let images: ImagePipeline

    private let favoritesTemplate: CPListTemplate
    private let recentsTemplate: CPListTemplate
    private let browseTemplate: CPListTemplate
    private var sessionConfiguration: CPSessionConfiguration?
    private var limitedLists = false
    private var observers: [NSObjectProtocol] = []
    private var reloadTask: Task<Void, Never>?
    private var imageTasks: [Task<Void, Never>] = []
    /// The category list currently pushed over Browse, so its rows can be refreshed too.
    private weak var pushedCategoryTemplate: CPListTemplate?
    private var pushedCategoryName: String?

    init(interfaceController: CPInterfaceController, channels: ChannelRepository, library: LibraryStore,
         player: PlayerManager, epg: EPGManager, settings: AppSettings, images: ImagePipeline) {
        self.interfaceController = interfaceController
        self.channels = channels
        self.library = library
        self.player = player
        self.epg = epg
        self.settings = settings
        self.images = images

        favoritesTemplate = CPListTemplate(title: "Favorites", sections: [])
        favoritesTemplate.tabTitle = "Favorites"
        favoritesTemplate.tabImage = UIImage(systemName: "star.fill")
        favoritesTemplate.emptyViewTitleVariants = ["No Favorites"]
        favoritesTemplate.emptyViewSubtitleVariants = ["Add favorites on your iPhone."]

        recentsTemplate = CPListTemplate(title: "Recent", sections: [])
        recentsTemplate.tabTitle = "Recent"
        recentsTemplate.tabImage = UIImage(systemName: "clock.fill")
        recentsTemplate.emptyViewTitleVariants = ["Nothing Played Yet"]
        recentsTemplate.emptyViewSubtitleVariants = ["Channels you play appear here."]

        browseTemplate = CPListTemplate(title: "Browse", sections: [])
        browseTemplate.tabTitle = "Browse"
        browseTemplate.tabImage = UIImage(systemName: "square.grid.2x2.fill")
        browseTemplate.emptyViewTitleVariants = ["No Playlists"]
        browseTemplate.emptyViewSubtitleVariants = ["Add a playlist on your iPhone."]

        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        limitedLists = sessionConfiguration?.limitedUserInterfaces.contains(.lists) ?? false

        var tabs: [CPTemplate] = [favoritesTemplate]
        if settings.carPlayShowsRecents { tabs.append(recentsTemplate) }
        if settings.carPlayShowsCategories { tabs.append(browseTemplate) }
        let tabBar = CPTabBarTemplate(templates: tabs)
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        let center = NotificationCenter.default
        for name in [Notification.Name.lumenLibraryDidChange, .lumenChannelsDidChange, .lumenNowPlayingDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            })
        }
        observers.append(center.addObserver(forName: .lumenPlaybackFailed, object: nil, queue: .main) { [weak self] note in
            let error = note.object as? AppError
            MainActor.assumeIsolated { self?.presentPlaybackError(error) }
        })
        reload()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        reloadTask?.cancel()
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
    }

    /// Coalesces bursts of change notifications into one rebuild.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    // MARK: - Building templates

    /// Maximum rows per list, honoring CarPlay's limits (stricter while driving on some vehicles).
    private var itemLimit: Int {
        let systemLimit = Int(CPListTemplate.maximumItemCount)
        return limitedLists ? min(systemLimit, 12) : min(systemLimit, 100)
    }

    private func reload() {
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()

        let snapshot = channels.snapshot
        let favorites = library.favoriteChannels
            .compactMap { snapshot.channel(rawID: $0.key) }
            .filter { !$0.isYouTube }
        favoritesTemplate.updateSections([CPListSection(items: items(for: favorites, context: favorites))])

        let recents = library.history
            .compactMap { snapshot.channel(rawID: $0.channelKey) }
            .filter { !$0.isYouTube }
        recentsTemplate.updateSections([CPListSection(items: items(for: recents, context: recents))])

        browseTemplate.updateSections([CPListSection(items: categoryItems(snapshot: snapshot))])

        if let template = pushedCategoryTemplate, let name = pushedCategoryName {
            let list = snapshot.channels(in: name).filter { !$0.isYouTube }
            template.updateSections([CPListSection(items: items(for: list, context: list))])
        }
    }

    private func items(for list: [Channel], context: [Channel]) -> [CPListItem] {
        let limited = Array(list.prefix(itemLimit))
        let limitedContext = Array(context.prefix(itemLimit))
        return limited.map { channel in
            let detail = epg.current(for: channel)?.title ?? channel.group
            let item = CPListItem(text: channel.name, detailText: detail,
                                  image: UIImage(systemName: "tv"))
            item.isPlaying = player.currentChannel?.id == channel.id && player.status == .playing
            item.playingIndicatorLocation = .trailing
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    self?.play(channel, context: limitedContext)
                }
                completion()
            }
            loadLogo(for: item, url: channel.logoURL)
            return item
        }
    }

    private func categoryItems(snapshot: LibrarySnapshot) -> [CPListItem] {
        // Favorite categories first, then the rest in playlist order.
        let favoriteNames = library.favoriteCategories.map(\.key)
        let all = snapshot.categories
        let ordered = favoriteNames.compactMap { name in all.first { $0.name == name } }
            + all.filter { !favoriteNames.contains($0.name) }

        return ordered.prefix(itemLimit).map { category in
            let item = CPListItem(text: category.name, detailText: "\(category.count) channels",
                                  image: UIImage(systemName: library.isFavoriteCategory(category.name) ? "star.fill" : "folder.fill"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    self?.showCategory(category.name)
                }
                completion()
            }
            return item
        }
    }

    private func showCategory(_ name: String) {
        let channels = channels.snapshot.channels(in: name).filter { !$0.isYouTube }
        let template = CPListTemplate(title: name, sections: [CPListSection(items: items(for: channels, context: channels))])
        template.emptyViewTitleVariants = ["No Channels"]
        pushedCategoryTemplate = template
        pushedCategoryName = name
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func loadLogo(for item: CPListItem, url: URL?) {
        guard let url else { return }
        let scale = interfaceController.carTraitCollection.displayScale
        let pixels = CPListItem.maximumImageSize.width * max(scale, 1)
        if let cached = images.cachedImage(for: url, maxPixelSize: pixels) {
            item.setImage(cached)
            return
        }
        let images = images
        imageTasks.append(Task { [weak item] in
            guard let image = await images.image(for: url, maxPixelSize: pixels), !Task.isCancelled else { return }
            item?.setImage(image)
        })
    }

    // MARK: - Playback

    private func play(_ channel: Channel, context: [Channel]) {
        player.play(channel, context: context, origin: .carPlay)
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = false
        nowPlaying.isAlbumArtistButtonEnabled = false
        if interfaceController.topTemplate !== nowPlaying {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    private func presentPlaybackError(_ error: AppError?) {
        guard player.origin == .carPlay, interfaceController.presentedTemplate == nil else { return }
        let error = error ?? .streamUnavailable
        let alert = CPAlertTemplate(titleVariants: [error.title, "Can't Play"], actions: [
            CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                }
            }
        ])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}

extension CarPlayCoordinator: CPSessionConfigurationDelegate {
    nonisolated func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                                          limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        let limited = limitedUserInterfaces.contains(.lists)
        MainActor.assumeIsolated {
            guard limitedLists != limited else { return }
            limitedLists = limited
            reload()
        }
    }
}
