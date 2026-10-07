import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerManager.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(ChannelRepository.self) private var channels
    @State private var didAttemptAutoPlay = false

    var body: some View {
        @Bindable var router = router
        @Bindable var player = player

        TabView(selection: $router.selectedTab) {
            HomeView()
                // Presented from here rather than the TabView so it never shares a presenter
                // with the IPTV player's cover below.
                .fullScreenCover(item: $router.youtubeRequest) { request in
                    YouTubePlayerScreen(request: request)
                        .tint(settings.accent.color)
                        .preferredColorScheme(.dark)
                }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)
            LiveTVView()
                .tabItem { Label("Live", systemImage: "tv.fill") }
                .tag(AppTab.live)
            GuideView()
                .tabItem { Label("Guide", systemImage: "calendar") }
                .tag(AppTab.guide)
            WebHubView()
                .tabItem { Label("Web", systemImage: "globe") }
                .tag(AppTab.web)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(settings.accent.color)
        .preferredColorScheme(settings.appearance.colorScheme)
        .fullScreenCover(isPresented: $player.isPlayerPresented) {
            PlayerScreen()
                .tint(settings.accent.color)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $router.isAddingSource) {
            NavigationStack { SourceEditorView(sourceID: nil) }
        }
        .onChange(of: channels.hasLoadedCache, initial: true) { _, loaded in
            autoPlayIfNeeded(loaded: loaded)
        }
    }

    private func autoPlayIfNeeded(loaded: Bool) {
        guard loaded, !didAttemptAutoPlay, settings.autoPlayLastChannel, player.currentChannel == nil else { return }
        didAttemptAutoPlay = true
        if let last = library.history.first, let channel = channels.channel(rawID: last.channelKey), !channel.isYouTube {
            player.play(channel, context: [])
        }
    }
}
