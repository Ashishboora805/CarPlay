import Foundation
import SwiftData

// SwiftData models. All properties have defaults and there are no unique constraints so the
// schema stays compatible with CloudKit should iCloud sync be enabled later (see README).
// Secrets (playlist/EPG URLs, credentials) are NOT stored here; they live in the Keychain.

@Model
final class SourceEntity {
    var id: UUID = UUID()
    var name: String = ""
    /// Host only, for display ("iptv.example.com"). The full URL is in the Keychain.
    var displayHost: String = ""
    var refreshIntervalHours: Int = 24
    var isEnabled: Bool = true
    var sortOrder: Int = 0
    var createdAt: Date = Date.now
    var lastRefreshedAt: Date?
    var lastErrorMessage: String?
    var channelCount: Int = 0
    var usesInsecureConnection: Bool = false
    var hasCustomEPG: Bool = false

    init(id: UUID = UUID(), name: String, displayHost: String, refreshIntervalHours: Int,
         isEnabled: Bool, sortOrder: Int) {
        self.id = id
        self.name = name
        self.displayHost = displayHost
        self.refreshIntervalHours = refreshIntervalHours
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
    }
}

enum FavoriteKind: String, Codable, Sendable {
    case channel
    case category
}

@Model
final class FavoriteEntity {
    var id: UUID = UUID()
    var kindRaw: String = FavoriteKind.channel.rawValue
    /// ChannelID raw value or category name.
    var key: String = ""
    var title: String = ""
    var subtitle: String?
    var logoURLString: String?
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    var kind: FavoriteKind { FavoriteKind(rawValue: kindRaw) ?? .channel }

    init(kind: FavoriteKind, key: String, title: String, subtitle: String?, logoURLString: String?, sortOrder: Int) {
        self.kindRaw = kind.rawValue
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.logoURLString = logoURLString
        self.sortOrder = sortOrder
    }
}

@Model
final class HistoryEntity {
    var channelKey: String = ""
    var title: String = ""
    var groupName: String?
    var logoURLString: String?
    var sourceID: UUID?
    var lastWatchedAt: Date = Date.now

    init(channelKey: String, title: String, groupName: String?, logoURLString: String?, sourceID: UUID?) {
        self.channelKey = channelKey
        self.title = title
        self.groupName = groupName
        self.logoURLString = logoURLString
        self.sourceID = sourceID
    }
}

enum PersistenceFactory {
    static let schema = Schema([SourceEntity.self, FavoriteEntity.self, HistoryEntity.self])

    /// Creates the on-disk container, falling back to in-memory storage instead of crashing if
    /// the store can't be opened (e.g. disk full or a corrupted file).
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        if !inMemory {
            let configuration = ModelConfiguration("Lumen", schema: schema, isStoredInMemoryOnly: false,
                                                   allowsSave: true, cloudKitDatabase: .none)
            if let container = try? ModelContainer(for: schema, configurations: configuration) {
                return container
            }
        }
        let memory = ModelConfiguration("LumenMemory", schema: schema, isStoredInMemoryOnly: true,
                                        allowsSave: true, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: memory)
        } catch {
            // An in-memory store failing to open indicates a programming error in the schema.
            fatalError("Unable to create in-memory SwiftData container: \(error)")
        }
    }
}
