# Lumen: IPTV & Media Player for iOS with CarPlay

Lumen is a lightweight, native iOS player for IPTV playlists you are authorized to use (M3U/M3U8 + HLS) with an XMLTV guide, favorites, history, Picture-in-Picture, AirPlay, an in-app browser, and YouTube playback through YouTube's official embed. It also has a **CarPlay Audio** interface. The feature set is inspired by APTV, but the design and implementation are original.

> **Status:** the code is complete, but it was written on a machine without Xcode and **has not been compiled yet**. Expect a first round of compiler fixes on a Mac. Report the errors and they'll be fixed.

---






Here are the commands to run the app. All of them are for your Mac (Terminal), with the project folder copied or pulled there first.

1. Run the fast tests (no simulator needed)
cd /path/to/CarPlay
swift test --package-path Packages/LumenKit

2. Open in Xcode and run on the simulator (easiest)
open Lumen.xcodeproj
Then in Xcode: choose the Lumen scheme, pick an iPhone simulator at the top, and press Cmd+R to run, Cmd+U for the tests.

3. Build and run from the command line (no Xcode UI)
# See which simulators you have
xcrun simctl list devices available | grep iPhone

# Build for the simulator (change the name to one from the list above)
xcodebuild build -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build

# Boot the simulator, install and launch the app
xcrun simctl boot "iPhone 16"
open -a Simulator
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Lumen.app
xcrun simctl launch booted com.example.lumen

4. Run all app tests from the command line
xcodebuild test -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=iOS Simulator,name=iPhone 16'

5. CarPlay
With the app running in the simulator: menu I/O → External Displays → CarPlay. A CarPlay window opens; tap the Lumen icon there.

6. Run on a real iPhone
1. Open Lumen.xcodeproj, select the Lumen target → Signing & Capabilities, set your Team, and change the bundle ID from com.example.lumen to your own.
2. Remove the com.apple.developer.carplay-audio line from Lumen/Support/Lumen.entitlements until Apple grants you that entitlement, or the device build won't sign.
3. Plug in the iPhone, select it at the top of Xcode, press Cmd+R.

If any command fails, paste the full error text here and I'll fix it. The first build will probably produce a few compiler errors, since the code has never been compiled.












## Requirements

| | |
|---|---|
| Xcode | **16.0 or newer** (the project uses Xcode 16 synchronized folders, `objectVersion 77`) |
| iOS | 17.0+ (SwiftData, Observation) |
| Dependencies | **None.** Apple frameworks only |

## Build & run

```bash
# 1. Package tests (parser, EPG, search, URL handling). Fast, no simulator needed.
swift test --package-path Packages/LumenKit

# 2. Open the app
open Lumen.xcodeproj
#    Select the "Lumen" scheme and an iPhone simulator, then Run.

# 3. App unit + UI tests from the command line
xcodebuild test -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

For a device build, set your **Team** under Signing & Capabilities and change `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.example.lumen`). Device builds won't sign until your App ID has the CarPlay entitlement (see below). Until then, you can temporarily remove the `com.apple.developer.carplay-audio` key from `Lumen/Support/Lumen.entitlements`.

If the project file won't open, regenerate it with XcodeGen:

```bash
brew install xcodegen && xcodegen generate
```

CI: `.github/workflows/ios.yml` runs both test suites on a macOS runner.

---

## Architecture

```
Lumen.xcodeproj
Packages/LumenKit/          Pure Swift logic, no UI, unit tested with `swift test`
  M3U/        M3UParser (incremental, line-by-line), M3UAttributes tokenizer
  EPG/        XMLTVParser (SAX/stream), XMLTVDate (fast timestamp parser), EPGIndex (binary search now/next)
  Search/     SearchIndex (diacritic/case-insensitive, ranked)
  Util/       URLValidator, BrowserInput + BrowserNavigationPolicy, YouTubeLinkParser,
              LogRedactor, Gzip (streaming, Compression framework), StableHash
  Playback/   ReconnectPolicy (exponential back-off)
Lumen/
  App/        LumenApp, AppDelegate (scene routing), AppEnvironment (composition root / DI),
              AppRouter, assets, PrivacyInfo.xcprivacy
  Core/       Networking (HTTPClient, AppError, NetworkMonitor), Storage (SwiftData models,
              LibraryStore, AppSettings), Cache (ChannelCache, ImagePipeline), Security (KeychainStore)
  IPTV/       PlaylistManager (actor), ChannelRepository, EPGLoader (actor), EPGManager, LibrarySnapshot
  Player/     PlayerManager (single AVPlayer, PiP, Now Playing, reconnect), PlaybackState
  Browser/    BrowserTab (WKWebView wrapper), BrowserManager (tabs, memory cap)
  YouTube/    YouTubePlayerView (official IFrame API), YouTubeController (search, recents)
  CarPlay/    CarPlaySceneDelegate, CarPlayCoordinator (templates)
  Features/   Home, LiveTV, Guide (EPG), Favorites, Web (Browser + YouTube), Settings, Player
  UI/         Theme (tokens, motion), Components (LogoImage, ChannelRow/Card, MiniPlayer, states)
LumenTests/   App unit tests.  LumenUITests/  UI smoke tests (synthetic data, no network)
```

**Data flow.** SwiftData stores sources, favorites and history. Secrets live in the Keychain. Parsed playlists are cached once per source as binary plists. `ChannelRepository` builds an immutable `LibrarySnapshot` (channels, categories, search index) **off the main thread** and swaps it in. Views only read it. The same `AppEnvironment` instance serves the iPhone UI and the CarPlay scene.

**Tabs:** Home · Live · Guide · Web (Browser / YouTube) · Settings. iPhone shows five tabs before overflowing into "More", so Favorites are on Home and in Live's filter chips. *Edit* opens full favorites management (reorder and delete).

---

## Compliance decisions (read before App Review)

### CarPlay
- Lumen is a **CarPlay Audio app** (`com.apple.developer.carplay-audio`). **Request the entitlement** at <https://developer.apple.com/contact/carplay/>. Apple grants it per App ID, and App Review checks that the app fits the category.
- The car display uses **templates only**: `CPTabBarTemplate`, `CPListTemplate` (Favorites, Recent, Browse → categories → channels), `CPNowPlayingTemplate` and `CPAlertTemplate` for errors.
- **No video is ever rendered on CarPlay.** CarPlay plays the stream's audio. Playback started from CarPlay caps the HLS bitrate (`preferredPeakBitRate`) to save data. Full quality comes back when the phone's player screen opens.
- There is no browser, web content, YouTube, text entry or configuration on CarPlay. YouTube entries in playlists are filtered out of CarPlay lists.
- Lists respect `CPListTemplate.maximumItemCount`, and drop to 12 rows when `CPSessionConfiguration` reports limited list UIs while driving.
- *Navigation-style interaction*, as described in the original brief, isn't possible: the CarPlay navigation category is only for turn-by-turn navigation apps.

### YouTube
- Videos play **inside the app** with YouTube's **official IFrame Player API** in a WKWebView, set up the same way as Google's own `youtube-ios-player-helper` (page origin = `http://<bundle id>`). This is YouTube's supported embedding method. Nothing is downloaded, scraped, proxied or extracted, and AVPlayer is never used for YouTube.
- Search uses the official **YouTube Data API v3** with the **user's own API key**, stored in the Keychain. No key ships with the app. Without a key, users can paste links or tap **Browse YouTube**, which opens m.youtube.com in the in-app browser.
- Videos whose owners disable embedding (IFrame errors 101/150/152/153) show a message and an **Open in YouTube** button.
- The embed page's origin and referrer are `http://<bundle id>`, exactly as Google's helper library does it; a missing or mismatched origin is the usual cause of embed error 153. If you change the bundle ID, nothing else needs updating.
- Background audio and PiP for YouTube depend on YouTube's embed and aren't guaranteed.

### IPTV content
- No channels or playlists are bundled. Test fixtures are synthetic `example.com` URLs.
- The app doesn't bypass DRM, geo-restrictions or authentication. HTTP Basic credentials, when configured, are sent only to that source.

### Networking / ATS
- IPTV servers often serve playlists, guides and streams over plain HTTP from arbitrary hosts, so `NSAllowsArbitraryLoads` is enabled. Per-domain exceptions can't cover user-supplied servers. **Expect to justify this in App Review** ("user-configured media servers").
- HTTPS-first behaviour stays in place where Lumen controls it:
  - Typed browser addresses are upgraded to `https://`, and `upgradeKnownHostsToHTTPS` is on.
  - The browser shows a lock or a "Not secure" badge.
  - The playlist editor warns about `http://` URLs, and the source list marks insecure sources.
- Certificate validation is left entirely to the system. There is no custom trust evaluation.

---

## Feature notes

| Area | Implementation |
|---|---|
| **Sources** | Two ways to add a provider: an **M3U/M3U8 link** (with optional XMLTV URL and HTTP Basic credentials) or an **Xtream Codes login** (server, username, password). Xtream logins use the panel's standard `get.php` playlist (`type=m3u_plus&output=m3u8`) and `xmltv.php` guide exports, so the rest of the pipeline is unchanged. |
| **M3U parsing** | Streaming: `URLSession.bytes(...).lines` feeds `M3UParser` as data arrives, off the main thread. It handles `#EXTINF` attributes (`tvg-id/name/logo`, `group-title`, language, country), `#EXTGRP`, `#EXTVLCOPT:http-user-agent`, BOM/CRLF, header `url-tvg`, plain URL lists, malformed entries (skipped and counted) and duplicates. Channel IDs stay stable when providers rotate stream URL tokens. |
| **EPG** | Downloaded **to disk**; `.gz` is decompressed file-to-file, then parsed as a stream, so peak memory stays low with 100 MB guides. Only programmes in [now − 2 h, now + 48 h] are kept. The parsed result is cached with ETag/Last-Modified and revalidated only when older than the refresh interval (6/12/24 h). On failure the last good guide is kept and an error is shown. Channel ↔ guide matching (tvg-id, case-insensitive, then display name) runs in the background. |
| **Player** | One shared `AVPlayer`. Handles live and VOD (seek bar for VOD), audio/subtitle track menus (`AVMediaSelectionGroup`), PiP, AirPlay (`AVRoutePickerView`) and background audio (`audiovisualBackgroundPlaybackPolicy`). Errors are mapped to friendly messages. **Auto-reconnect** uses exponential back-off and waits for the network to return. A 15 s stall watchdog is active, with a smaller buffer on cellular, bitrate caps for Data Saver and Low Data Mode, and a live-edge rejoin after long pauses. Interruptions and media-services resets are handled, and Now Playing plus remote commands support channel up/down. |
| **Logos** | Memory cache (cost-limited `NSCache`), then disk, then network. ImageIO **downsamples to the displayed pixel size**, so a 4K logo is never decoded at full size. Requests are coalesced and dead URLs get a 5-minute negative cache. The disk cache is trimmed to 60 MB, and memory is purged on memory warnings. |
| **Browser** | WKWebView with an address/search bar (Google, DuckDuckGo or Bing), back/forward/reload/stop/home, a progress bar, a secure indicator and up to 12 tabs. **At most 3 live web views** exist at once; older tabs are hibernated and reload on demand. Navigation policy blocks `file:`/`javascript:`/`data:`, sends `tel:`/`mailto:`/app links to the system only on a user tap, opens `target=_blank` links in the same tab, recovers when the content process terminates, and keeps fraud warnings on. |
| **Search** | Debounced (250 ms), cancellable, runs off the main thread over a prebuilt index. Matches name, category, country, language and tvg-name, with prefix matches ranked first. |
| **Offline** | The app opens from the channel cache (Application Support) and the guide cache with no network. Refreshes are skipped while offline, and a banner explains why. |
| **Storage** | SwiftData holds sources, favorites and history. UserDefaults holds small preferences only. The Keychain (`AfterFirstUnlockThisDeviceOnly`, so CarPlay works while the phone is locked) holds playlist/EPG URLs, credentials and the YouTube key. Cache files use `completeUntilFirstUserAuthentication` protection and are excluded from backup. |
| **Accessibility** | Dynamic Type text styles throughout, VoiceOver labels and actions (for example, "Add to Favorites" on rows), states shown with text or icons as well as color ("LIVE" badge, ★), Reduce Motion respected, high-contrast color variants, 44 pt hit targets, and player controls that stay visible while VoiceOver is on. |

### Stream formats
AVFoundation plays HLS (`.m3u8`), progressive MP4/MOV and other Apple-supported containers with H.264/HEVC/AAC/AC-3. It **cannot** play raw MPEG-TS (`.ts`) over plain HTTP, RTMP, RTSP or UDP multicast. Apps that do bundle FFmpeg/VLC (tens of MB), which the brief ruled out. Lumen mitigates the most common case: Xtream-style `/live/<user>/<pass>/<id>.ts` URLs are played through their `.m3u8` twin, and Xtream logins request HLS output up front. Other unsupported streams show "Format not supported" with advice to ask the provider for an HLS link.

### iCloud sync
Not enabled. The SwiftData models avoid unique constraints and give every property a default, so they stay **CloudKit-compatible**. To turn sync on, add the iCloud (CloudKit) capability and set `cloudKitDatabase: .automatic` in `PersistenceFactory`. Only small records (sources, favorites, history) would sync; secrets stay in the device Keychain, so on other devices the playlist URLs must be re-entered.

### Background refresh
Lumen refreshes stale sources and guides at launch and whenever it returns to the foreground. It doesn't schedule `BGAppRefreshTask` work. That would cost battery for data the user only needs when the app is open. It's straightforward to add if you want it.

---

## Testing

| Suite | Covers |
|---|---|
| `LumenKitTests` (`swift test`) | M3U: valid, malformed, missing logo/category, duplicates, BOM/CRLF, stable IDs, **50k-channel** playlist, async parsing. XMLTV: valid, malformed, partial recovery, missing stop/title/attributes, **timezone conversion**, window filtering, **large EPG**, index now/next/schedule, channel matching, Codable round-trip. Plus search ranking, YouTube link parsing, browser input (URLs, HTTPS upgrade, search fallback, invalid input), navigation policy, log redaction, reconnect back-off and gzip (in memory and streaming). |
| `LumenTests` | Error mapping (URL, CoreMedia and AVFoundation errors), HTTP status validation, Basic auth, Keychain round-trip, settings persistence, browser tab lifecycle and caps, playback state, YouTube error mapping. |
| `LumenUITests` | Tab navigation, channel list, search, favorite via swipe, playlist URL validation, launch performance. They run with `-UITestMode` (in-memory store, synthetic channels, no network). |

**Manual test checklist** (these need real streams or Apple's simulators):
1. **Streams.** Create a playlist that points at public HLS test streams (for example Apple's sample streams on developer.apple.com) and host it anywhere. Check:
   - play and pause
   - PiP: swipe home while a video is playing
   - AirPlay
   - background audio: lock the screen
   - reconnect: toggle airplane mode during playback
   - dead streams: point at a 404 URL
2. **CarPlay.** In the Simulator choose **I/O → External Displays → CarPlay**. Check:
   - the Favorites, Recent and Browse tabs appear
   - tapping a channel plays audio and shows Now Playing
   - lists stay short
   - favoriting a channel on the phone updates the CarPlay list
   - disconnecting and reconnecting while playing works
3. **Performance.** Use Instruments **Time Profiler** while loading a large playlist to confirm no parsing on the main thread. Use **Allocations** while scrolling Live TV quickly to confirm logo memory stays bounded.

---

## App size
The app has no third-party code or fonts. The only assets are a 6 KB placeholder icon and two colors; everything else uses SF Symbols. Release builds use `-Osize`, whole-module optimization and dead-code stripping. The final App Store size depends on Apple's thinning and compression, so it isn't promised here.

## Before shipping
- Replace the placeholder app icon, bundle ID and the placeholder Privacy and Terms text (Settings → About).
- Get the CarPlay Audio entitlement.
- Prepare an ATS justification and an App Review note: explain that the app ships no content, and give reviewers a demo playlist you're licensed to use.
