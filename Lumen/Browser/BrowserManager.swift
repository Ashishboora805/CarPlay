import Foundation
import LumenKit
import Observation

/// Tab management with a cap on live web views: beyond `maxLiveWebViews`, the least recently
/// used tabs are hibernated (web view released, URL kept) to bound memory.
@MainActor
@Observable
final class BrowserManager {
    static let maxLiveWebViews = 3
    static let maxTabs = 12

    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTabID: UUID?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        restoreTabs()
    }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    func open(_ url: URL?, inNewTab: Bool = false) {
        if inNewTab || tabs.isEmpty {
            newTab(url: url ?? settings.homepageURL)
        } else if let url, let tab = selectedTab {
            tab.load(url)
        }
        persistTabs()
    }

    func submit(_ text: String) {
        guard let url = BrowserInput.resolve(text, engine: settings.searchEngine) else { return }
        if let tab = selectedTab {
            tab.load(url)
        } else {
            newTab(url: url)
        }
        persistTabs()
    }

    func goHome() {
        submit(settings.homepageURL.absoluteString)
    }

    @discardableResult
    func newTab(url: URL? = nil) -> BrowserTab {
        if tabs.count >= Self.maxTabs, let oldest = tabs.min(by: { $0.lastAccessed < $1.lastAccessed }) {
            close(oldest.id)
        }
        let tab = BrowserTab(url: url ?? settings.homepageURL)
        tabs.append(tab)
        select(tab.id)
        return tab
    }

    func select(_ id: UUID) {
        selectedTabID = id
        enforceLiveWebViewLimit()
        persistTabs()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].hibernate()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        persistTabs()
    }

    func closeAll() {
        tabs.forEach { $0.hibernate() }
        tabs.removeAll()
        selectedTabID = nil
        persistTabs()
    }

    /// Releases every web view except the visible one (memory warning / leaving the tab).
    func hibernateBackgroundTabs() {
        for tab in tabs where tab.id != selectedTab?.id { tab.hibernate() }
    }

    private func enforceLiveWebViewLimit() {
        let live = tabs.filter { !$0.isHibernated && $0.id != selectedTabID }
            .sorted { $0.lastAccessed > $1.lastAccessed }
        for tab in live.dropFirst(Self.maxLiveWebViews - 1) { tab.hibernate() }
    }

    // MARK: - Persistence (URLs only; private browsing data is never written)

    func persistTabs() {
        let urls = tabs.compactMap { $0.url?.absoluteString }.filter { $0 != "about:blank" }
        defaults.set(urls, forKey: AppSettings.Keys.browserTabs)
    }

    private func restoreTabs() {
        let urls = (defaults.stringArray(forKey: AppSettings.Keys.browserTabs) ?? [])
            .compactMap(URLValidator.httpURL(from:))
            .prefix(Self.maxTabs)
        tabs = urls.map { BrowserTab(url: $0) }
        selectedTabID = tabs.last?.id
    }
}
