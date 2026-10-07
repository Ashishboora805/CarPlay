import Foundation
import LumenKit
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case blue, teal, indigo, orange, pink, green
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .blue: Color(red: 0.29, green: 0.59, blue: 0.98)
        case .teal: Color(red: 0.19, green: 0.73, blue: 0.75)
        case .indigo: Color(red: 0.42, green: 0.42, blue: 0.95)
        case .orange: Color(red: 1.0, green: 0.58, blue: 0.2)
        case .pink: Color(red: 0.97, green: 0.36, blue: 0.56)
        case .green: Color(red: 0.25, green: 0.78, blue: 0.43)
        }
    }
}

enum PlaybackQuality: String, CaseIterable, Identifiable, Sendable {
    case automatic, dataSaver, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .dataSaver: "Data Saver"
        case .high: "Highest"
        }
    }
    var detail: String {
        switch self {
        case .automatic: "Adapts to your connection. Limits bitrate on cellular and in Low Data Mode."
        case .dataSaver: "Caps streams at about 1.5 Mbps."
        case .high: "Always picks the best available variant."
        }
    }
}

/// Small user preferences backed by UserDefaults. Nothing sensitive is stored here.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var autoPlayLastChannel: Bool { didSet { defaults.set(autoPlayLastChannel, forKey: Keys.autoPlay) } }
    var quality: PlaybackQuality { didSet { defaults.set(quality.rawValue, forKey: Keys.quality) } }
    var subtitlesEnabled: Bool { didSet { defaults.set(subtitlesEnabled, forKey: Keys.subtitles) } }
    /// BCP-47 language prefix (e.g. "en"); empty means "device default".
    var preferredAudioLanguage: String { didSet { defaults.set(preferredAudioLanguage, forKey: Keys.audioLanguage) } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: Keys.accent) } }
    var searchEngine: SearchEngine { didSet { defaults.set(searchEngine.rawValue, forKey: Keys.searchEngine) } }
    /// Empty means "use the search engine's home page".
    var browserHomepage: String { didSet { defaults.set(browserHomepage, forKey: Keys.homepage) } }
    var epgRefreshHours: Int { didSet { defaults.set(epgRefreshHours, forKey: Keys.epgRefresh) } }
    var carPlayShowsRecents: Bool { didSet { defaults.set(carPlayShowsRecents, forKey: Keys.carPlayRecents) } }
    var carPlayShowsCategories: Bool { didSet { defaults.set(carPlayShowsCategories, forKey: Keys.carPlayCategories) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.autoPlay: false,
            Keys.quality: PlaybackQuality.automatic.rawValue,
            Keys.subtitles: false,
            Keys.audioLanguage: "",
            Keys.appearance: AppearanceMode.dark.rawValue,
            Keys.accent: AccentChoice.blue.rawValue,
            Keys.searchEngine: SearchEngine.google.rawValue,
            Keys.homepage: "",
            Keys.epgRefresh: 12,
            Keys.carPlayRecents: true,
            Keys.carPlayCategories: true
        ])
        autoPlayLastChannel = defaults.bool(forKey: Keys.autoPlay)
        quality = PlaybackQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .automatic
        subtitlesEnabled = defaults.bool(forKey: Keys.subtitles)
        preferredAudioLanguage = defaults.string(forKey: Keys.audioLanguage) ?? ""
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        accent = AccentChoice(rawValue: defaults.string(forKey: Keys.accent) ?? "") ?? .blue
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .google
        browserHomepage = defaults.string(forKey: Keys.homepage) ?? ""
        epgRefreshHours = max(1, defaults.integer(forKey: Keys.epgRefresh))
        carPlayShowsRecents = defaults.bool(forKey: Keys.carPlayRecents)
        carPlayShowsCategories = defaults.bool(forKey: Keys.carPlayCategories)
    }

    var homepageURL: URL {
        if let url = URLValidator.userURL(from: browserHomepage) { return url }
        return searchEngine.homeURL
    }

    enum Keys {
        static let autoPlay = "playback.autoPlay"
        static let quality = "playback.quality"
        static let subtitles = "playback.subtitles"
        static let audioLanguage = "playback.audioLanguage"
        static let appearance = "appearance.mode"
        static let accent = "appearance.accent"
        static let searchEngine = "browser.searchEngine"
        static let homepage = "browser.homepage"
        static let epgRefresh = "iptv.epgRefreshHours"
        static let carPlayRecents = "carplay.showRecents"
        static let carPlayCategories = "carplay.showCategories"
        static let browserTabs = "browser.tabs"
        static let youtubeRecents = "youtube.recents"
    }
}
