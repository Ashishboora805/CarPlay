import AVFoundation
import Foundation
import LumenKit

/// User-facing error taxonomy. Every network, parse and playback failure is mapped to one of
/// these so the UI can always show a friendly title, message and (where useful) a Retry action.
enum AppError: Error, Equatable, Hashable, Sendable {
    case offline
    case timeout
    case dnsFailure
    case cannotConnect
    case insecureConnection
    case http(status: Int)
    case authenticationFailed
    case invalidURL
    case invalidPlaylist
    case emptyPlaylist
    case epgUnavailable
    case streamUnavailable
    case unsupportedFormat
    case embeddingNotAllowed
    case cancelled
    case unknown(String)

    var title: String {
        switch self {
        case .offline: "You're offline"
        case .timeout: "The connection timed out"
        case .dnsFailure: "Server not found"
        case .cannotConnect: "Can't reach the server"
        case .insecureConnection: "Secure connection failed"
        case .http(let status): "Server error (\(status))"
        case .authenticationFailed: "Sign-in required"
        case .invalidURL: "Invalid address"
        case .invalidPlaylist: "Invalid playlist"
        case .emptyPlaylist: "Playlist is empty"
        case .epgUnavailable: "TV guide unavailable"
        case .streamUnavailable: "Unable to play this channel"
        case .unsupportedFormat: "Format not supported"
        case .embeddingNotAllowed: "Video can't be played here"
        case .cancelled: "Cancelled"
        case .unknown: "Something went wrong"
        }
    }

    var message: String {
        switch self {
        case .offline: "Check your internet connection. Cached channels and guide data are still available."
        case .timeout: "The server took too long to respond. It may be busy or offline."
        case .dnsFailure: "The server address couldn't be found. Check the URL or your network."
        case .cannotConnect: "The server refused the connection or is offline."
        case .insecureConnection: "A secure connection to the server couldn't be established."
        case .http(let status): "The server responded with HTTP \(status)."
        case .authenticationFailed: "The server rejected the credentials. Check the username and password for this source."
        case .invalidURL: "Enter a valid http:// or https:// address."
        case .invalidPlaylist: "This doesn't look like an M3U playlist."
        case .emptyPlaylist: "The playlist contains no playable channels."
        case .epgUnavailable: "Guide data couldn't be loaded. Showing the last saved guide where available."
        case .streamUnavailable: "The stream may be offline or unavailable."
        case .unsupportedFormat: "This stream uses a format or codec iOS can't play (for example raw MPEG-TS). Ask your provider for an HLS (.m3u8) link."
        case .embeddingNotAllowed: "The owner of this video doesn't allow playback in other apps. Open it in YouTube instead."
        case .cancelled: "The operation was cancelled."
        case .unknown(let detail): detail.isEmpty ? "Please try again." : detail
        }
    }

    /// Whether an automatic or manual retry has a reasonable chance of succeeding.
    var isRetryable: Bool {
        switch self {
        case .invalidURL, .invalidPlaylist, .emptyPlaylist, .unsupportedFormat,
             .authenticationFailed, .embeddingNotAllowed, .cancelled:
            false
        case .http(let status):
            status >= 500 || status == 408 || status == 429
        default:
            true
        }
    }

    static func from(_ error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return .cancelled }
        if let m3u = error as? M3UError {
            return m3u == .noPlayableEntries || m3u == .empty ? .emptyPlaylist : .invalidPlaylist
        }
        if error is XMLTVError || error is GzipError { return .epgUnavailable }
        if let urlError = error as? URLError { return from(urlError: urlError.code) }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return from(urlError: URLError.Code(rawValue: nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return from(urlError: URLError.Code(rawValue: underlying.code))
        }
        return .unknown(nsError.localizedDescription)
    }

    /// Maps AVFoundation / CoreMedia playback failures.
    static func fromPlayback(_ error: Error?) -> AppError {
        guard let error else { return .streamUnavailable }
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain { return from(error) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSURLErrorDomain { return from(underlying) }
            if underlying.domain == "CoreMediaErrorDomain" { return fromCoreMedia(underlying.code) }
        }
        if nsError.domain == "CoreMediaErrorDomain" { return fromCoreMedia(nsError.code) }

        if nsError.domain == AVFoundationErrorDomain, let code = AVError.Code(rawValue: nsError.code) {
            switch code {
            case .fileFormatNotRecognized, .decoderNotFound, .decodeFailed,
                 .failedToParse, .contentIsUnavailable, .noCompatibleAlternatesForExternalDisplay:
                return .unsupportedFormat
            case .contentIsProtected, .applicationIsNotAuthorized, .contentIsNotAuthorized:
                return .authenticationFailed
            case .serverIncorrectlyConfigured, .noLongerPlayable:
                return .streamUnavailable
            default:
                return .streamUnavailable
            }
        }
        return .streamUnavailable
    }

    private static func fromCoreMedia(_ code: Int) -> AppError {
        switch code {
        case -12660, -12937: .authenticationFailed // HTTP 403 / 401
        case -12938: .streamUnavailable            // HTTP 404
        case -12927, -12645: .unsupportedFormat    // unsupported playlist / media format
        case -12889, -16839: .timeout             // no response / segment timeout
        default: .streamUnavailable
        }
    }

    private static func from(urlError code: URLError.Code) -> AppError {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            .offline
        case .timedOut:
            .timeout
        case .cannotFindHost, .dnsLookupFailed:
            .dnsFailure
        case .cannotConnectToHost:
            .cannotConnect
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .appTransportSecurityRequiresSecureConnection:
            .insecureConnection
        case .userAuthenticationRequired, .userCancelledAuthentication:
            .authenticationFailed
        case .badURL, .unsupportedURL:
            .invalidURL
        case .cancelled:
            .cancelled
        case .badServerResponse, .zeroByteResource, .cannotDecodeContentData, .cannotParseResponse:
            .invalidPlaylist
        default:
            .unknown("Network error (\(code.rawValue)).")
        }
    }
}

extension AppError: LocalizedError {
    var errorDescription: String? { title }
    var failureReason: String? { message }
}

extension AppError: Identifiable {
    var id: String { "\(self)" }
}
