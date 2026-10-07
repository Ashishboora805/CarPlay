import AVFoundation
import AVKit
import LumenKit
import MediaPlayer
import Observation
import UIKit
import os

/// Owns the single AVPlayer used by the app (iPhone UI, Picture-in-Picture and CarPlay).
///
/// Responsibilities: item lifecycle, status mapping, automatic reconnect with back-off,
/// network-aware buffering, audio-session management, Now Playing / remote commands, and
/// audio/subtitle track selection. The video layer view and PiP controller are owned here so
/// PiP survives the full-screen player being dismissed.
@MainActor
@Observable
final class PlayerManager: NSObject {
    nonisolated private static let logger = Logger(subsystem: "app.lumen", category: "player")
    private static let stallTimeout: Duration = .seconds(15)
    private static let carPlayPeakBitRate: Double = 600_000
    private static let dataSaverPeakBitRate: Double = 1_500_000

    private(set) var status: PlaybackStatus = .idle
    private(set) var currentChannel: Channel?
    private(set) var origin: PlaybackOrigin = .phone
    private(set) var isLive = true
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var audioOptions: [MediaOptionInfo] = []
    private(set) var subtitleOptions: [MediaOptionInfo] = []
    private(set) var selectedAudioID: Int?
    private(set) var selectedSubtitleID: Int?
    private(set) var isPictureInPictureActive = false
    private(set) var isPictureInPicturePossible = false
    private(set) var isExternalPlaybackActive = false
    var isPlayerPresented = false
    var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored let videoView = PlayerLayerView()
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored private var context: [Channel] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var systemNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var mediaOptionsTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var playingSince: Date?
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var audibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var audibleOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var legibleOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?

    @ObservationIgnored private let policy = ReconnectPolicy()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let epg: EPGManager
    @ObservationIgnored private let router: AppRouter

    init(settings: AppSettings, network: NetworkMonitor, library: LibraryStore, epg: EPGManager, router: AppRouter) {
        self.settings = settings
        self.network = network
        self.library = library
        self.epg = epg
        self.router = router
        super.init()
        configurePlayer()
        configureRemoteCommands()
        observeSystemNotifications()
    }

    // MARK: - Public API

    /// Plays a channel. YouTube entries are routed to the official YouTube embed (iPhone only).
    func play(_ channel: Channel, context: [Channel] = [], origin: PlaybackOrigin = .phone) {
        if channel.isYouTube {
            guard origin == .phone, let videoID = YouTubeLinkParser.videoID(from: channel.streamURL) else { return }
            stop()
            router.presentYouTube(videoID: videoID, title: channel.name)
            library.recordWatch(channel)
            return
        }

        self.context = context.filter { !$0.isYouTube }
        self.origin = origin
        currentChannel = channel
        reconnectAttempt = 0
        playingSince = nil
        status = .loading
        activateAudioSession()
        startItem(for: channel)
        library.recordWatch(channel)
        updateNowPlaying(loadArtwork: true)
        if origin == .phone { isPlayerPresented = true }
        postNowPlayingChanged()
    }

    func togglePlayPause() {
        switch status {
        case .playing, .buffering, .loading, .reconnecting:
            pause()
        case .paused:
            resume()
        case .failed:
            retry()
        case .idle:
            if let currentChannel { play(currentChannel, context: context, origin: origin) }
        }
    }

    func pause() {
        reconnectTask?.cancel()
        stallTask?.cancel()
        player.pause()
        pausedAt = .now
        status = .paused
        updateNowPlaying()
        postNowPlayingChanged()
    }

    func resume() {
        guard let channel = currentChannel else { return }
        activateAudioSession()
        // Pausing during a reconnect leaves a failed/half-loaded item behind; `play()` on it does
        // nothing. Also, after a long pause a live stream's buffer is stale: rejoin at the live edge.
        let itemBroken = player.currentItem == nil || player.currentItem?.status == .failed
        let stale = isLive && pausedAt.map { Date().timeIntervalSince($0) > 30 } == true
        if itemBroken || stale {
            status = .loading
            startItem(for: channel)
        } else {
            player.play()
        }
        pausedAt = nil
        updateNowPlaying()
        postNowPlayingChanged()
    }

    /// Manual retry from an error state; resets the back-off.
    func retry() {
        guard let channel = currentChannel else { return }
        reconnectAttempt = 0
        status = .loading
        activateAudioSession()
        startItem(for: channel)
    }

    func stop() {
        reconnectTask?.cancel()
        stallTask?.cancel()
        mediaOptionsTask?.cancel()
        artworkTask?.cancel()
        tearDownItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentChannel = nil
        status = .idle
        audioOptions = []
        subtitleOptions = []
        isPlayerPresented = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        deactivateAudioSession()
        postNowPlayingChanged()
    }

    func playAdjacent(offset: Int) {
        guard let current = currentChannel, !context.isEmpty,
              let index = context.firstIndex(where: { $0.id == current.id }) else { return }
        let next = context[(index + offset + context.count) % context.count]
        play(next, context: context, origin: origin)
    }

    func seek(to seconds: Double) {
        guard !isLive else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) {
        seek(to: max(0, min(duration, currentTime + seconds)))
    }

    /// Called when the phone shows video again after CarPlay-originated playback.
    func restoreVideoQuality() {
        guard origin == .carPlay else { return }
        origin = .phone
        if let item = player.currentItem { applyQuality(to: item) }
        updateNowPlaying()
    }

    func selectAudio(_ id: Int) {
        guard let item = player.currentItem, let group = audibleGroup, audibleOptions.indices.contains(id) else { return }
        item.select(audibleOptions[id], in: group)
        selectedAudioID = id
    }

    func selectSubtitle(_ id: Int?) {
        guard let item = player.currentItem, let group = legibleGroup else { return }
        if let id, legibleOptions.indices.contains(id) {
            item.select(legibleOptions[id], in: group)
        } else {
            item.select(nil, in: group)
        }
        selectedSubtitleID = id
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        }
    }

    // MARK: - Item lifecycle

    private func configurePlayer() {
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.preventsDisplaySleepDuringVideoPlayback = true
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: videoView.playerLayer)
            controller?.delegate = self
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = controller
            if let controller {
                playerObservations.append(controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
                    let possible = controller.isPictureInPicturePossible
                    Task { @MainActor [weak self] in self?.isPictureInPicturePossible = possible }
                })
            }
        }

        playerObservations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let value = player.timeControlStatus
            Task { @MainActor [weak self] in self?.handleTimeControlStatus(value) }
        })
        playerObservations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor [weak self] in self?.isExternalPlaybackActive = active }
        })
    }

    private func startItem(for channel: Channel) {
        reconnectTask?.cancel()
        stallTask?.cancel()
        mediaOptionsTask?.cancel()
        tearDownItemObservers()

        var options: [String: Any] = [:]
        if let userAgent = channel.userAgent {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        // AVFoundation can't play raw MPEG-TS over HTTP. Xtream-style panels serve the same
        // stream as HLS at the `.m3u8` path, so use that variant when the URL has that shape.
        let streamURL = XtreamCodes.hlsAlternative(for: channel.streamURL) ?? channel.streamURL
        let asset = AVURLAsset(url: streamURL, options: options)
        let item = AVPlayerItem(asset: asset)
        // On cellular keep a small forward buffer (saves data and battery); otherwise let AVFoundation decide.
        item.preferredForwardBufferDuration = network.isExpensive || network.isConstrained ? 6 : 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        applyQuality(to: item)
        observeItem(item)

        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func applyQuality(to item: AVPlayerItem) {
        if origin == .carPlay {
            item.preferredPeakBitRate = Self.carPlayPeakBitRate
            return
        }
        switch settings.quality {
        case .high:
            item.preferredPeakBitRate = 0
        case .dataSaver:
            item.preferredPeakBitRate = Self.dataSaverPeakBitRate
        case .automatic:
            item.preferredPeakBitRate = network.isConstrained ? Self.dataSaverPeakBitRate : 0
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor [weak self] in self?.handleItemStatus(status, error: error) }
        })

        let center = NotificationCenter.default
        itemNotificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.handleFailure(error) }
        })
        itemNotificationTokens.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startStallWatchdog() }
        })
        itemNotificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A live stream "ending" means the connection dropped.
                if self.isLive { self.handleFailure(nil) } else { self.status = .paused }
            }
        })
    }

    private func tearDownItemObservers() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        itemNotificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotificationTokens.removeAll()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    // MARK: - State handling

    private func handleItemStatus(_ itemStatus: AVPlayerItem.Status, error: Error?) {
        switch itemStatus {
        case .readyToPlay:
            guard let item = player.currentItem else { return }
            let isIndefinite = item.duration.isIndefinite
            isLive = isIndefinite
            duration = isIndefinite ? 0 : item.duration.seconds
            configureTimeObserver()
            loadMediaOptions(for: item)
            updateNowPlaying()
        case .failed:
            handleFailure(error)
        default:
            break
        }
    }

    private func handleTimeControlStatus(_ value: AVPlayer.TimeControlStatus) {
        guard currentChannel != nil, player.currentItem != nil else { return }
        switch value {
        case .playing:
            stallTask?.cancel()
            if playingSince == nil { playingSince = .now }
            status = .playing
        case .waitingToPlayAtSpecifiedRate:
            // Arm the watchdog first: a reconnect attempt whose server accepts the connection
            // but never sends segments must still time out and try again.
            startStallWatchdog()
            if case .reconnecting = status { return }
            status = status == .loading ? .loading : .buffering
        case .paused:
            if case .reconnecting = status { return }
            if case .failed = status { return }
            if status != .loading { status = .paused }
        @unknown default:
            break
        }
        updateNowPlaying()
        postNowPlayingChanged()
    }

    /// If buffering doesn't recover within the timeout, treat it as a dropped stream.
    private func startStallWatchdog() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stallTimeout)
            guard !Task.isCancelled, let self else { return }
            if self.player.timeControlStatus != .playing, self.currentChannel != nil, self.status != .paused {
                Self.logger.info("Stall timeout; reconnecting")
                self.handleFailure(nil)
            }
        }
    }

    private func handleFailure(_ error: Error?) {
        guard currentChannel != nil else { return }
        if case .failed = status { return }
        // The old item's observers stay live during the back-off sleep; its late failure
        // notifications must not count as extra attempts.
        if case .reconnecting = status { return }
        let mapped = AppError.fromPlayback(error)
        let playedFor = playingSince.map { Date().timeIntervalSince($0) }
        playingSince = nil
        Self.logger.error("Playback failure: \(mapped.title, privacy: .public)")

        guard mapped.isRetryable else {
            fail(with: mapped)
            return
        }
        let attempt = policy.nextAttempt(current: reconnectAttempt, playedFor: playedFor)
        guard let delay = policy.delay(forAttempt: attempt) else {
            fail(with: mapped)
            return
        }
        reconnectAttempt = attempt
        status = .reconnecting(attempt: attempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if !self.network.isConnected {
                await self.network.waitForConnection()
            }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let channel = self.currentChannel else { return }
            self.startItem(for: channel)
        }
        postNowPlayingChanged()
    }

    private func fail(with error: AppError) {
        reconnectTask?.cancel()
        stallTask?.cancel()
        player.pause()
        status = .failed(error)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        NotificationCenter.default.post(name: .lumenPlaybackFailed, object: error)
        postNowPlayingChanged()
    }

    private func configureTimeObserver() {
        guard !isLive, timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.currentTime = seconds.isFinite ? seconds : 0 }
        }
    }

    private func loadMediaOptions(for item: AVPlayerItem) {
        mediaOptionsTask?.cancel()
        let asset = item.asset
        mediaOptionsTask = Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
            self.audibleGroup = audible
            self.legibleGroup = legible
            self.audibleOptions = audible?.options ?? []
            self.legibleOptions = (legible?.options ?? []).filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            self.audioOptions = self.audibleOptions.enumerated().map { MediaOptionInfo(id: $0.offset, displayName: $0.element.displayName) }
            self.subtitleOptions = self.legibleOptions.enumerated().map { MediaOptionInfo(id: $0.offset, displayName: $0.element.displayName) }
            self.applyPreferredTracks(item: item)
        }
    }

    private func applyPreferredTracks(item: AVPlayerItem) {
        if let audible = audibleGroup {
            let preferred = settings.preferredAudioLanguage
            if !preferred.isEmpty, let index = audibleOptions.firstIndex(where: { ($0.extendedLanguageTag ?? "").hasPrefix(preferred) }) {
                item.select(audibleOptions[index], in: audible)
                selectedAudioID = index
            } else if let selected = item.currentMediaSelection.selectedMediaOption(in: audible) {
                selectedAudioID = audibleOptions.firstIndex(of: selected)
            }
        }
        if let legible = legibleGroup {
            if settings.subtitlesEnabled, !legibleOptions.isEmpty {
                let languages = Locale.preferredLanguages.map { String($0.prefix(2)) }
                let index = legibleOptions.firstIndex { option in
                    languages.contains { (option.extendedLanguageTag ?? "").hasPrefix($0) }
                } ?? 0
                item.select(legibleOptions[index], in: legible)
                selectedSubtitleID = index
            } else if let selected = item.currentMediaSelection.selectedMediaOption(in: legible) {
                selectedSubtitleID = legibleOptions.firstIndex(of: selected)
            } else {
                selectedSubtitleID = nil
            }
        }
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try session.setActive(true)
        } catch {
            Self.logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateAudioSession() {
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        systemNotificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(rawType: rawType, rawOptions: rawOptions) }
        })
        systemNotificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentChannel != nil else { return }
                self.activateAudioSession()
                self.retry()
            }
        })
        systemNotificationTokens.append(center.addObserver(forName: .lumenNetworkRestored, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .failed(let error) = self.status, error == .offline || error == .timeout else { return }
                self.retry()
            }
        })
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt?) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            if status.isActive { pause() }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
            if options.contains(.shouldResume), status == .paused { resume() }
        @unknown default:
            break
        }
    }

    // MARK: - Now Playing & remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        _ = center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentChannel != nil else { return .noActionableNowPlayingItem }
                self.resume()
                return .success
            }
        }
        _ = center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentChannel != nil else { return .noActionableNowPlayingItem }
                self.pause()
                return .success
            }
        }
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentChannel != nil else { return .noActionableNowPlayingItem }
                self.togglePlayPause()
                return .success
            }
        }
        _ = center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.context.count > 1 else { return .noSuchContent }
                self.playAdjacent(offset: 1)
                return .success
            }
        }
        _ = center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.context.count > 1 else { return .noSuchContent }
                self.playAdjacent(offset: -1)
                return .success
            }
        }
        _ = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return MainActor.assumeIsolated {
                guard let self, !self.isLive else { return .commandFailed }
                self.seek(to: position)
                return .success
            }
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func updateNowPlaying(loadArtwork: Bool = false) {
        guard let channel = currentChannel else { return }
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = !isLive
        center.nextTrackCommand.isEnabled = context.count > 1
        center.previousTrackCommand.isEnabled = context.count > 1

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: channel.name,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: origin == .carPlay
                ? MPNowPlayingInfoMediaType.audio.rawValue
                : MPNowPlayingInfoMediaType.video.rawValue
        ]
        if let program = epg.current(for: channel) {
            info[MPMediaItemPropertyArtist] = program.title
        } else if let group = channel.group {
            info[MPMediaItemPropertyArtist] = group
        }
        if !isLive, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
        if let nowPlayingArtwork, !loadArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = status == .playing ? .playing : .paused

        if loadArtwork {
            nowPlayingArtwork = nil
            artworkTask?.cancel()
            guard let logoURL = channel.logoURL else { return }
            let channelID = channel.id
            artworkTask = Task { [weak self] in
                guard let image = await ImagePipeline.shared.image(for: logoURL, maxPixelSize: 600),
                      let self, !Task.isCancelled, self.currentChannel?.id == channelID else { return }
                self.nowPlayingArtwork = Self.makeArtwork(image)
                self.updateNowPlaying()
            }
        }
    }

    /// Built outside the main actor's isolation: MediaPlayer calls the handler on its own queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func postNowPlayingChanged() {
        NotificationCenter.default.post(name: .lumenNowPlayingDidChange, object: nil)
    }
}

// MARK: - Picture in Picture

extension PlayerManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isPictureInPictureActive = true
            isPlayerPresented = false
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isPictureInPictureActive = false }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            isPlayerPresented = true
            // Let the full-screen cover present before the PiP window animates into the layer.
            try? await Task.sleep(for: .milliseconds(350))
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Self.logger.error("PiP failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// UIView backed by an AVPlayerLayer. A single instance lives for the app's lifetime.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    // swiftlint:disable:next force_cast
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isAccessibilityElement = true
        accessibilityLabel = "Video"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
