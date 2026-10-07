import Foundation

enum CacheDirectories {
    /// Channel metadata. Lives in Application Support (not Caches) so the app opens with
    /// channels even after iOS purges caches under storage pressure. Excluded from backups.
    static let channels: URL = make(base: .applicationSupportDirectory, name: "Channels")
    /// EPG cache, safe for the system to purge.
    static let epg: URL = make(base: .cachesDirectory, name: "EPG")
    static let logos: URL = make(base: .cachesDirectory, name: "Logos")

    private static func make(base: FileManager.SearchPathDirectory, name: String) -> URL {
        let root = FileManager.default.urls(for: base, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Total allocated size of all files in `directory`.
    static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func clear(_ directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents { try? FileManager.default.removeItem(at: url) }
    }
}

extension Data.WritingOptions {
    /// Readable after first unlock so CarPlay can start while the phone stays locked.
    static let lumenCache: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
}
