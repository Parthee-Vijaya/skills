import Foundation

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal, downloads, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideOriginal: return "Ved siden af originalen"
        case .downloads: return "Overførsler"
        case .custom: return "Valgt mappe"
        }
    }
}

/// User preferences. Backed by UserDefaults so engines on background threads can read them safely,
/// while SwiftUI views bind to the same keys with @AppStorage.
enum Prefs {
    enum Key {
        static let outputLocation = "outputLocation"
        static let customOutputPath = "customOutputPath"
        static let revealInFinder = "revealInFinder"
        static let imageQuality = "imageQuality"
        static let isPaused = "isPaused"
        static let ffmpegPath = "ffmpegPath"
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let playSound = "playSound"
        static let filesProcessed = "filesProcessed"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.outputLocation: OutputLocation.besideOriginal.rawValue,
            Key.customOutputPath: "",
            Key.revealInFinder: true,
            Key.imageQuality: 0.85,
            Key.isPaused: false,
            Key.ffmpegPath: "",
            Key.hasSeenOnboarding: false,
            Key.playSound: true,
            Key.filesProcessed: 0,
        ])
    }

    private static var defaults: UserDefaults { .standard }

    static var outputLocation: OutputLocation {
        OutputLocation(rawValue: defaults.string(forKey: Key.outputLocation) ?? "") ?? .besideOriginal
    }

    static var customOutputPath: String { defaults.string(forKey: Key.customOutputPath) ?? "" }
    static var revealInFinder: Bool { defaults.bool(forKey: Key.revealInFinder) }
    static var imageQuality: Double {
        let value = defaults.double(forKey: Key.imageQuality)
        return value > 0 ? min(value, 1) : 0.85
    }

    static var isPaused: Bool {
        get { defaults.bool(forKey: Key.isPaused) }
        set { defaults.set(newValue, forKey: Key.isPaused) }
    }

    static var ffmpegPath: String { defaults.string(forKey: Key.ffmpegPath) ?? "" }

    static var hasSeenOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasSeenOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasSeenOnboarding) }
    }

    static var playSound: Bool { defaults.bool(forKey: Key.playSound) }

    static func countProcessed(_ count: Int) {
        defaults.set(defaults.integer(forKey: Key.filesProcessed) + count, forKey: Key.filesProcessed)
    }
}
