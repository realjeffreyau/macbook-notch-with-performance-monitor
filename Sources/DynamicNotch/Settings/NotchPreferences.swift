import Foundation
import Observation

enum NotchMotionPreference: String, CaseIterable, Identifiable, Sendable {
    case followSystem
    case reduceMotion
    case animate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followSystem: "Follow System"
        case .reduceMotion: "Reduce Motion"
        case .animate: "Animate"
        }
    }
}

/// User-controlled behavior for the notch and its local expanded pages.
///
/// The object is main-actor isolated because it is shared by AppKit lifecycle
/// code and SwiftUI bindings. Each mutation is one synchronous UserDefaults
/// write; it never starts background work or a refresh loop.
@MainActor
@Observable
final class NotchPreferences {
    enum Key {
        static let isNotchEnabled = "notch.enabled"
        static let motionPreference = "notch.motionPreference"
        static let showCollapsedMediaIndicators = "notch.showCollapsedMediaIndicators"
        static let showArtwork = "notch.showArtwork"
        static let showOutputDevice = "notch.showOutputDevice"
        static let showPrivacyIndicators = "notch.showPrivacyIndicators"
        static let systemStatsEnabled = "notch.systemStatsEnabled"
        static let fileShelfEnabled = "notch.fileShelfEnabled"
        static let fileShelfMaximumItems = "notch.fileShelfMaximumItems"
        static let showResourceDiagnostics = "notch.showResourceDiagnostics"
    }

    static let defaultFileShelfMaximumItems = 8

    private let defaults: UserDefaults

    var isNotchEnabled: Bool {
        didSet {
            defaults.set(isNotchEnabled, forKey: Key.isNotchEnabled)
            notifyChange()
        }
    }

    var motionPreference: NotchMotionPreference {
        didSet {
            defaults.set(motionPreference.rawValue, forKey: Key.motionPreference)
            notifyChange()
        }
    }

    var showCollapsedMediaIndicators: Bool {
        didSet {
            defaults.set(showCollapsedMediaIndicators, forKey: Key.showCollapsedMediaIndicators)
            notifyChange()
        }
    }

    var showArtwork: Bool {
        didSet {
            defaults.set(showArtwork, forKey: Key.showArtwork)
            notifyChange()
        }
    }

    var showOutputDevice: Bool {
        didSet {
            defaults.set(showOutputDevice, forKey: Key.showOutputDevice)
            notifyChange()
        }
    }

    var showPrivacyIndicators: Bool {
        didSet {
            defaults.set(showPrivacyIndicators, forKey: Key.showPrivacyIndicators)
            notifyChange()
        }
    }

    var systemStatsEnabled: Bool {
        didSet {
            defaults.set(systemStatsEnabled, forKey: Key.systemStatsEnabled)
            notifyChange()
        }
    }

    var fileShelfEnabled: Bool {
        didSet {
            defaults.set(fileShelfEnabled, forKey: Key.fileShelfEnabled)
            notifyChange()
        }
    }

    var fileShelfMaximumItems: Int {
        didSet {
            let boundedValue = Self.clampFileShelfMaximumItems(fileShelfMaximumItems)
            if fileShelfMaximumItems != boundedValue {
                fileShelfMaximumItems = boundedValue
                return
            }
            defaults.set(fileShelfMaximumItems, forKey: Key.fileShelfMaximumItems)
            notifyChange()
        }
    }

    var showResourceDiagnostics: Bool {
        didSet {
            defaults.set(showResourceDiagnostics, forKey: Key.showResourceDiagnostics)
            notifyChange()
        }
    }

    /// Called by the owner of the notch controller after a persisted value
    /// changes. It is intentionally not persisted and is weakly captured by
    /// the controller, so closing Settings cannot affect notch presentation.
    var onChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isNotchEnabled = defaults.object(forKey: Key.isNotchEnabled) as? Bool ?? true

        let storedMotion = defaults.string(forKey: Key.motionPreference)
        motionPreference = NotchMotionPreference(rawValue: storedMotion ?? "") ?? .followSystem

        showCollapsedMediaIndicators = defaults.object(
            forKey: Key.showCollapsedMediaIndicators
        ) as? Bool ?? true
        showArtwork = defaults.object(forKey: Key.showArtwork) as? Bool ?? true
        showOutputDevice = defaults.object(forKey: Key.showOutputDevice) as? Bool ?? true
        showPrivacyIndicators = defaults.object(forKey: Key.showPrivacyIndicators) as? Bool ?? true
        systemStatsEnabled = defaults.object(forKey: Key.systemStatsEnabled) as? Bool ?? true
        fileShelfEnabled = defaults.object(forKey: Key.fileShelfEnabled) as? Bool ?? true

        let storedMaximum = defaults.object(forKey: Key.fileShelfMaximumItems) as? Int
        fileShelfMaximumItems = Self.clampFileShelfMaximumItems(
            storedMaximum ?? Self.defaultFileShelfMaximumItems
        )
        showResourceDiagnostics = defaults.object(
            forKey: Key.showResourceDiagnostics
        ) as? Bool ?? false
    }

    func shouldReduceMotion(systemValue: Bool) -> Bool {
        switch motionPreference {
        case .followSystem: systemValue
        case .reduceMotion: true
        case .animate: false
        }
    }

    static func clampFileShelfMaximumItems(_ value: Int) -> Int {
        min(max(value, 1), FileShelfLimits.maximumItemCount)
    }

    private func notifyChange() {
        onChange?()
    }
}
