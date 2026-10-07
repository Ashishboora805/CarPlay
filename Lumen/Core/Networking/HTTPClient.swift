import Foundation
import LumenKit
import os

/// Thin async wrapper over URLSession with sane timeouts, typed error mapping and bounded
/// retries for transient failures. System networking performs certificate validation; there
/// is no custom trust evaluation anywhere in the app.
final class HTTPClient: Sendable {
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Lumen/\(version) (iOS)"
    }()

    private static let logger = Logger(subsystem: "app.lumen", category: "http")

    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData // caching is handled explicitly
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
            self.session = URLSession(configuration: configuration)
        }
    }

    static func request(_ url: URL, credentials: SourceCredentials? = nil, timeout: TimeInterval = 25) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let credentials, let header = credentials.basicAuthorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Fetches the full body. Retries timeouts, dropped connections and 5xx responses.
    func data(for request: URLRequest, retries: Int = 2) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                return (data, try Self.validate(response))
            } catch {
                let mapped = AppError.from(error)
                attempt += 1
                guard attempt <= retries, Self.shouldRetry(mapped) else {
                    Self.logger.error("Request failed: \(LogRedactor.redact(request.url ?? URL(fileURLWithPath: "/")), privacy: .public) – \(mapped.title, privacy: .public)")
                    throw mapped
                }
                try await Task.sleep(for: .milliseconds(500 * (1 << (attempt - 1))))
            }
        }
    }

    /// Streams the body, so callers can parse while downloading.
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            return (bytes, try Self.validate(response))
        } catch {
            throw AppError.from(error)
        }
    }

    /// Downloads to a temporary file (moved by the caller). Keeps large EPGs out of memory.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        do {
            let (url, response) = try await session.download(for: request)
            return (url, try Self.validate(response))
        } catch {
            throw AppError.from(error)
        }
    }

    static func validate(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidPlaylist }
        switch http.statusCode {
        case 200..<300, 304:
            return http
        case 401, 403:
            throw AppError.authenticationFailed
        default:
            throw AppError.http(status: http.statusCode)
        }
    }

    private static func shouldRetry(_ error: AppError) -> Bool {
        switch error {
        case .timeout, .cannotConnect: true
        case .http(let status): status >= 500 || status == 429
        default: false
        }
    }
}

/// Optional HTTP Basic credentials for a source. Stored only in the Keychain.
struct SourceCredentials: Codable, Hashable, Sendable {
    var username: String
    var password: String

    var basicAuthorizationHeader: String? {
        guard !username.isEmpty else { return nil }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}
