import LumenKit
import SwiftUI

struct GuideView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case favorites, all
        var id: String { rawValue }
        var title: String { self == .favorites ? "Favorites" : "All Channels" }
    }

    @Environment(ChannelRepository.self) private var channels
    @Environment(EPGManager.self) private var epg
    @Environment(LibraryStore.self) private var library
    @State private var scope: Scope = .all

    var body: some View {
        NavigationStack {
            // Re-renders once a minute so "now" and progress bars stay current, without per-row timers.
            TimelineView(.everyMinute) { timeline in
                content(now: timeline.date)
            }
            .background(Theme.background)
            .navigationTitle("Guide")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await channels.refreshAll(force: true)
            }
            .navigationDestination(for: ChannelID.self) { id in
                if let channel = channels.channel(id: id) {
                    ChannelScheduleView(channel: channel)
                }
            }
            .miniPlayerInset()
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let list = guideChannels
        if list.isEmpty {
            emptyState.frame(maxHeight: .infinity)
        } else {
            List {
                if let error = epg.lastError {
                    Label(error.title, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(list) { channel in
                    NavigationLink(value: channel.id) {
                        GuideRow(channel: channel, now: now)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var guideChannels: [Channel] {
        switch scope {
        case .favorites:
            return library.favoriteChannels
                .compactMap { channels.channel(rawID: $0.key) }
                .filter { epg.hasGuide(for: $0) }
        case .all:
            return epg.guideChannelIDs.compactMap { channels.channel(id: $0) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if epg.isLoading {
            ProgressView("Loading guide…")
        } else if let error = epg.lastError {
            StateMessageView(error: error) {
                Task { await channels.refreshAll(force: true) }
            }
        } else if scope == .favorites {
            StateMessageView(systemImage: "star", title: "No favorites with guide data",
                             message: "Favorite channels that have EPG information appear here.")
        } else {
            StateMessageView(systemImage: "calendar.badge.exclamationmark", title: "No guide data",
                             message: "Add an XMLTV EPG URL to a playlist in Settings, or use a playlist that includes one (url-tvg).")
        }
    }
}

private struct GuideRow: View {
    let channel: Channel
    let now: Date
    @Environment(EPGManager.self) private var epg

    var body: some View {
        HStack(spacing: 12) {
            LogoImage(url: channel.logoURL, name: channel.name, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                NowNextView(current: epg.current(for: channel, at: now),
                            next: epg.next(for: channel, after: now),
                            now: now)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Per-channel schedule (timeline) grouped by day, scrolled to the current programme.
struct ChannelScheduleView: View {
    let channel: Channel
    @Environment(EPGManager.self) private var epg
    @Environment(PlayerManager.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let now = timeline.date
            let programs = epg.schedule(for: channel, from: now.addingTimeInterval(-EPGLoader.pastWindow),
                                        to: now.addingTimeInterval(EPGLoader.futureWindow))
            let days = Dictionary(grouping: programs) { Calendar.current.startOfDay(for: $0.start) }
            let sortedDays = days.keys.sorted()
            let currentID = programs.first { $0.isAiring(at: now) }?.id

            ScrollViewReader { proxy in
                List {
                    Section {
                        header
                    }
                    ForEach(sortedDays, id: \.self) { day in
                        Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                            ForEach(days[day] ?? []) { program in
                                ProgramRow(program: program, now: now)
                                    .id(program.id)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .onAppear {
                    if let currentID { proxy.scrollTo(currentID, anchor: .top) }
                }
            }
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerInset()
    }

    private var header: some View {
        HStack(spacing: 14) {
            LogoImage(url: channel.logoURL, name: channel.name, size: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text(channel.name).font(.headline)
                HStack {
                    Button {
                        player.play(channel, context: [])
                    } label: {
                        Label("Watch", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        library.toggleFavorite(channel)
                    } label: {
                        Image(systemName: library.isFavorite(channel.id) ? "star.fill" : "star")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(library.isFavorite(channel.id) ? "Remove from Favorites" : "Add to Favorites")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProgramRow: View {
    let program: EPGProgram
    let now: Date

    var body: some View {
        let airing = program.isAiring(at: now)
        let past = program.end <= now
        HStack(alignment: .top, spacing: 12) {
            Text(program.start.formatted(date: .omitted, time: .shortened))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(past ? .tertiary : .secondary)
                .frame(minWidth: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(program.title)
                        .font(.body.weight(airing ? .semibold : .regular))
                        .foregroundStyle(past ? .secondary : .primary)
                    if airing { LiveBadge() }
                }
                if let subtitle = program.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if airing {
                    ProgressView(value: program.progress(at: now)).progressViewStyle(.linear)
                }
                if let summary = program.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(airing: airing))
    }

    private func accessibilityText(airing: Bool) -> String {
        var parts = ["\(program.start.formatted(date: .omitted, time: .shortened)), \(program.title)"]
        if airing { parts.append("On now") }
        if let subtitle = program.subtitle { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }
}
