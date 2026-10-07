import LumenKit
import SwiftUI

/// List row for a channel: logo, name, current programme, favorite state.
struct ChannelRow: View {
    let channel: Channel
    let context: [Channel]

    @Environment(PlayerManager.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(EPGManager.self) private var epg

    var body: some View {
        let isFavorite = library.isFavorite(channel.id)
        let program = epg.current(for: channel)
        let isCurrent = player.currentChannel?.id == channel.id

        Button {
            player.play(channel, context: context)
        } label: {
            HStack(spacing: 12) {
                LogoImage(url: channel.logoURL, name: channel.name, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(channel.name)
                            .font(.body.weight(isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                        if channel.isYouTube {
                            Image(systemName: "play.rectangle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("YouTube")
                        }
                    }
                    Text(program?.title ?? channel.category)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Now playing")
                }
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                library.toggleFavorite(channel)
            } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button {
                library.toggleFavorite(channel)
            } label: {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star")
            }
            if let group = channel.group {
                Button {
                    library.toggleFavoriteCategory(group)
                } label: {
                    Label(library.isFavoriteCategory(group) ? "Unfavorite “\(group)”" : "Favorite “\(group)”", systemImage: "folder")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(isFavorite: isFavorite, program: program, isCurrent: isCurrent))
        .accessibilityHint("Plays the channel")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            library.toggleFavorite(channel)
        }
    }

    private func accessibilityText(isFavorite: Bool, program: EPGProgram?, isCurrent: Bool) -> String {
        var parts = [channel.name]
        if let program { parts.append("Now: \(program.title)") } else { parts.append(channel.category) }
        if isFavorite { parts.append("Favorite") }
        if isCurrent { parts.append("Now playing") }
        return parts.joined(separator: ", ")
    }
}

/// Compact card used in horizontal rails on Home.
struct ChannelCard: View {
    let channel: Channel
    let context: [Channel]

    @Environment(PlayerManager.self) private var player
    @Environment(EPGManager.self) private var epg
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let program = epg.current(for: channel)
        Button {
            player.play(channel, context: context)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                LogoImage(url: channel.logoURL, name: channel.name, size: 56, cornerRadius: 12)
                Text(channel.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(program?.title ?? channel.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let program {
                    ProgressView(value: program.progress(at: .now))
                        .progressViewStyle(.linear)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(width: 148, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                library.toggleFavorite(channel)
            } label: {
                Label(library.isFavorite(channel.id) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([channel.name, program.map { "Now: \($0.title)" } ?? channel.category].joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// Persistent mini player shown above the tab bar while something is playing.
struct MiniPlayerBar: View {
    @Environment(PlayerManager.self) private var player
    @Environment(EPGManager.self) private var epg

    var body: some View {
        if let channel = player.currentChannel, !player.isPlayerPresented {
            HStack(spacing: 12) {
                LogoImage(url: channel.logoURL, name: channel.name, size: 36, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle(for: channel)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: playIcon)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.status == .playing ? "Pause" : "Play")
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 44)
                }
                .accessibilityLabel("Stop")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { player.isPlayerPresented = true }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open player") { player.isPlayerPresented = true }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var playIcon: String {
        switch player.status {
        case .playing, .buffering, .loading, .reconnecting: "pause.fill"
        case .failed: "arrow.clockwise"
        default: "play.fill"
        }
    }

    private func subtitle(for channel: Channel) -> String {
        switch player.status {
        case .failed(let error): return error.title
        case .reconnecting: return "Reconnecting…"
        case .buffering, .loading: return "Loading…"
        default: return epg.current(for: channel)?.title ?? channel.category
        }
    }
}

extension View {
    /// Adds the mini player as a bottom inset (each tab root applies it so it sits above the tab bar).
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }
}
