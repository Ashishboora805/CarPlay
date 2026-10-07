import LumenKit
import SwiftUI

/// Manage favorites: reorder (drag) and remove channels and categories.
struct FavoritesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ChannelRepository.self) private var channels
    @Environment(PlayerManager.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            Section("Channels") {
                if library.favoriteChannels.isEmpty {
                    Text("No favorite channels").foregroundStyle(.secondary)
                }
                ForEach(library.favoriteChannels) { favorite in
                    let channel = channels.channel(rawID: favorite.key)
                    Button {
                        if let channel { player.play(channel, context: favoriteChannelList) }
                    } label: {
                        HStack(spacing: 12) {
                            LogoImage(url: favorite.logoURLString.flatMap(URL.init(string:)), name: favorite.title, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(favorite.title).lineLimit(1)
                                Text(channel == nil ? "Unavailable – source offline or removed" : (favorite.subtitle ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(channel == nil)
                }
                .onMove { library.moveFavorites(.channel, from: $0, to: $1) }
                .onDelete { library.removeFavorites(.channel, at: $0) }
            }

            Section("Categories") {
                if library.favoriteCategories.isEmpty {
                    Text("Long-press a channel to favorite its category.").foregroundStyle(.secondary)
                }
                ForEach(library.favoriteCategories) { favorite in
                    Button {
                        router.showCategory(favorite.key)
                    } label: {
                        Label(favorite.title, systemImage: "folder")
                    }
                }
                .onMove { library.moveFavorites(.category, from: $0, to: $1) }
                .onDelete { library.removeFavorites(.category, at: $0) }
            }
        }
        .navigationTitle("Favorites")
        .toolbar { EditButton() }
        .miniPlayerInset()
    }

    private var favoriteChannelList: [Channel] {
        library.favoriteChannels.compactMap { channels.channel(rawID: $0.key) }
    }
}
