import AVKit
import LumenKit
import SwiftUI
import UIKit

/// Full-screen TV-style player. Controls auto-hide after a few seconds of inactivity.
struct PlayerScreen: View {
    @Environment(PlayerManager.self) private var player
    @Environment(EPGManager.self) private var epg
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubPosition: Double?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerVideoView(view: player.videoView)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            statusOverlay

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controlsVisible)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .onAppear {
            player.restoreVideoQuality()
            scheduleHide()
        }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: player.status) { _, status in
            if status != .playing { showControls(autoHide: false) } else { scheduleHide() }
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var statusOverlay: some View {
        switch player.status {
        case .loading, .buffering:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .accessibilityLabel("Loading")
        case .reconnecting(let attempt):
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Reconnecting… (\(attempt))")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .accessibilityElement(children: .combine)
        case .failed(let error):
            StateMessageView(error: error, retry: { player.retry() })
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .environment(\.colorScheme, .dark)
                .padding()
        default:
            EmptyView()
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .foregroundStyle(.white)
        .background {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                player.isPlayerPresented = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close player")

            if let channel = player.currentChannel {
                LogoImage(url: channel.logoURL, name: channel.name, size: 36, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(channel.name).font(.headline).lineLimit(1)
                        if player.isLive { LiveBadge() }
                    }
                    if let program = epg.current(for: channel) {
                        Text(program.title).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }
            }
            Spacer()
            if let channel = player.currentChannel {
                Button {
                    library.toggleFavorite(channel)
                } label: {
                    Image(systemName: library.isFavorite(channel.id) ? "star.fill" : "star")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(library.isFavorite(channel.id) ? "Remove from Favorites" : "Add to Favorites")
            }
            RoutePickerView()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
        }
        .padding(.horizontal, 12)
    }

    private var centerControls: some View {
        HStack(spacing: 44) {
            Button { player.playAdjacent(offset: -1); scheduleHide() } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .accessibilityLabel("Previous channel")

            if !player.isLive {
                Button { player.skip(by: -15); scheduleHide() } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }
                .accessibilityLabel("Back 15 seconds")
            }

            Button {
                player.togglePlayPause()
                scheduleHide()
            } label: {
                Image(systemName: player.status == .playing || player.status == .buffering ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 72, height: 72)
            }
            .accessibilityLabel(player.status == .playing ? "Pause" : "Play")

            if !player.isLive {
                Button { player.skip(by: 15); scheduleHide() } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }
                .accessibilityLabel("Forward 15 seconds")
            }

            Button { player.playAdjacent(offset: 1); scheduleHide() } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
            .accessibilityLabel("Next channel")
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !player.isLive, player.duration > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { scrubPosition ?? player.currentTime },
                        set: { scrubPosition = $0 }
                    ), in: 0...max(player.duration, 1)) { editing in
                        if !editing, let position = scrubPosition {
                            player.seek(to: position)
                            scrubPosition = nil
                        }
                        if editing { hideTask?.cancel() } else { scheduleHide() }
                    }
                    .accessibilityLabel("Playback position")
                    HStack {
                        Text(format(scrubPosition ?? player.currentTime))
                        Spacer()
                        Text(format(player.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                }
            }

            HStack(spacing: 18) {
                Image(systemName: "speaker.fill").font(.caption).accessibilityHidden(true)
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Volume")
                Spacer()
                tracksMenu
                if player.isPictureInPicturePossible {
                    Button { player.togglePictureInPicture() } label: {
                        Image(systemName: player.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Picture in Picture")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var tracksMenu: some View {
        if !player.audioOptions.isEmpty || !player.subtitleOptions.isEmpty {
            Menu {
                if player.audioOptions.count > 1 {
                    Section("Audio") {
                        ForEach(player.audioOptions) { option in
                            Button {
                                player.selectAudio(option.id)
                            } label: {
                                if player.selectedAudioID == option.id {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    }
                }
                if !player.subtitleOptions.isEmpty {
                    Section("Subtitles") {
                        Button {
                            player.selectSubtitle(nil)
                        } label: {
                            if player.selectedSubtitleID == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                        }
                        ForEach(player.subtitleOptions) { option in
                            Button {
                                player.selectSubtitle(option.id)
                            } label: {
                                if player.selectedSubtitleID == option.id {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Audio and subtitles")
        }
    }

    // MARK: - Controls visibility

    private func toggleControls() {
        if controlsVisible {
            controlsVisible = false
            hideTask?.cancel()
        } else {
            showControls(autoHide: true)
        }
    }

    private func showControls(autoHide: Bool) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // Keep controls up for VoiceOver users and whenever playback isn't running.
        guard !voiceOverEnabled, player.status == .playing else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// Hosts the app-lifetime `PlayerLayerView` so the layer (and PiP) outlive this screen.
struct PlayerVideoView: UIViewRepresentable {
    let view: PlayerLayerView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

/// System AirPlay route picker.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
