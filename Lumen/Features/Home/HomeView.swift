import LumenKit
import SwiftUI

enum HomeRoute: Hashable {
    case favorites
    case category(String)
}

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(ChannelRepository.self) private var channels
    @Environment(EPGManager.self) private var epg

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    header

                    if let error = channels.bannerError {
                        ErrorBanner(error: error) { channels.bannerError = nil }
                    }

                    if !library.hasSources && channels.snapshot.isEmpty {
                        onboarding
                    } else if channels.snapshot.isEmpty {
                        loadingOrEmpty
                    } else {
                        continueWatching
                        favorites
                        onNow
                        categories
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .refreshable { await channels.refreshAll(force: true) }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .favorites: FavoritesView()
                case .category(let name): CategoryChannelsView(category: name)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .miniPlayerInset()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("LUMEN")
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(.tint)
            Text(Theme.greeting())
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 8)
    }

    private var onboarding: some View {
        StateMessageView(
            systemImage: "list.bullet.rectangle.portrait",
            title: "Add your first playlist",
            message: "Lumen plays M3U/M3U8 playlists from providers you're authorized to use. It doesn't include any channels.",
            actionTitle: "Add Playlist",
            action: { router.isAddingSource = true }
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private var loadingOrEmpty: some View {
        if channels.isRefreshing || !channels.hasLoadedCache {
            HStack {
                Spacer()
                ProgressView("Loading channels…")
                Spacer()
            }
            .padding(.top, 60)
        } else {
            StateMessageView(
                systemImage: "antenna.radiowaves.left.and.right.slash",
                title: "No channels",
                message: "Your playlists are disabled or couldn't be loaded. Check them in Settings.",
                actionTitle: "Retry",
                action: { Task { await channels.refreshAll(force: true) } }
            )
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var continueWatching: some View {
        let recent = library.history.prefix(15).compactMap { channels.channel(rawID: $0.channelKey) }
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Continue Watching")
                rail(recent)
            }
        }
    }

    @ViewBuilder
    private var favorites: some View {
        let favorites = library.favoriteChannels.compactMap { channels.channel(rawID: $0.key) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Favorites")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !favorites.isEmpty {
                    NavigationLink(value: HomeRoute.favorites) {
                        Text("Edit").font(.subheadline.weight(.medium))
                    }
                    .accessibilityLabel("Edit favorites")
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            if favorites.isEmpty {
                Text("Swipe a channel in Live and tap the star to add it here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.horizontalPadding)
            } else {
                rail(favorites)
            }
        }
    }

    @ViewBuilder
    private var onNow: some View {
        // Guide highlights for favorites, falling back to the first guide channels.
        let favorites = library.favoriteChannels.compactMap { channels.channel(rawID: $0.key) }.filter { epg.hasGuide(for: $0) }
        let candidates = favorites.isEmpty
            ? epg.guideChannelIDs.prefix(8).compactMap { channels.channel(id: $0) }
            : Array(favorites.prefix(8))
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "On Now", actionTitle: "Guide") { router.selectedTab = .guide }
                VStack(spacing: 0) {
                    ForEach(candidates) { channel in
                        OnNowRow(channel: channel, context: candidates)
                        if channel.id != candidates.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .cardStyle()
                .padding(.horizontal, Theme.horizontalPadding)
            }
        }
    }

    @ViewBuilder
    private var categories: some View {
        let list = channels.snapshot.categories
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Categories")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(list.prefix(24)) { category in
                        NavigationLink(value: HomeRoute.category(category.name)) {
                            CategoryTile(category: category, isFavorite: library.isFavoriteCategory(category.name))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                if list.count > 24 {
                    Button("All \(list.count) categories") { router.selectedTab = .live }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, Theme.horizontalPadding)
                }
            }
        }
    }

    private func rail(_ list: [Channel]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(list) { channel in
                    ChannelCard(channel: channel, context: list)
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
        }
    }
}

private struct OnNowRow: View {
    let channel: Channel
    let context: [Channel]
    @Environment(PlayerManager.self) private var player
    @Environment(EPGManager.self) private var epg

    var body: some View {
        Button {
            player.play(channel, context: context)
        } label: {
            HStack(spacing: 12) {
                LogoImage(url: channel.logoURL, name: channel.name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    NowNextView(current: epg.current(for: channel), next: nil)
                }
                Spacer()
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the channel")
    }
}

private struct CategoryTile: View {
    let category: CategorySummary
    let isFavorite: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(category.count) channels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isFavorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite category")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

struct CategoryChannelsView: View {
    let category: String
    @Environment(ChannelRepository.self) private var channels
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let list = channels.snapshot.channels(in: category)
        List(list) { channel in
            ChannelRow(channel: channel, context: list)
        }
        .listStyle(.plain)
        .navigationTitle(category)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    library.toggleFavoriteCategory(category)
                } label: {
                    Image(systemName: library.isFavoriteCategory(category) ? "star.fill" : "star")
                }
                .accessibilityLabel(library.isFavoriteCategory(category) ? "Remove category from Favorites" : "Add category to Favorites")
            }
        }
        .overlay {
            if list.isEmpty {
                StateMessageView(systemImage: "tv", title: "No channels", message: "This category is empty.")
            }
        }
        .miniPlayerInset()
    }
}
