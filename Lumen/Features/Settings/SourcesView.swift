import LumenKit
import SwiftUI

struct SourcesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ChannelRepository.self) private var channels
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            if library.sources.isEmpty {
                StateMessageView(systemImage: "list.bullet.rectangle.portrait", title: "No playlists",
                                 message: "Add an M3U/M3U8 playlist URL from your provider.")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            ForEach(library.sources) { source in
                NavigationLink {
                    SourceEditorView(sourceID: source.id)
                } label: {
                    SourceRow(source: source, status: channels.status[source.id])
                }
                .swipeActions(edge: .leading) {
                    Button {
                        library.setEnabled(!source.isEnabled, for: source.id)
                        Task { await channels.sourcesDidChange() }
                    } label: {
                        Label(source.isEnabled ? "Disable" : "Enable", systemImage: source.isEnabled ? "pause.circle" : "play.circle")
                    }
                    .tint(source.isEnabled ? .gray : .green)
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { library.sources[$0].id }
                ids.forEach(library.deleteSource)
                Task { await channels.sourcesDidChange() }
            }
            .onMove { from, to in
                library.moveSources(from: from, to: to)
                Task { await channels.sourcesDidChange() }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.isAddingSource = true
                } label: {
                    Label("Add Playlist", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
    }
}

private struct SourceRow: View {
    let source: SourceEntity
    let status: ChannelRepository.SourceStatus?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(source.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name).font(.body.weight(.medium))
                    if source.usesInsecureConnection {
                        Image(systemName: "lock.open")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Unencrypted connection")
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer()
            if status == .loading { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(source.isEnabled ? "Enabled" : "Disabled")
    }

    private var statusIsError: Bool {
        if case .failed = status { return true }
        return false
    }

    private var detail: String {
        if case .failed(let error) = status { return error.title }
        var parts = [source.displayHost]
        if source.channelCount > 0 { parts.append("\(source.channelCount) channels") }
        if let refreshed = source.lastRefreshedAt {
            parts.append("Updated \(refreshed.formatted(.relative(presentation: .named)))")
        }
        if !source.isEnabled { parts.append("Disabled") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct SourceEditorView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case m3u, xtream
        var id: String { rawValue }
        var title: String { self == .m3u ? "M3U Link" : "Xtream Codes" }
    }

    let sourceID: UUID?

    @Environment(LibraryStore.self) private var library
    @Environment(ChannelRepository.self) private var channels
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .m3u
    @State private var name = ""
    @State private var playlistURL = ""
    @State private var xtreamServer = ""
    @State private var epgURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var refreshHours = 24
    @State private var isEnabled = true
    @State private var validationMessage: String?
    @State private var didLoad = false
    @State private var confirmDelete = false

    private var isNew: Bool { sourceID == nil }

    var body: some View {
        Form {
            if isNew {
                Picker("Type", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                TextField("Name", text: $name)
                if mode == .m3u {
                    TextField("Playlist URL (M3U / M3U8)", text: $playlistURL, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                        .accessibilityIdentifier("playlistURL")
                    TextField("EPG URL (XMLTV, optional)", text: $epgURL, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                } else {
                    TextField("Server (e.g. http://host:port)", text: $xtreamServer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("xtreamServer")
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
            } footer: {
                if let validationMessage {
                    Text(validationMessage).foregroundStyle(.red)
                } else if mode == .xtream {
                    Text("Uses your provider's standard playlist and guide exports. Credentials are stored in the Keychain and sent only to this server.")
                } else if playlistURL.lowercased().hasPrefix("http://") {
                    Label("This playlist uses an unencrypted connection (http). Prefer https if your provider supports it.",
                          systemImage: "lock.open")
                } else {
                    Text("If the playlist advertises a guide (url-tvg), it's used automatically.")
                }
            }

            if mode == .m3u {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Authentication (optional)")
                } footer: {
                    Text("For servers that use HTTP Basic authentication. Stored in the Keychain.")
                }
            }

            Section("Options") {
                Picker("Refresh", selection: $refreshHours) {
                    Text("Every hour").tag(1)
                    Text("Every 6 hours").tag(6)
                    Text("Every 12 hours").tag(12)
                    Text("Daily").tag(24)
                    Text("Weekly").tag(168)
                }
                Toggle("Enabled", isOn: $isEnabled)
            }

            if !isNew {
                Section {
                    Button("Delete Playlist", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(isNew ? "Add Playlist" : "Edit Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(mode == .m3u
                              ? playlistURL.trimmingCharacters(in: .whitespaces).isEmpty
                              : xtreamServer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Delete this playlist? Its channels will be removed from Lumen.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let sourceID {
                    library.deleteSource(id: sourceID)
                    Task { await channels.sourcesDidChange() }
                }
                dismiss()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let sourceID, let source = library.source(id: sourceID) else { return }
        name = source.name
        refreshHours = source.refreshIntervalHours
        isEnabled = source.isEnabled
        if let secrets = library.secrets(for: sourceID) {
            // A saved Xtream login is edited as server/username/password, not as a raw get.php link.
            if secrets.playlistURL.lastPathComponent == "get.php",
               let items = URLComponents(url: secrets.playlistURL, resolvingAgainstBaseURL: false)?.queryItems,
               let user = items.first(where: { $0.name == "username" })?.value,
               let pass = items.first(where: { $0.name == "password" })?.value,
               let account = XtreamCodes.account(server: secrets.playlistURL.absoluteString, username: user, password: pass) {
                mode = .xtream
                xtreamServer = account.server.absoluteString
                username = user
                password = pass
                return
            }
            playlistURL = secrets.playlistURL.absoluteString
            epgURL = secrets.epgURL?.absoluteString ?? ""
            username = secrets.credentials?.username ?? ""
            password = secrets.credentials?.password ?? ""
        }
    }

    private func save() {
        let secrets: SourceSecrets
        switch mode {
        case .xtream:
            // Credentials travel in the panel's own query parameters; no Basic auth header.
            guard let account = XtreamCodes.account(server: xtreamServer, username: username, password: password),
                  let playlist = account.playlistURL else {
                validationMessage = "Enter the server address, username and password from your provider."
                return
            }
            secrets = SourceSecrets(playlistURL: playlist, epgURL: account.epgURL, credentials: nil)
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = account.server.host ?? "Xtream" }
        case .m3u:
            guard let playlist = URLValidator.userURL(from: playlistURL) else {
                validationMessage = "Enter a valid playlist URL starting with http:// or https://."
                return
            }
            var epg: URL?
            if !epgURL.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let parsed = URLValidator.userURL(from: epgURL) else {
                    validationMessage = "Enter a valid EPG URL, or leave it empty."
                    return
                }
                epg = parsed
            }
            let trimmedUser = username.trimmingCharacters(in: .whitespaces)
            let credentials = trimmedUser.isEmpty ? nil : SourceCredentials(username: trimmedUser, password: password)
            secrets = SourceSecrets(playlistURL: playlist, epgURL: epg, credentials: credentials)
        }
        let id = library.saveSource(id: sourceID, name: name, secrets: secrets,
                                    refreshIntervalHours: refreshHours, isEnabled: isEnabled)
        Task {
            if isEnabled {
                await channels.refresh(sourceID: id)
            } else {
                await channels.sourcesDidChange()
            }
        }
        dismiss()
    }
}
