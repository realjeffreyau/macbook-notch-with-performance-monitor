import Foundation

/// Actions exposed by the small menu-bar recovery surface.
///
/// This enum is deliberately independent from AppKit so the preference/action
/// contract remains testable without creating an `NSStatusItem` in a test
/// process.
enum MenuBarAction: Equatable, Sendable {
    case openOrExpandNotch
    case openSettings
    case toggleNotch
    case quit
}

enum MenuBarToggleState: Equatable, Sendable {
    case off
    case on
}

/// The menu's user-visible state derived from the persisted preference.
struct MenuBarMenuModel: Equatable, Sendable {
    let isNotchEnabled: Bool

    var openOrExpandTitle: String {
        "Open / Expand Notch"
    }

    var openOrExpandEnabled: Bool {
        isNotchEnabled
    }

    var toggleTitle: String {
        isNotchEnabled ? "Disable Dynamic Notch" : "Enable Dynamic Notch"
    }

    var toggleState: MenuBarToggleState {
        isNotchEnabled ? .on : .off
    }

    static func current(isNotchEnabled: Bool) -> Self {
        Self(isNotchEnabled: isNotchEnabled)
    }

    /// Applies the only menu action that changes persisted state.
    static func nextNotchEnabledValue(
        after action: MenuBarAction,
        currentValue: Bool
    ) -> Bool {
        action == .toggleNotch ? !currentValue : currentValue
    }
}

/// The Keep Awake part of the status-item menu. Built when the menu opens,
/// so it shows a static end time and never runs a countdown.
struct KeepAwakeMenuModel: Equatable, Sendable {
    let statusTitle: String
    let detailLines: [String]
    let isActive: Bool
    let toggleTitle: String
    /// The running preset, checkmarked like the notch page highlights it.
    let selectedPreset: KeepAwakeDurationPreset?
    let isUntilTimeSelected: Bool

    static func make(
        status: KeepAwakeStatus,
        defaultPreset: KeepAwakeDurationPreset,
        now: Date,
        presentation: KeepAwakePresentation = KeepAwakePresentation()
    ) -> Self {
        Self(
            statusTitle: presentation.statusTitle(for: status, now: now),
            detailLines: presentation.detailLines(for: status),
            isActive: status.isActive,
            toggleTitle: status.isActive
                ? "Stop Keep Awake"
                : "Start Keep Awake (\(defaultPreset.title))",
            selectedPreset: KeepAwakeDurationPreset.allCases.first {
                $0.duration == status.session?.duration
            },
            isUntilTimeSelected: {
                if case .until = status.session?.duration { return true }
                return false
            }()
        )
    }
}
