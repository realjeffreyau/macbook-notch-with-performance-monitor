import Foundation

/// Owns the Keep Awake session state machine.
///
/// While inactive it holds no power assertion, schedules no deadline, and
/// installs no observer, so the feature adds no wakeups. An active session
/// holds one idle-system-sleep assertion (plus an optional display
/// assertion), one wall-clock deadline when it has an end, and event-driven
/// power-source and wake observers. Remaining time is never published; UI
/// derives it from `endsAt` only while a countdown is visible.
///
/// Closed-lid mode is a separate backend. Its failure or absence changes only
/// `ClosedLidState`; the ordinary session keeps running.
@MainActor
final class KeepAwakeController {
    static let assertionName = "Dynamic Notch Keep Awake"
    /// Set before lid sleep is disabled and cleared after it is restored, so
    /// the next launch can undo an override left behind by a crash.
    static let closedLidMarkerKey = "keepAwake.closedLidEngaged"

    private(set) var status = KeepAwakeStatus.inactive {
        didSet {
            if status != oldValue {
                onStatusChange?(status)
            }
        }
    }

    var onStatusChange: (@MainActor (KeepAwakeStatus) -> Void)?

    private let assertions: any PowerAssertionBackend
    private let closedLid: any ClosedLidBackend
    private let powerSource: any PowerSourceMonitoring
    private let systemEvents: any KeepAwakeSystemEvents
    private let scheduler: any KeepAwakeScheduler
    private let defaults: UserDefaults

    private var options = KeepAwakeOptions()
    private var systemAssertion: UInt32?
    private var displayAssertion: UInt32?
    private var deadline: (any KeepAwakeCancellable)?
    private var isObserving = false
    private var lastSnapshot: PowerSourceSnapshot?
    private var isLidSleepDisabled = false
    private var closedLidFailure: String?

    init(
        assertions: any PowerAssertionBackend,
        closedLid: any ClosedLidBackend,
        powerSource: any PowerSourceMonitoring,
        systemEvents: any KeepAwakeSystemEvents,
        scheduler: any KeepAwakeScheduler,
        defaults: UserDefaults = .standard
    ) {
        self.assertions = assertions
        self.closedLid = closedLid
        self.powerSource = powerSource
        self.systemEvents = systemEvents
        self.scheduler = scheduler
        self.defaults = defaults
    }

    /// Restores lid-close sleep if a previous process exited while it was
    /// disabled. Sessions themselves never resume after relaunch.
    func recoverAfterUnexpectedExit() {
        guard defaults.bool(forKey: Self.closedLidMarkerKey) else { return }
        if closedLid.setLidSleepDisabled(false) {
            defaults.removeObject(forKey: Self.closedLidMarkerKey)
        }
    }

    /// Starts a session, replacing any active one. Returns false when the
    /// request was rejected or macOS refused the power assertion.
    @discardableResult
    func start(_ duration: KeepAwakeDuration, options: KeepAwakeOptions) -> Bool {
        let now = scheduler.now
        let endsAt = duration.deadline(from: now)
        if let endsAt, endsAt <= now {
            return false
        }

        let snapshot = powerSource.currentSnapshot()
        if snapshot.isBelowThreshold(options.lowBatteryThreshold) {
            tearDown()
            status = KeepAwakeStatus(session: nil, lastStopReason: .lowBattery)
            return false
        }

        // Replacement releases the previous assertions and deadline first so
        // two sessions never overlap. Lid state is reconciled below.
        releaseAssertionsAndDeadline()
        closedLidFailure = nil

        do {
            systemAssertion = try assertions.acquire(.preventIdleSystemSleep, name: Self.assertionName)
            if options.keepsDisplayAwake {
                displayAssertion = try assertions.acquire(.preventIdleDisplaySleep, name: Self.assertionName)
            }
        } catch {
            tearDown()
            status = KeepAwakeStatus(
                session: nil,
                lastStopReason: .failed("macOS didn’t allow Keep Awake (error \(error.code)).")
            )
            return false
        }

        if let endsAt {
            deadline = scheduler.schedule(at: endsAt) { [weak self] in
                self?.stop(reason: .expired)
            }
        }

        self.options = options
        startObserving()
        lastSnapshot = snapshot
        let lidState = reconcileClosedLid(snapshot: snapshot, reapply: true)
        status = KeepAwakeStatus(
            session: KeepAwakeActiveSession(
                duration: duration,
                startedAt: now,
                endsAt: endsAt,
                keepsDisplayAwake: displayAssertion != nil,
                closedLid: lidState
            ),
            lastStopReason: nil
        )
        return true
    }

    func stop(reason: KeepAwakeStopReason = .user) {
        guard status.isActive else { return }
        tearDown()
        status = KeepAwakeStatus(session: nil, lastStopReason: reason)
    }

    /// Applies changed Settings to a running session without restarting it.
    func updateOptions(_ newOptions: KeepAwakeOptions) {
        options = newOptions
        guard var session = status.session else { return }

        if newOptions.keepsDisplayAwake, displayAssertion == nil {
            // A display assertion failure leaves the system session intact.
            displayAssertion = try? assertions.acquire(.preventIdleDisplaySleep, name: Self.assertionName)
        } else if !newOptions.keepsDisplayAwake, let id = displayAssertion {
            assertions.release(id)
            displayAssertion = nil
        }

        let snapshot = powerSource.currentSnapshot()
        if snapshot.isBelowThreshold(newOptions.lowBatteryThreshold) {
            stop(reason: .lowBattery)
            return
        }
        session.keepsDisplayAwake = displayAssertion != nil
        session.closedLid = reconcileClosedLid(snapshot: snapshot, reapply: false)
        status.session = session
    }

    // MARK: - Events

    private func handlePowerSourceChange(_ snapshot: PowerSourceSnapshot) {
        guard status.isActive else { return }
        if snapshot.isBelowThreshold(options.lowBatteryThreshold) {
            stop(reason: .lowBattery)
            return
        }
        // powerd re-evaluates lid sleep on AC changes and may clear our
        // request, so re-apply only when the power source itself changed.
        let powerChanged = lastSnapshot?.isOnACPower != snapshot.isOnACPower
        lastSnapshot = snapshot
        updateClosedLid(snapshot: snapshot, reapply: powerChanged)
    }

    private func handleSystemEvent(_ event: KeepAwakeSystemEvent) {
        guard let session = status.session else { return }
        if event == .powerAssertionsChanged, !isLidSleepDisabled { return }
        if let endsAt = session.endsAt, endsAt <= scheduler.now {
            stop(reason: .expired)
            return
        }
        if event == .clockChanged, let endsAt = session.endsAt {
            deadline?.cancel()
            deadline = scheduler.schedule(at: endsAt) { [weak self] in
                self?.stop(reason: .expired)
            }
        }
        // On Apple silicon powerd clears the lid request after each wake, and
        // display changes can trigger its re-evaluation too.
        updateClosedLid(snapshot: powerSource.currentSnapshot(), reapply: true)
    }

    private func handleLidClosed(causesSleep: Bool) {
        guard causesSleep, isLidSleepDisabled, status.isActive else { return }
        // This flag describes kernel policy at notification time, not proof
        // that sleep already occurred. powerd may have cleared the shared
        // override. Reapply once per event instead of disabling the feature.
        updateClosedLid(snapshot: powerSource.currentSnapshot(), reapply: true)
    }

    // MARK: - Closed lid

    private func updateClosedLid(snapshot: PowerSourceSnapshot, reapply: Bool) {
        guard var session = status.session else { return }
        session.closedLid = reconcileClosedLid(snapshot: snapshot, reapply: reapply)
        status.session = session
    }

    private func reconcileClosedLid(snapshot: PowerSourceSnapshot, reapply: Bool) -> ClosedLidState {
        guard options.closedLidRequested else {
            restoreLidSleep()
            return .off
        }
        guard closedLid.isSupported else {
            restoreLidSleep()
            return .unavailable("This Mac doesn’t support closed-lid mode.")
        }
        if let closedLidFailure {
            restoreLidSleep()
            return .unavailable(closedLidFailure)
        }
        guard snapshot.isOnACPower || options.closedLidAllowedOnBattery else {
            restoreLidSleep()
            return .waitingForPower
        }
        if isLidSleepDisabled, !reapply {
            return .on
        }

        defaults.set(true, forKey: Self.closedLidMarkerKey)
        guard closedLid.setLidSleepDisabled(true) else {
            if isLidSleepDisabled {
                // If restoration also fails, preserve the launch marker so
                // an existing override is not forgotten after a failed retry.
                restoreLidSleep()
            } else {
                defaults.removeObject(forKey: Self.closedLidMarkerKey)
            }
            let reason = "macOS didn’t accept the request."
            closedLidFailure = reason
            return .unavailable(reason)
        }
        if !isLidSleepDisabled {
            closedLid.startObservingLidClose { [weak self] causesSleep in
                self?.handleLidClosed(causesSleep: causesSleep)
            }
        }
        isLidSleepDisabled = true
        return .on
    }

    private func restoreLidSleep() {
        guard isLidSleepDisabled else { return }
        closedLid.stopObservingLidClose()
        isLidSleepDisabled = false
        // Keep the marker if the restore failed so the next launch retries.
        if closedLid.setLidSleepDisabled(false) {
            defaults.removeObject(forKey: Self.closedLidMarkerKey)
        }
    }

    // MARK: - Resources

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        powerSource.start { [weak self] snapshot in
            self?.handlePowerSourceChange(snapshot)
        }
        systemEvents.start { [weak self] event in
            self?.handleSystemEvent(event)
        }
    }

    private func releaseAssertionsAndDeadline() {
        deadline?.cancel()
        deadline = nil
        if let id = displayAssertion {
            assertions.release(id)
            displayAssertion = nil
        }
        if let id = systemAssertion {
            assertions.release(id)
            systemAssertion = nil
        }
    }

    private func tearDown() {
        restoreLidSleep()
        releaseAssertionsAndDeadline()
        if isObserving {
            powerSource.stop()
            systemEvents.stop()
            isObserving = false
        }
        lastSnapshot = nil
        closedLidFailure = nil
    }
}
