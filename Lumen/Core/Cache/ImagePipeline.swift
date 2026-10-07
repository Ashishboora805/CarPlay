import ImageIO
import LumenKit
import UIKit

/// Logo/thumbnail loader: memory cache → disk cache → network.
///
/// - Images are decoded with ImageIO thumbnails at the exact pixel size requested, so a 4K
///   logo shown at 44pt costs ~30 KB of memory instead of ~33 MB.
/// - Concurrent requests for the same image share one download/decode.
/// - The memory cache is cost-limited and purged on memory warnings.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private static let maxDownloadBytes = 4 * 1024 * 1024
    private static let diskLimitBytes: Int64 = 60 * 1024 * 1024

    nonisolated(unsafe) private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 600
        return cache
    }()
    private let directory: URL
    private let session: URLSession
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// URLs that recently failed; avoids hammering dead logo hosts while scrolling.
    private var failures: [String: Date] = [:]

    init(directory: URL = CacheDirectories.logos) {
        self.directory = directory
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.httpAdditionalHeaders = ["User-Agent": HTTPClient.userAgent]
        self.session = URLSession(configuration: configuration)
    }

    private static func memoryKey(_ url: URL, _ pixelSize: Int) -> String {
        "\(url.absoluteString)#\(pixelSize)"
    }

    private func diskURL(for url: URL) -> URL {
        directory.appendingPathComponent(StableHash.hex(url.absoluteString))
    }

    /// Synchronous memory-cache lookup so cells can render cached logos without a flash.
    nonisolated func cachedImage(for url: URL, maxPixelSize: CGFloat) -> UIImage? {
        memory.object(forKey: Self.memoryKey(url, Int(maxPixelSize.rounded(.up))) as NSString)
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let pixels = max(16, Int(maxPixelSize.rounded(.up)))
        let key = Self.memoryKey(url, pixels)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let failedAt = failures[url.absoluteString], Date().timeIntervalSince(failedAt) < 300 { return nil }
        if let task = inFlight[key] { return await task.value }

        let diskURL = diskURL(for: url)
        let session = session
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            var data = try? Data(contentsOf: diskURL)
            if data == nil {
                data = await Self.download(url, session: session)
                if let data { try? data.write(to: diskURL, options: .lumenCache) }
            }
            guard let data, !Task.isCancelled else { return nil }
            return Self.downsample(data, maxPixelSize: pixels)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key as NSString, cost: cost)
        } else {
            failures[url.absoluteString] = Date()
        }
        return image
    }

    private static func download(_ url: URL, session: URLSession) async -> Data? {
        guard let result = try? await session.data(from: url),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              result.0.count <= maxDownloadBytes, !result.0.isEmpty
        else { return nil }
        return result.0
    }

    /// Decodes directly to a thumbnail; never materializes the full-size bitmap.
    static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated func clearMemory() {
        memory.removeAllObjects()
    }

    func clearAll() {
        memory.removeAllObjects()
        failures.removeAll()
        CacheDirectories.clear(directory)
    }

    func diskSize() -> Int64 {
        CacheDirectories.size(of: directory)
    }

    /// Evicts least-recently-modified files until the disk cache is under its limit.
    func trimDisk() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return
        }
        var entries = files.compactMap { url -> (URL, Date, Int64)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.totalFileAllocatedSize ?? 0))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.2 }
        guard total > Self.diskLimitBytes else { return }
        entries.sort { $0.1 < $1.1 }
        for entry in entries where total > Self.diskLimitBytes * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.2
        }
    }
}
