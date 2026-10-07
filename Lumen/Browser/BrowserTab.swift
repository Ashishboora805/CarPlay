import Foundation
import LumenKit
import Observation
import UIKit
import WebKit

/// One browser tab. The WKWebView is created lazily and can be discarded ("hibernated") to
/// free memory; the tab then reloads its last URL when shown again.
@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id = UUID()
    private(set) var title: String = "New Tab"
    private(set) var url: URL?
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var hasOnlySecureContent = false
    private(set) var error: AppError?
    @ObservationIgnored private(set) var lastAccessed = Date()

    @ObservationIgnored private var storedWebView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let isPrivate: Bool

    init(url: URL?, isPrivate: Bool = false) {
        self.url = url
        self.isPrivate = isPrivate
        super.init()
    }

    var isSecure: Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && hasOnlySecureContent
    }

    var isHibernated: Bool { storedWebView == nil }

    var displayHost: String {
        guard let url else { return "" }
        if url.absoluteString == "about:blank" { return "" }
        return url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
    }

    /// The tab's web view, created (and its last URL reloaded) on first access.
    var webView: WKWebView {
        lastAccessed = Date()
        if let storedWebView { return storedWebView }
        let webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration(isPrivate: isPrivate))
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isInspectable = false
        storedWebView = webView
        observeWebView(webView)
        if let url { webView.load(URLRequest(url: url)) }
        return webView
    }

    private static func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        // Battery: don't autoplay audible media in arbitrary pages.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = [.phoneNumber, .link]
        return configuration
    }

    private func observeWebView(_ webView: WKWebView) {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                let title = webView.title
                Task { @MainActor [weak self] in
                    if let title, !title.isEmpty { self?.title = title }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let url = webView.url
                Task { @MainActor [weak self] in if let url { self?.url = url } }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                let progress = webView.estimatedProgress
                Task { @MainActor [weak self] in self?.progress = progress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                let loading = webView.isLoading
                Task { @MainActor [weak self] in self?.isLoading = loading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                let value = webView.canGoBack
                Task { @MainActor [weak self] in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                let value = webView.canGoForward
                Task { @MainActor [weak self] in self?.canGoForward = value }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] webView, _ in
                let value = webView.hasOnlySecureContent
                Task { @MainActor [weak self] in self?.hasOnlySecureContent = value }
            }
        ]
    }

    // MARK: - Commands

    func load(_ url: URL) {
        error = nil
        self.url = url
        if let storedWebView {
            storedWebView.load(URLRequest(url: url))
        } else {
            _ = webView // creating the web view loads `url`
        }
    }

    func goBack() { storedWebView?.goBack() }
    func goForward() { storedWebView?.goForward() }

    func reload() {
        error = nil
        if let storedWebView, storedWebView.url != nil {
            storedWebView.reload()
        } else if let url {
            load(url)
        }
    }

    func stopLoading() { storedWebView?.stopLoading() }

    /// Releases the web view (and its content process memory). The URL is kept.
    func hibernate() {
        guard let storedWebView else { return }
        storedWebView.stopLoading()
        storedWebView.navigationDelegate = nil
        storedWebView.uiDelegate = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        storedWebView.removeFromSuperview()
        self.storedWebView = nil
        progress = 0
        isLoading = false
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let decision = BrowserNavigationPolicy.decide(
            url: navigationAction.request.url,
            isUserInitiated: navigationAction.navigationType == .linkActivated
        )
        switch decision {
        case .allow:
            return .allow
        case .openExternally:
            if let url = navigationAction.request.url {
                _ = await UIApplication.shared.open(url)
            }
            return .cancel
        case .block:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The content process was killed (usually memory pressure). Recover by reloading.
        webView.reload()
    }

    private func handle(_ error: Error) {
        let nsError = error as NSError
        // Cancelled navigations (user tapped another link) and frame-load interruptions are not errors.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        self.error = AppError.from(error)
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// `target="_blank"` links open in the same tab instead of spawning hidden web views.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           BrowserNavigationPolicy.decide(url: url, isUserInitiated: true) == .allow {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
