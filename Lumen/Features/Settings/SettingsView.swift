import LumenKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ChannelRepository.self) private var channels
    @Environment(EPGManager.self) private var epg
    @Environment(LibraryStore.self) private var library
    @Environment(YouTubeController.self) private var youtube

    @State private var cacheSize: Int64?
    @State private var confirmClearCache = false
    @State private var confirmClearHistory = false
    @State private var apiKeyDraft = ""

    private struct AudioLanguage: Identifiable {
        let id: String
        let name: String
    }

    private static let audioLanguages: [AudioLanguage] = [
        ("", "Device Default"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("ar", "Arabic"), ("hi", "Hindi"), ("tr", "Turkish"),
        ("ru", "Russian"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean")
    ].map { AudioLanguage(id: $0.0, name: $0.1) }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto Play Last Channel", isOn: $settings.autoPlayLastChannel)
                    Picker("Preferred Quality", selection: $settings.quality) {
                        ForEach(PlaybackQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Subtitles On by Default", isOn: $settings.subtitlesEnabled)
                    Picker("Audio Language", selection: $settings.preferredAudioLanguage) {
                        ForEach(Self.audioLanguages) { Text($0.name).tag($0.id) }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text(settings.quality.detail)
                }

                Section("IPTV") {
                    NavigationLink {
                        SourcesView()
                    } label: {
                        LabeledContent("Playlists", value: "\(library.sources.count)")
                    }
                    Picker("Guide Refresh", selection: $settings.epgRefreshHours) {
                        Text("Every 6 hours").tag(6)
                        Text("Every 12 hours").tag(12)
                        Text("Daily").tag(24)
                    }
                    Button {
                        Task { await channels.refreshAll(force: true) }
                    } label: {
                        HStack {
                            Text("Refresh Now")
                            Spacer()
                            if channels.isRefreshing || epg.isLoading { ProgressView() }
                        }
                    }
                    .disabled(channels.isRefreshing || !library.hasSources)
                    if let updated = epg.lastUpdated {
                        LabeledContent("Guide Updated", value: updated.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Accent", selection: $settings.accent) {
                        ForEach(AccentChoice.allCases) { choice in
                            Label {
                                Text(choice.title)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(choice.color)
                            }
                            .tag(choice)
                        }
                    }
                }

                Section("Browser") {
                    Picker("Search Engine", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Homepage (optional)", text: $settings.browserHomepage)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    SecureField(youtube.hasAPIKey ? "API key saved" : "YouTube Data API key", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Save Key") {
                            youtube.saveAPIKey(apiKeyDraft)
                            apiKeyDraft = ""
                        }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        if youtube.hasAPIKey {
                            Button("Remove", role: .destructive) { youtube.saveAPIKey("") }
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("YouTube")
                } footer: {
                    Text("Optional. Enables in-app YouTube search. Create a key in Google Cloud Console (YouTube Data API v3). It's stored only in this device's Keychain.")
                }

                Section {
                    Toggle("Show Recently Watched", isOn: $settings.carPlayShowsRecents)
                    Toggle("Show Categories", isOn: $settings.carPlayShowsCategories)
                } header: {
                    Text("CarPlay")
                } footer: {
                    Text("On CarPlay, Lumen plays the audio of your favorite and recent channels. Video, the browser and YouTube are never shown on the car display. Changes apply the next time CarPlay connects.")
                }

                Section("Storage") {
                    LabeledContent("Cache", value: cacheSize?.formattedByteCount ?? "Calculating…")
                    Button("Clear Cache", role: .destructive) { confirmClearCache = true }
                    Button("Clear Watch History", role: .destructive) { confirmClearHistory = true }
                        .disabled(library.history.isEmpty)
                }

                Section("About") {
                    LabeledContent("Version", value: Self.versionString)
                    NavigationLink("Privacy") { LegalTextView(title: "Privacy", text: LegalText.privacy) }
                    NavigationLink("Terms of Use") { LegalTextView(title: "Terms of Use", text: LegalText.terms) }
                    Text("Lumen is a media player. It does not provide, sell or recommend any channels or subscriptions. Only add playlists you're authorized to use.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task { cacheSize = await AppEnvironment.shared.cacheSize() }
            .confirmationDialog("Clear cached logos, guide data and playlists? Channels will be downloaded again.",
                                isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await AppEnvironment.shared.clearCaches()
                        cacheSize = await AppEnvironment.shared.cacheSize()
                    }
                }
            }
            .confirmationDialog("Clear watch history?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { library.clearHistory() }
            }
            .miniPlayerInset()
        }
    }

    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct LegalTextView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Placeholder legal copy. Replace with your reviewed policy before App Store submission.
enum LegalText {
    static let privacy = """
    Lumen does not collect, sell or share personal data and contains no analytics or advertising SDKs.

    • Playlists, guide data, favorites and history are stored only on this device.
    • Playlist URLs, credentials and your optional YouTube API key are stored in the iOS Keychain.
    • Network requests go directly from your device to the playlist, guide, logo and stream servers you add, and to YouTube when you use YouTube features. Those services have their own privacy policies.
    • The in-app browser uses Apple's WebKit; website data is handled by WebKit and can be cleared in Settings.
    """

    static let terms = """
    Lumen is a player for media you are authorized to access. Lumen does not provide any content.

    You are responsible for ensuring that any playlist, stream or guide you add is legal for you to use. Do not use Lumen to access content in violation of copyright or the terms of the content provider.

    YouTube videos are played using YouTube's official embedded player and are subject to YouTube's Terms of Service.
    """
}
