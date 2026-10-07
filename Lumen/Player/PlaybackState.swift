import AVFoundation
import Foundation

enum PlaybackStatus: Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case reconnecting(attempt: Int)
    case failed(AppError)

    var isActive: Bool {
        switch self {
        case .idle, .failed: false
        default: true
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: "Stopped"
        case .loading: "Loading"
        case .playing: "Playing"
        case .paused: "Paused"
        case .buffering: "Buffering"
        case .reconnecting(let attempt): "Reconnecting, attempt \(attempt)"
        case .failed(let error): error.title
        }
    }
}

/// Where playback was started from. CarPlay starts audio-first playback at a reduced bitrate.
enum PlaybackOrigin: Equatable {
    case phone
    case carPlay
}

/// An audio or subtitle choice presented in the player's menus.
struct MediaOptionInfo: Identifiable, Hashable {
    let id: Int
    let displayName: String
}
