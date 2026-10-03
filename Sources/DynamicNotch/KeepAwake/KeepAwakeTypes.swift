import Foundation

/// How long a Keep Awake session should last.
enum KeepAwakeDuration: Equatable, Sendable {
    case indefinitely
    case interval(TimeInterval)
    case until(Date)

    /// The wall-clock end of a session started at `now`, or nil when the
    /// session has no end. Callers reject an `until` date that has passed.
    func deadline(from now: Date) -> Date? {
        switch self {
        case .indefinitely: nil
        case .interval(let seconds): now.addingTimeInterval(seconds)
        case .until(let date): date
        }
    }
}

/// Fixed choices offered by the menu, notch control, and Settings.
enum KeepAwakeDurationPreset: String, CaseIterable, Identifiable, Sendable {
    case indefinitely
    case minutes5
    case minutes15
    case minutes30
    case minutes45
    case hour1
    case hours2

    var id: String { rawValue }

    /// Short chip label for the notch page.
    var shortTitle: String {
        switch self {
        case .indefinitely: "Indefinitely"
        case .minutes5: "5 min"
        case .minutes15: "15 min"
        case .minutes30: "30 min"
        case .minutes45: "45 min"
        case .hour1: "1 hr"
        case .hours2: "2 hr"
        }
    }

    var title: String {
        switch self {
        case .indefinitely: "Indefinitely"
        case .minutes5: "5 Minutes"
        case .minutes15: "15 Minutes"
        case .minutes30: "30 Minutes"
        case .minutes45: "45 Minutes"
        case .hour1: "1 Hour"
        case .hours2: "2 Hours"
        }
    }

    var duration: KeepAwakeDuration {
        switch self {
        case .indefinitely: .indefinitely
        case .minutes5: .interval(5 * 60)
        case .minutes15: .interval(15 * 60)
        case .minutes30: .interval(30 * 60)
        case .minutes45: .interval(45 * 60)
        case .hour1: .interval(60 * 60)
        case .hours2: .interval(2 * 60 * 60)
        }
    }
}

/// Session options that may change while a session runs.
struct KeepAwakeOptions: Equatable, Sendable {
    var keepsDisplayAwake = false
    /// The user opted in to keeping the Mac awake with the lid closed.
    var closedLidRequested = false
    /// Separate, deliberate opt-in. Closed-lid mode is AC-only without it.
    var closedLidAllowedOnBattery = false
    /// Stop when running on battery at or below this percentage. Nil = never.
    var lowBatteryThreshold: Int? = 20
}

enum KeepAwakeStopReason: Equatable, Sendable {
    case user
    case expired
    case lowBattery
    case failed(String)
}

/// The closed-lid part of a session. Only `.on` means macOS accepted the
/// request; every other case leaves ordinary lid-close sleep in place.
enum ClosedLidState: Equatable, Sendable {
    case off
    case on
    /// Requested, but AC-only and the Mac is on battery.
    case waitingForPower
    case unavailable(String)

    var isEngaged: Bool { self == .on }
}

struct KeepAwakeActiveSession: Equatable, Sendable {
    /// What the user chose, so every surface can highlight the same option.
    let duration: KeepAwakeDuration
    let startedAt: Date
    let endsAt: Date?
    var keepsDisplayAwake: Bool
    var closedLid: ClosedLidState
}

/// The only Keep Awake value published to UI. It changes on session events,
/// never once per second; views derive remaining time from `endsAt`.
struct KeepAwakeStatus: Equatable, Sendable {
    var session: KeepAwakeActiveSession?
    var lastStopReason: KeepAwakeStopReason?

    var isActive: Bool { session != nil }

    static let inactive = KeepAwakeStatus(session: nil, lastStopReason: nil)
}

/// Power-source facts used for the AC-only and low-battery policies.
struct PowerSourceSnapshot: Equatable, Sendable {
    var isOnACPower: Bool
    /// Battery charge in percent, or nil on a Mac without a battery.
    var batteryPercent: Int?

    static let acWithoutBattery = PowerSourceSnapshot(isOnACPower: true, batteryPercent: nil)

    func isBelowThreshold(_ threshold: Int?) -> Bool {
        guard let threshold, !isOnACPower, let batteryPercent else { return false }
        return batteryPercent <= threshold
    }
}
