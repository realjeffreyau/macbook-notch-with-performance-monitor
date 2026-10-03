import Foundation

/// Injection seams for Keep Awake. The controller owns all policy; these
/// protocols only touch the system, so tests replace every one of them and
/// never create a real assertion or change lid-sleep state.

enum PowerAssertionKind: Equatable, Sendable {
    /// Prevents idle system sleep; the display may still sleep.
    case preventIdleSystemSleep
    /// Prevents idle display sleep.
    case preventIdleDisplaySleep
}

struct PowerAssertionError: Error, Equatable, Sendable {
    let code: Int32
}

@MainActor
protocol PowerAssertionBackend: AnyObject {
    /// Returns an identifier that must be passed back to `release` exactly once.
    func acquire(_ kind: PowerAssertionKind, name: String) throws(PowerAssertionError) -> UInt32
    func release(_ id: UInt32)
}

/// Lid-close sleep control, kept apart from ordinary assertions so missing
/// support never affects a normal session.
@MainActor
protocol ClosedLidBackend: AnyObject {
    /// False on Macs without a lid or when the system interface is missing.
    var isSupported: Bool { get }
    /// Returns false when macOS rejected the request.
    func setLidSleepDisabled(_ disabled: Bool) -> Bool
    /// Delivers `causesSleep` each time the lid closes while observing.
    func startObservingLidClose(_ handler: @escaping @MainActor (_ causesSleep: Bool) -> Void)
    func stopObservingLidClose()
}

@MainActor
protocol PowerSourceMonitoring: AnyObject {
    func currentSnapshot() -> PowerSourceSnapshot
    /// Event-driven: installs an OS notification source; no polling.
    func start(_ handler: @escaping @MainActor (PowerSourceSnapshot) -> Void)
    func stop()
}

enum KeepAwakeSystemEvent: Equatable, Sendable {
    case didWake
    case displaysChanged
    case clockChanged
    case powerAssertionsChanged
}

@MainActor
protocol KeepAwakeSystemEvents: AnyObject {
    func start(_ handler: @escaping @MainActor (KeepAwakeSystemEvent) -> Void)
    func stop()
}

@MainActor
protocol KeepAwakeCancellable: AnyObject {
    func cancel()
}

@MainActor
protocol KeepAwakeScheduler: AnyObject {
    var now: Date { get }
    /// Schedules one wall-clock deadline. The handler runs on the main actor.
    func schedule(at date: Date, _ handler: @escaping @MainActor () -> Void) -> any KeepAwakeCancellable
}
