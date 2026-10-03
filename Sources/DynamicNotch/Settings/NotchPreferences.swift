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
        static let startAtLogin = "notch.startAtLogin"
        static let keepAwakeDurationPreset = "keepAwake.durationPreset"
        static let keepAwakeKeepsDisplayAwake = "keepAwake.keepsDisplayAwake"
        static let keepAwakeClosedLidEnabled = "keepAwake.closedLidEnabled"
        static let keepAwakeClosedLidAllowsBattery = "keepAwake.closedLidAllowsBattery"
        static let keepAwakeLowBatteryThreshold = "keepAwake.lowBatteryThreshold"
        static let keepAwakeLowPowerWithClosedLid = "keepAwake.lowPowerWithClosedLid"
    }

    static let defaultFileShelfMaximumItems = 8
    static let defaultKeepAwakeLowBatteryThreshold = 20
    /// Offered low-battery thresholds; 0 means never stop for battery.
    static let keepAwakeLowBatteryThresholds = [0, 10, 20, 30, 50]

    private let defaults: UserDefaults
    private var isRollingBackStartAtLogin = false

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

    /// Opt-in only. The app owner applies the native registration after this
    /// value changes and rejects the change if macOS cannot register it.
    var startAtLogin: Bool {
        didSet {
            if isRollingBackStartAtLogin {
                return
            }
            guard startAtLogin != oldValue else { return }
            if let onStartAtLoginChange,
               !onStartAtLoginChange(startAtLogin) {
                isRollingBackStartAtLogin = true
                startAtLogin = oldValue
                isRollingBackStartAtLogin = false
                return
            }
            defaults.set(startAtLogin, forKey: Key.startAtLogin)
            notifyChange()
        }
    }

    // Keep Awake configuration. Only configuration persists; an active
    // session never resumes after relaunch.

    var keepAwakeDurationPreset: KeepAwakeDurationPreset {
        didSet {
            defaults.set(keepAwakeDurationPreset.rawValue, forKey: Key.keepAwakeDurationPreset)
        }
    }

    /// Runtime status is observable but never persisted as proof of activation.
    var keepAwakeEnergyModeStatus = "Low Power Mode follows the closed-lid switch when this option is enabled."
    var energyHelperStatus = "Enable the energy helper once to avoid repeated password prompts."
    var onEnableEnergyHelper: (@MainActor () -> Void)?
    var onDisableEnergyHelper: (@MainActor () -> Void)?
    var onRefreshEnergyHelper: (@MainActor () -> Void)?

    var keepAwakeLowPowerWithClosedLid: Bool {
        didSet {
            defaults.set(keepAwakeLowPowerWithClosedLid, forKey: Key.keepAwakeLowPowerWithClosedLid)
            notifyKeepAwakeChange()
        }
    }

    var keepAwakeKeepsDisplayAwake: Bool {
        didSet {
            defaults.set(keepAwakeKeepsDisplayAwake, forKey: Key.keepAwakeKeepsDisplayAwake)
            notifyKeepAwakeChange()
        }
    }

    /// Explicit opt-in; off by default.
    var keepAwakeClosedLidEnabled: Bool {
        didSet {
            defaults.set(keepAwakeClosedLidEnabled, forKey: Key.keepAwakeClosedLidEnabled)
            notifyKeepAwakeChange()
        }
    }

    /// Separate deliberate opt-in; closed-lid mode is AC-only without it.
    var keepAwakeClosedLidAllowsBattery: Bool {
        didSet {
            defaults.set(keepAwakeClosedLidAllowsBattery, forKey: Key.keepAwakeClosedLidAllowsBattery)
            notifyKeepAwakeChange()
        }
    }

    /// Percent; 0 turns the low-battery stop off.
    var keepAwakeLowBatteryThreshold: Int {
        didSet {
            let boundedValue = Self.clampKeepAwakeLowBatteryThreshold(keepAwakeLowBatteryThreshold)
            if keepAwakeLowBatteryThreshold != boundedValue {
                keepAwakeLowBatteryThreshold = boundedValue
                return
            }
            defaults.set(keepAwakeLowBatteryThreshold, forKey: Key.keepAwakeLowBatteryThreshold)
            notifyKeepAwakeChange()
        }
    }

    var keepAwakeOptions: KeepAwakeOptions {
        KeepAwakeOptions(
            keepsDisplayAwake: keepAwakeKeepsDisplayAwake,
            closedLidRequested: keepAwakeClosedLidEnabled,
            closedLidAllowedOnBattery: keepAwakeClosedLidAllowsBattery,
            lowBatteryThreshold: keepAwakeLowBatteryThreshold > 0 ? keepAwakeLowBatteryThreshold : nil
        )
    }

    /// Lets a running Keep Awake session apply option changes immediately.
    var onKeepAwakeOptionsChange: (@MainActor (KeepAwakeOptions) -> Void)?

    /// Called by the owner of the notch controller after a persisted value
    /// changes. It is intentionally not persisted and is weakly captured by
    /// the controller, so closing Settings cannot affect notch presentation.
    var onChange: (@MainActor () -> Void)?

    /// Returns false when the native login-item registration could not be
    /// applied. It is separate from `onChange` so the notch controller does
    /// not need to own startup registration.
    var onStartAtLoginChange: (@MainActor (Bool) -> Bool)?

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
        startAtLogin = defaults.object(forKey: Key.startAtLogin) as? Bool ?? false

        keepAwakeDurationPreset = KeepAwakeDurationPreset(
            rawValue: defaults.string(forKey: Key.keepAwakeDurationPreset) ?? ""
        ) ?? .indefinitely
        keepAwakeKeepsDisplayAwake = defaults.object(forKey: Key.keepAwakeKeepsDisplayAwake) as? Bool ?? false
        keepAwakeLowPowerWithClosedLid = defaults.bool(forKey: Key.keepAwakeLowPowerWithClosedLid)
        keepAwakeClosedLidEnabled = defaults.object(forKey: Key.keepAwakeClosedLidEnabled) as? Bool ?? false
        keepAwakeClosedLidAllowsBattery = defaults.object(
            forKey: Key.keepAwakeClosedLidAllowsBattery
        ) as? Bool ?? false
        keepAwakeLowBatteryThreshold = Self.clampKeepAwakeLowBatteryThreshold(
            defaults.object(forKey: Key.keepAwakeLowBatteryThreshold) as? Int
                ?? Self.defaultKeepAwakeLowBatteryThreshold
        )
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

    static func clampKeepAwakeLowBatteryThreshold(_ value: Int) -> Int {
        min(max(value, 0), 95)
    }

    private func notifyChange() {
        onChange?()
    }

    /// Keep Awake values do not affect notch layout, so they skip `onChange`
    /// and its geometry refresh; SwiftUI observes them directly.
    private func notifyKeepAwakeChange() {
        onKeepAwakeOptionsChange?(keepAwakeOptions)
    }
}
