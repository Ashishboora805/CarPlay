import LumenKit
import SwiftUI

struct YouTubeHomeView: View {
    @Environment(YouTubeController.self) private var youtube
    @Environment(AppRouter.self) private var router
    @State private var linkText = ""
    @State private var searchText = ""
    @State private var linkError: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Paste a YouTube link or video ID", text: $linkText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(playLink)
                    Button("Play", action: playLink)
                        .buttonStyle(.borderedProminent)
                        .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let linkError {
                    Text(linkError).font(.caption).foregroundStyle(.red)
                }
                // PasteButton reads the clipboard only when tapped, without a permission prompt.
                PasteButton(payloadType: URL.self) { urls in
                    guard let url = urls.first else { return }
                    linkText = url.absoluteString
                    playLink()
                }
                .labelStyle(.titleAndIcon)
            } header: {
                Text("Play a video")
            }

            Section {
                if youtube.hasAPIKey {
                    TextField("Search YouTube", text: $searchText)
                        .submitLabel(.search)
                        .onChange(of: searchText) { _, value in youtube.search(value) }
                    if youtube.isSearching {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    if let error = youtube.searchError, !searchText.isEmpty {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(youtube.results) { video in
                        VideoRow(video: video) { play(video) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In-app search needs your own YouTube Data API key.")
                            .font(.subheadline)
                        Text("Add one in Settings › YouTube, or browse YouTube's mobile site below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    router.webSegment = .browser
                    router.openInBrowser(URL(string: "https://m.youtube.com")!)
                } label: {
                    Label("Browse YouTube", systemImage: "safari")
                }
            } header: {
                Text("Search")
            }

            if !youtube.recents.isEmpty {
                Section {
                    ForEach(youtube.recents) { video in
                        VideoRow(video: video) { play(video) }
                    }
                } header: {
                    HStack {
                        Text("Recently Played")
                        Spacer()
                        Button("Clear") { youtube.clearRecents() }.font(.caption)
                    }
                }
            }

            Section {
                Text("Videos play with YouTube's official embedded player. Some videos can't be played outside YouTube; those open in the YouTube app. YouTube isn't available on CarPlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func playLink() {
        guard let id = YouTubeLinkParser.videoID(fromString: linkText) else {
            linkError = "That doesn't look like a YouTube video link."
            return
        }
        linkError = nil
        router.presentYouTube(videoID: id, title: "YouTube Video")
        linkText = ""
    }

    private func play(_ video: YouTubeVideo) {
        router.presentYouTube(videoID: video.id, title: video.title)
    }
}

private struct VideoRow: View {
    let video: YouTubeVideo
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ThumbnailImage(url: video.thumbnailURL, width: 112)
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    if let channel = video.channelTitle {
                        Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the video")
    }
}
