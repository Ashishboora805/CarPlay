import SwiftUI
import UIKit

/// Full-screen host for the official YouTube embed.
struct YouTubePlayerScreen: View {
    let request: YouTubeRequest

    @Environment(AppRouter.self) private var router
    @Environment(YouTubeController.self) private var youtube
    @Environment(\.openURL) private var openURL
    @State private var error: AppError?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    router.youtubeRequest = nil
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Text(request.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button {
                    openInYouTube()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Open in YouTube")
            }
            .padding(.horizontal, 8)
            .foregroundStyle(.white)

            ZStack {
                YouTubePlayerView(videoID: request.videoID) { event in
                    switch event {
                    case .ready, .playing:
                        isLoading = false
                    case .error:
                        isLoading = false
                        error = event.appError
                    default:
                        break
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)

                if isLoading && error == nil {
                    ProgressView().tint(.white)
                }
                if let error {
                    StateMessageView(systemImage: "play.slash", title: error.title, message: error.message,
                                     actionTitle: "Open in YouTube", action: openInYouTube)
                        .foregroundStyle(.white)
                        .background(Color.black)
                }
            }
            .frame(maxHeight: .infinity)

            Text("Playback is provided by YouTube. Content and ads are YouTube's.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            youtube.recordPlayed(YouTubeVideo(id: request.videoID, title: request.title, channelTitle: nil,
                                              thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(request.videoID)/mqdefault.jpg")))
        }
    }

    private func openInYouTube() {
        let appURL = URL(string: "youtube://watch?v=\(request.videoID)")!
        let webURL = URL(string: "https://www.youtube.com/watch?v=\(request.videoID)")!
        if UIApplication.shared.canOpenURL(appURL) {
            openURL(appURL)
        } else {
            openURL(webURL)
        }
    }
}
