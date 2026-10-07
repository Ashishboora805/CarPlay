import SwiftUI

/// "Web" tab: in-app browser and YouTube (both iPhone-only features).
struct WebHubView: View {
    @Environment(AppRouter.self) private var router
    @Environment(BrowserManager.self) private var browser

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $router.webSegment) {
                    ForEach(WebSegment.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.vertical, 8)

                switch router.webSegment {
                case .browser: BrowserView()
                case .youtube: YouTubeHomeView()
                }
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .miniPlayerInset()
        }
        .onChange(of: router.pendingBrowserURL) { _, url in
            guard let url else { return }
            browser.open(url, inNewTab: true)
            router.pendingBrowserURL = nil
        }
        .onChange(of: router.selectedTab) { _, tab in
            // Leaving the tab: free memory held by background tabs.
            if tab != .web { browser.hibernateBackgroundTabs() }
        }
    }
}
