import LumenKit
import SwiftUI

struct LiveTVView: View {
    @Environment(AppRouter.self) private var router
    @Environment(ChannelRepository.self) private var channels
    @Environment(LibraryStore.self) private var library

    @State private var query = ""
    @State private var results: [Channel]?
    @State private var isSearching = false

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            VStack(spacing: 0) {
                if query.isEmpty {
                    FilterChips(selection: $router.liveFilter,
                                categories: orderedCategories)
                }
                content
            }
            .background(Theme.background)
            .navigationTitle("Live TV")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Channels, categories, countries")
            .task(id: query) { await runSearch() }
            .refreshable { await channels.refreshAll(force: true) }
            .toolbar {
                if router.liveFilter == .favorites {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("Edit") { FavoritesView() }
                    }
                }
            }
            .miniPlayerInset()
        }
    }

    @ViewBuilder
    private var content: some View {
        let list = results ?? filteredChannels
        if !library.hasSources && channels.snapshot.isEmpty {
            StateMessageView(systemImage: "list.bullet.rectangle.portrait", title: "No playlists",
                             message: "Add an M3U playlist to start watching.", actionTitle: "Add Playlist") {
                router.isAddingSource = true
            }
            .frame(maxHeight: .infinity)
        } else if list.isEmpty {
            emptyState.frame(maxHeight: .infinity)
        } else {
            List(list) { channel in
                ChannelRow(channel: channel, context: list)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            if isSearching {
                ProgressView()
            } else {
                StateMessageView(systemImage: "magnifyingglass", title: "No results",
                                 message: "No channels match “\(query)”.")
            }
        } else if router.liveFilter == .favorites {
            StateMessageView(systemImage: "star", title: "No favorites yet",
                             message: "Swipe left on a channel and tap Favorite.")
        } else if !channels.hasLoadedCache || channels.isRefreshing {
            ProgressView("Loading channels…")
        } else {
            StateMessageView(systemImage: "tv", title: "No channels",
                             message: "Your playlists have no channels, or couldn't be loaded.",
                             actionTitle: "Retry") {
                Task { await channels.refreshAll(force: true) }
            }
        }
    }

    private var orderedCategories: [String] {
        let favorites = library.favoriteCategories.map(\.key)
        let all = channels.snapshot.categories.map(\.name)
        return favorites.filter { all.contains($0) } + all.filter { !favorites.contains($0) }
    }

    private var filteredChannels: [Channel] {
        switch router.liveFilter {
        case .all:
            return channels.snapshot.channels
        case .favorites:
            return library.favoriteChannels.compactMap { channels.channel(rawID: $0.key) }
        case .category(let name):
            return channels.snapshot.channels(in: name)
        }
    }

    /// Debounced (250 ms) search that runs off the main thread; cancelled on each keystroke.
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = nil
            isSearching = false
            return
        }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return // cancelled by a newer keystroke
        }
        let found = await channels.search(trimmed)
        guard !Task.isCancelled else { return }
        results = found
        isSearching = false
    }
}

/// Horizontal filter chips: All, Favorites, then categories.
struct FilterChips: View {
    @Binding var selection: LiveFilter
    let categories: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    chip(.all)
                    chip(.favorites)
                    ForEach(categories, id: \.self) { name in
                        chip(.category(name))
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.vertical, 8)
            }
            .frame(height: 52)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, value in proxy.scrollTo(value, anchor: .center) }
        }
    }

    private func chip(_ filter: LiveFilter) -> some View {
        let isSelected = selection == filter
        return Button {
            selection = filter
        } label: {
            HStack(spacing: 4) {
                if filter == .favorites { Image(systemName: "star.fill").font(.caption2) }
                Text(filter.title).lineLimit(1)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.surface), in: Capsule())
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: isSelected ? 0 : 0.5))
        }
        .buttonStyle(.plain)
        .id(filter)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
