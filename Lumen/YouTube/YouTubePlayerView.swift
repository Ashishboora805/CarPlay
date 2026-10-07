import LumenKit
import SwiftUI
import UIKit
import WebKit

enum YouTubePlayerEvent: Equatable {
    case ready
    case playing
    case paused
    case ended
    case buffering
    case error(code: Int)

    /// Maps IFrame API error codes to user-facing errors.
    var appError: AppError? {
        guard case .error(let code) = self else { return nil }
        switch code {
        case 101, 150, 152, 153: return .embeddingNotAllowed
        case 100: return .unknown("This video is unavailable or private.")
        case -1: return .offline
        case 2: return .invalidURL
        default: return .unknown("YouTube couldn't play this video (error \(code)).")
        }
    }
}

/// Hosts YouTube's official IFrame Player API in a WKWebView. This is YouTube's supported way
/// to play videos inside third-party apps; ads, branding and controls are YouTube's own.
struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String
    var onEvent: (YouTubePlayerEvent) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: Coordinator.messageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(videoID: videoID, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        if context.coordinator.loadedVideoID != videoID {
            context.coordinator.load(videoID: videoID, in: webView)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// The embed's origin. YouTube requires embeds to identify the embedding client through the
    /// page origin/referrer. This mirrors Google's youtube-ios-player-helper, which uses
    /// `http://<bundle identifier>` as both the WKWebView base URL and the `origin` player var.
    /// (Missing or mismatched origins are the usual cause of embed error 153.)
    static var embedOrigin: URL {
        let bundleID = (Bundle.main.bundleIdentifier ?? "app.lumen").lowercased()
        return URL(string: "http://\(bundleID)") ?? URL(string: "http://app.lumen")!
    }

    static func html(videoID: String, origin: String) -> String {
        // `videoID` is validated against the 11-character [A-Za-z0-9_-] alphabet before use,
        // so it cannot break out of the JavaScript string literal.
        """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#player{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body>
        <div id="player"></div>
        <script>
        function post(name, data) { window.webkit.messageHandlers.\(Coordinator.messageName).postMessage({event: name, data: data}); }
        var tag = document.createElement('script');
        tag.src = 'https://www.youtube.com/iframe_api';
        tag.onerror = function() { post('error', -1); }; // offline / blocked: don't spin forever
        document.head.appendChild(tag);
        var player;
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            videoId: '\(videoID)',
            playerVars: { playsinline: 1, autoplay: 1, rel: 0, origin: '\(origin)', widget_referrer: '\(origin)' },
            events: {
              onReady: function(e) { post('ready', 0); e.target.playVideo(); },
              onStateChange: function(e) { post('state', e.data); },
              onError: function(e) { post('error', e.data); }
            }
          });
        }
        </script>
        </body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        nonisolated static let messageName = "lumenYouTube"
        var onEvent: (YouTubePlayerEvent) -> Void
        private(set) var loadedVideoID: String?

        init(onEvent: @escaping (YouTubePlayerEvent) -> Void) {
            self.onEvent = onEvent
        }

        func load(videoID: String, in webView: WKWebView) {
            guard YouTubeLinkParser.isValidID(videoID) else {
                onEvent(.error(code: 2))
                return
            }
            loadedVideoID = videoID
            let origin = YouTubePlayerView.embedOrigin
            webView.loadHTMLString(YouTubePlayerView.html(videoID: videoID, origin: origin.absoluteString), baseURL: origin)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let name = body["event"] as? String else { return }
            let value = (body["data"] as? NSNumber)?.intValue ?? 0
            switch name {
            case "ready": onEvent(.ready)
            case "state":
                switch value {
                case 0: onEvent(.ended)
                case 1: onEvent(.playing)
                case 2: onEvent(.paused)
                case 3: onEvent(.buffering)
                default: break
                }
            case "error": onEvent(.error(code: value))
            default: break
            }
        }

        /// The player page may only load YouTube itself; tapping the YouTube logo or title opens
        /// the official app/site instead of navigating the embed away.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if !isMainFrame { return .allow } // the YouTube iframe and its resources
            if url.host?.lowercased() == YouTubePlayerView.embedOrigin.host || url.scheme == "about" {
                return .allow // our own page (the base URL) and about:blank
            }
            // Same allow-list as Google's youtube-ios-player-helper: the embed, ads, consent and
            // sign-in frames may navigate; anything else (logo, title, "Watch on YouTube") opens externally.
            if let host = url.host?.lowercased(),
               (host.hasSuffix("youtube.com") && url.path.hasPrefix("/embed/"))
                || host == "accounts.google.com" || host == "content.googleapis.com"
                || host.hasSuffix("googlesyndication.com") || host.hasSuffix("doubleclick.net") {
                return .allow
            }
            if navigationAction.navigationType == .linkActivated {
                _ = await UIApplication.shared.open(url)
            }
            return .cancel
        }
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
