import AVFoundation
import XCTest
@testable import Lumen

/// App-level unit tests. Parser/EPG/search/browser-input tests live in the LumenKit package
/// (`swift test` in Packages/LumenKit) so they run without a simulator.
final class AppErrorTests: XCTestCase {
    func testURLErrorMapping() {
        XCTAssertEqual(AppError.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(AppError.from(URLError(.timedOut)), .timeout)
        XCTAssertEqual(AppError.from(URLError(.cannotFindHost)), .dnsFailure)
        XCTAssertEqual(AppError.from(URLError(.dnsLookupFailed)), .dnsFailure)
        XCTAssertEqual(AppError.from(URLError(.cannotConnectToHost)), .cannotConnect)
        XCTAssertEqual(AppError.from(URLError(.serverCertificateUntrusted)), .insecureConnection)
        XCTAssertEqual(AppError.from(URLError(.userAuthenticationRequired)), .authenticationFailed)
        XCTAssertEqual(AppError.from(URLError(.badURL)), .invalidURL)
        XCTAssertEqual(AppError.from(CancellationError()), .cancelled)
    }

    func testPlaybackErrorMapping() {
        let notFound = NSError(domain: "CoreMediaErrorDomain", code: -12938)
        XCTAssertEqual(AppError.fromPlayback(notFound), .streamUnavailable)

        let forbidden = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                                userInfo: [NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12660)])
        XCTAssertEqual(AppError.fromPlayback(forbidden), .authenticationFailed)

        let codec = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.fileFormatNotRecognized.rawValue)
        XCTAssertEqual(AppError.fromPlayback(codec), .unsupportedFormat)

        let timeout = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)])
        XCTAssertEqual(AppError.fromPlayback(timeout), .timeout)

        XCTAssertEqual(AppError.fromPlayback(nil), .streamUnavailable)
    }

    func testRetryability() {
        XCTAssertTrue(AppError.timeout.isRetryable)
        XCTAssertTrue(AppError.streamUnavailable.isRetryable)
        XCTAssertTrue(AppError.http(status: 503).isRetryable)
        XCTAssertFalse(AppError.http(status: 404).isRetryable)
        XCTAssertFalse(AppError.unsupportedFormat.isRetryable)
        XCTAssertFalse(AppError.authenticationFailed.isRetryable)
    }

    func testEveryErrorHasUserFacingText() {
        let all: [AppError] = [.offline, .timeout, .dnsFailure, .cannotConnect, .insecureConnection, .http(status: 500),
                               .authenticationFailed, .invalidURL, .invalidPlaylist, .emptyPlaylist, .epgUnavailable,
                               .streamUnavailable, .unsupportedFormat, .embeddingNotAllowed, .cancelled, .unknown("")]
        for error in all {
            XCTAssertFalse(error.title.isEmpty)
            XCTAssertFalse(error.message.isEmpty)
        }
        XCTAssertEqual(AppError.streamUnavailable.title, "Unable to play this channel")
    }
}

final class HTTPClientTests: XCTestCase {
    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testValidateStatusCodes() throws {
        XCTAssertNoThrow(try HTTPClient.validate(response(200)))
        XCTAssertNoThrow(try HTTPClient.validate(response(304)))
        XCTAssertThrowsError(try HTTPClient.validate(response(401))) { XCTAssertEqual($0 as? AppError, .authenticationFailed) }
        XCTAssertThrowsError(try HTTPClient.validate(response(403))) { XCTAssertEqual($0 as? AppError, .authenticationFailed) }
        XCTAssertThrowsError(try HTTPClient.validate(response(404))) { XCTAssertEqual($0 as? AppError, .http(status: 404)) }
        XCTAssertThrowsError(try HTTPClient.validate(URLResponse())) { XCTAssertEqual($0 as? AppError, .invalidPlaylist) }
    }

    func testBasicAuthorizationHeader() {
        let request = HTTPClient.request(URL(string: "https://example.com/list.m3u")!,
                                         credentials: SourceCredentials(username: "alice", password: "s3cret"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic YWxpY2U6czNjcmV0")
        XCTAssertNil(SourceCredentials(username: "", password: "x").basicAuthorizationHeader)
    }
}

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "app.lumen.tests.\(UUID().uuidString)")

    override func tearDown() {
        store.removeAll()
        super.tearDown()
    }

    /// Unsigned test hosts (e.g. CI with CODE_SIGNING_ALLOWED=NO) have no Keychain access.
    private func skipIfKeychainUnavailable() throws {
        guard store.set("probe", for: "probe") else {
            throw XCTSkip("Keychain unavailable in this (unsigned) test host")
        }
        store.remove("probe")
    }

    func testRoundTripAndOverwrite() throws {
        try skipIfKeychainUnavailable()
        XCTAssertNil(store.string(for: "key"))
        XCTAssertTrue(store.set("first", for: "key"))
        XCTAssertEqual(store.string(for: "key"), "first")
        XCTAssertTrue(store.set("second", for: "key"))
        XCTAssertEqual(store.string(for: "key"), "second")
        store.remove("key")
        XCTAssertNil(store.string(for: "key"))
    }

    func testCodableSecrets() throws {
        try skipIfKeychainUnavailable()
        let secrets = SourceSecrets(playlistURL: URL(string: "https://example.com/get.php?username=a&password=b")!,
                                    epgURL: nil, credentials: SourceCredentials(username: "u", password: "p"))
        XCTAssertTrue(store.set(value: secrets, for: "source"))
        XCTAssertEqual(store.value(SourceSecrets.self, for: "source"), secrets)
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "app.lumen.tests.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsAreDarkFirstAndPersist() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(settings.quality, .automatic)
        XCTAssertEqual(settings.epgRefreshHours, 12)

        settings.appearance = .light
        settings.quality = .dataSaver
        settings.browserHomepage = "example.com"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.appearance, .light)
        XCTAssertEqual(reloaded.quality, .dataSaver)
        XCTAssertEqual(reloaded.homepageURL.absoluteString, "https://example.com")
    }

    func testInvalidHomepageFallsBackToSearchEngine() {
        let settings = AppSettings(defaults: defaults)
        settings.browserHomepage = "not a url"
        XCTAssertEqual(settings.homepageURL, settings.searchEngine.homeURL)
    }
}

@MainActor
final class BrowserManagerTests: XCTestCase {
    private func makeManager() -> BrowserManager {
        let suite = "app.lumen.tests.browser.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return BrowserManager(settings: AppSettings(defaults: defaults), defaults: defaults)
    }

    func testTabLifecycleAndPersistence() {
        let manager = makeManager()
        XCTAssertTrue(manager.tabs.isEmpty)
        let first = manager.newTab(url: URL(string: "https://example.com/a"))
        let second = manager.newTab(url: URL(string: "https://example.com/b"))
        XCTAssertEqual(manager.selectedTab?.id, second.id)

        manager.close(second.id)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTab?.id, first.id)
    }

    func testTabCountIsCapped() {
        let manager = makeManager()
        for index in 0..<(BrowserManager.maxTabs + 3) {
            manager.newTab(url: URL(string: "https://example.com/\(index)"))
        }
        XCTAssertEqual(manager.tabs.count, BrowserManager.maxTabs)
    }

    func testTabsAreHibernatedUntilShown() {
        let manager = makeManager()
        let tab = manager.newTab(url: URL(string: "https://example.com"))
        // No WKWebView (and no web content process) exists until the tab is displayed.
        XCTAssertTrue(tab.isHibernated)
    }
}

final class PlaybackStateTests: XCTestCase {
    func testActiveStates() {
        XCTAssertTrue(PlaybackStatus.playing.isActive)
        XCTAssertTrue(PlaybackStatus.reconnecting(attempt: 2).isActive)
        XCTAssertFalse(PlaybackStatus.idle.isActive)
        XCTAssertFalse(PlaybackStatus.failed(.streamUnavailable).isActive)
        XCTAssertEqual(PlaybackStatus.reconnecting(attempt: 3).accessibilityDescription, "Reconnecting, attempt 3")
    }

    func testYouTubeErrorMapping() {
        XCTAssertEqual(YouTubePlayerEvent.error(code: 150).appError, .embeddingNotAllowed)
        XCTAssertEqual(YouTubePlayerEvent.error(code: 101).appError, .embeddingNotAllowed)
        XCTAssertNil(YouTubePlayerEvent.playing.appError)
    }
}
