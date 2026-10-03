import Foundation
import Testing
@testable import DynamicNotch

// MARK: - Fakes (no real assertions, lid state, or observers)

@MainActor
private final class FakeAssertions: PowerAssertionBackend {
    var live: [UInt32: PowerAssertionKind] = [:]
    var failingKinds: Set<String> = []
    var releaseCount = 0
    private var nextID: UInt32 = 1

    func acquire(_ kind: PowerAssertionKind, name: String) throws(PowerAssertionError) -> UInt32 {
        if failingKinds.contains("\(kind)") {
            throw PowerAssertionError(code: -536_870_212)
        }
        let id = nextID
        nextID += 1
        live[id] = kind
        return id
    }

    func release(_ id: UInt32) {
        #expect(live[id] != nil, "released an unknown or already released assertion")
        live[id] = nil
        releaseCount += 1
    }

    func count(_ kind: PowerAssertionKind) -> Int {
        live.values.filter { $0 == kind }.count
    }
}

@MainActor
private final class FakeClosedLid: ClosedLidBackend {
    var isSupported = true
    var acceptsRequests = true
    var writes: [Bool] = []
    var lidCloseHandler: (@MainActor (Bool) -> Void)?

    var isObserving: Bool { lidCloseHandler != nil }
    var isDisabledNow: Bool { writes.last ?? false }

    func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        guard acceptsRequests else { return false }
        writes.append(disabled)
        return true
    }

    func startObservingLidClose(_ handler: @escaping @MainActor (Bool) -> Void) {
        lidCloseHandler = handler
    }

    func stopObservingLidClose() {
        lidCloseHandler = nil
    }
}

@MainActor
private final class FakePowerSource: PowerSourceMonitoring {
    var snapshot = PowerSourceSnapshot(isOnACPower: true, batteryPercent: 80)
    var handler: (@MainActor (PowerSourceSnapshot) -> Void)?

    var isRunning: Bool { handler != nil }

    func currentSnapshot() -> PowerSourceSnapshot { snapshot }
    func start(_ handler: @escaping @MainActor (PowerSourceSnapshot) -> Void) { self.handler = handler }
    func stop() { handler = nil }

    func change(_ newSnapshot: PowerSourceSnapshot) {
        snapshot = newSnapshot
        handler?(newSnapshot)
    }
}

@MainActor
private final class FakeSystemEvents: KeepAwakeSystemEvents {
    var handler: (@MainActor (KeepAwakeSystemEvent) -> Void)?
    var isRunning: Bool { handler != nil }

    func start(_ handler: @escaping @MainActor (KeepAwakeSystemEvent) -> Void) { self.handler = handler }
    func stop() { handler = nil }
    func send(_ event: KeepAwakeSystemEvent) { handler?(event) }
}

@MainActor
private final class FakeDeadline: KeepAwakeCancellable {
    let date: Date
    let handler: @MainActor () -> Void
    var isCancelled = false

    init(date: Date, handler: @escaping @MainActor () -> Void) {
        self.date = date
        self.handler = handler
    }

    func cancel() { isCancelled = true }
}

@MainActor
private final class FakeScheduler: KeepAwakeScheduler {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var deadlines: [FakeDeadline] = []

    var pending: [FakeDeadline] { deadlines.filter { !$0.isCancelled } }

    func schedule(at date: Date, _ handler: @escaping @MainActor () -> Void) -> any KeepAwakeCancellable {
        let deadline = FakeDeadline(date: date, handler: handler)
        deadlines.append(deadline)
        return deadline
    }

    /// Advances the clock and fires any due, uncancelled deadline once.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for deadline in pending where deadline.date <= now {
            deadline.isCancelled = true
            deadline.handler()
        }
    }
}

@MainActor
private struct Harness {
    let assertions = FakeAssertions()
    let lid = FakeClosedLid()
    let power = FakePowerSource()
    let events = FakeSystemEvents()
    let scheduler = FakeScheduler()
    let suiteName = "KeepAwakeTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let controller: KeepAwakeController

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        controller = KeepAwakeController(
            assertions: assertions,
            closedLid: lid,
            powerSource: power,
            systemEvents: events,
            scheduler: scheduler,
            defaults: defaults
        )
    }

    var marker: Bool { defaults.bool(forKey: KeepAwakeController.closedLidMarkerKey) }

    /// Inactive means no held assertion, deadline, observer, or lid override.
    func expectFullyIdle() {
        #expect(assertions.live.isEmpty)
        #expect(scheduler.pending.isEmpty)
        #expect(!power.isRunning)
        #expect(!events.isRunning)
        #expect(!lid.isDisabledNow)
        #expect(!lid.isObserving)
        #expect(!marker)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private let closedLidOptions = KeepAwakeOptions(closedLidRequested: true)

// MARK: - Session transitions

@Test("keep awake starts inactive and holds nothing")
@MainActor
func keepAwakeStartsInactive() {
    let h = Harness()
    defer { h.cleanUp() }
    #expect(h.controller.status == .inactive)
    h.expectFullyIdle()
}

@Test("indefinite session holds one system assertion and no deadline")
@MainActor
func indefiniteSessionHoldsSystemAssertionOnly() {
    let h = Harness()
    defer { h.cleanUp() }
    var published: [KeepAwakeStatus] = []
    h.controller.onStatusChange = { published.append($0) }

    #expect(h.controller.start(.indefinitely, options: KeepAwakeOptions()))

    #expect(h.assertions.count(.preventIdleSystemSleep) == 1)
    #expect(h.assertions.count(.preventIdleDisplaySleep) == 0)
    #expect(h.scheduler.deadlines.isEmpty)
    #expect(h.power.isRunning && h.events.isRunning)
    let session = h.controller.status.session
    #expect(session?.endsAt == nil)
    #expect(session?.keepsDisplayAwake == false)
    #expect(session?.closedLid == .off)
    #expect(published.count == 1)
}

@Test("display option adds a separate display assertion")
@MainActor
func displayOptionAddsDisplayAssertion() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.indefinitely, options: KeepAwakeOptions(keepsDisplayAwake: true))
    #expect(h.assertions.count(.preventIdleSystemSleep) == 1)
    #expect(h.assertions.count(.preventIdleDisplaySleep) == 1)
    #expect(h.controller.status.session?.keepsDisplayAwake == true)
}

@Test("stop releases everything and is idempotent")
@MainActor
func stopReleasesEverything() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.interval(600), options: KeepAwakeOptions(keepsDisplayAwake: true))
    h.controller.stop()
    h.controller.stop()

    #expect(h.controller.status == KeepAwakeStatus(session: nil, lastStopReason: .user))
    #expect(h.assertions.releaseCount == 2)
    h.expectFullyIdle()
}

@Test("timed session expires once from its single deadline")
@MainActor
func timedSessionExpires() {
    let h = Harness()
    defer { h.cleanUp() }
    let start = h.scheduler.now
    h.controller.start(.interval(15 * 60), options: KeepAwakeOptions())

    #expect(h.scheduler.deadlines.count == 1)
    #expect(h.controller.status.session?.endsAt == start.addingTimeInterval(15 * 60))

    h.scheduler.advance(by: 15 * 60 - 1)
    #expect(h.controller.status.isActive)
    h.scheduler.advance(by: 1)

    #expect(h.controller.status.lastStopReason == .expired)
    h.expectFullyIdle()
}

@Test("until-time session uses the chosen end time and rejects the past")
@MainActor
func untilTimeSession() {
    let h = Harness()
    defer { h.cleanUp() }
    let end = h.scheduler.now.addingTimeInterval(3600)

    #expect(!h.controller.start(.until(h.scheduler.now), options: KeepAwakeOptions()))
    #expect(h.controller.status == .inactive)
    h.expectFullyIdle()

    #expect(h.controller.start(.until(end), options: KeepAwakeOptions()))
    #expect(h.controller.status.session?.endsAt == end)
    #expect(h.controller.status.session?.duration == .until(end))
    #expect(h.scheduler.pending.first?.date == end)
}

@Test("waking after the deadline ends the session immediately")
@MainActor
func wakeAfterDeadlineExpires() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.interval(60), options: KeepAwakeOptions())
    h.scheduler.now = h.scheduler.now.addingTimeInterval(120) // slept past it
    h.events.send(.didWake)

    #expect(h.controller.status.lastStopReason == .expired)
    h.expectFullyIdle()
}

@Test("clock change reschedules the one deadline")
@MainActor
func clockChangeReschedules() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.interval(600), options: KeepAwakeOptions())
    h.events.send(.clockChanged)
    #expect(h.scheduler.pending.count == 1)
    #expect(h.scheduler.deadlines.count == 2)
}

// MARK: - Replacement

@Test("replacing a session never leaves two sessions or leaked assertions")
@MainActor
func replacementReleasesPreviousSession() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.interval(600), options: KeepAwakeOptions(keepsDisplayAwake: true))
    let firstDeadline = h.scheduler.deadlines[0]

    h.controller.start(.interval(1200), options: KeepAwakeOptions())

    #expect(firstDeadline.isCancelled)
    #expect(h.scheduler.pending.count == 1)
    #expect(h.assertions.live.count == 1)
    #expect(h.assertions.count(.preventIdleSystemSleep) == 1)
    #expect(h.controller.status.session?.keepsDisplayAwake == false)

    // The old deadline must not end the new session.
    h.scheduler.advance(by: 600)
    #expect(h.controller.status.isActive)
}

@Test("repeated start and stop cycles leave nothing behind")
@MainActor
func repeatedCyclesDoNotLeak() {
    let h = Harness()
    defer { h.cleanUp() }
    for index in 0..<50 {
        let options = KeepAwakeOptions(keepsDisplayAwake: index.isMultiple(of: 2), closedLidRequested: true)
        h.controller.start(index.isMultiple(of: 3) ? .indefinitely : .interval(60), options: options)
        if index.isMultiple(of: 5) {
            h.controller.start(.interval(30), options: options)
        }
        h.controller.stop()
    }
    h.expectFullyIdle()
}

// MARK: - Assertion failures

@Test("system assertion failure reports a failure and holds nothing")
@MainActor
func systemAssertionFailure() {
    let h = Harness()
    defer { h.cleanUp() }
    h.assertions.failingKinds = ["\(PowerAssertionKind.preventIdleSystemSleep)"]

    #expect(!h.controller.start(.interval(60), options: closedLidOptions))

    guard case .failed = h.controller.status.lastStopReason else {
        Issue.record("expected a failure reason")
        return
    }
    #expect(!h.controller.status.isActive)
    h.expectFullyIdle()
}

@Test("display assertion failure releases the system assertion too")
@MainActor
func displayAssertionFailureCleansUp() {
    let h = Harness()
    defer { h.cleanUp() }
    h.assertions.failingKinds = ["\(PowerAssertionKind.preventIdleDisplaySleep)"]

    #expect(!h.controller.start(.interval(60), options: KeepAwakeOptions(keepsDisplayAwake: true)))
    #expect(h.assertions.releaseCount == 1)
    h.expectFullyIdle()
}

@Test("failed replacement ends the previous session cleanly")
@MainActor
func failedReplacementCleansUp() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.interval(600), options: closedLidOptions)
    #expect(h.lid.isDisabledNow)

    h.assertions.failingKinds = ["\(PowerAssertionKind.preventIdleSystemSleep)"]
    #expect(!h.controller.start(.interval(60), options: closedLidOptions))
    h.expectFullyIdle()
}

@Test("display toggle during a session changes only the display assertion")
@MainActor
func updateOptionsTogglesDisplay() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.indefinitely, options: KeepAwakeOptions())
    h.controller.updateOptions(KeepAwakeOptions(keepsDisplayAwake: true))
    #expect(h.assertions.count(.preventIdleDisplaySleep) == 1)
    #expect(h.controller.status.session?.keepsDisplayAwake == true)

    h.controller.updateOptions(KeepAwakeOptions(keepsDisplayAwake: false))
    #expect(h.assertions.count(.preventIdleDisplaySleep) == 0)
    #expect(h.assertions.count(.preventIdleSystemSleep) == 1)

    h.assertions.failingKinds = ["\(PowerAssertionKind.preventIdleDisplaySleep)"]
    h.controller.updateOptions(KeepAwakeOptions(keepsDisplayAwake: true))
    #expect(h.controller.status.isActive)
    #expect(h.controller.status.session?.keepsDisplayAwake == false)
}

// MARK: - Low battery

@Test("low battery on battery power stops the session")
@MainActor
func lowBatteryStopsSession() {
    let h = Harness()
    defer { h.cleanUp() }
    h.power.snapshot = PowerSourceSnapshot(isOnACPower: false, batteryPercent: 50)
    h.controller.start(.indefinitely, options: KeepAwakeOptions(lowBatteryThreshold: 20))

    h.power.change(PowerSourceSnapshot(isOnACPower: false, batteryPercent: 21))
    #expect(h.controller.status.isActive)
    h.power.change(PowerSourceSnapshot(isOnACPower: false, batteryPercent: 20))

    #expect(h.controller.status.lastStopReason == .lowBattery)
    h.expectFullyIdle()
}

@Test("low battery refuses to start and AC power or no threshold never stops")
@MainActor
func lowBatteryPolicyEdges() {
    let h = Harness()
    defer { h.cleanUp() }
    h.power.snapshot = PowerSourceSnapshot(isOnACPower: false, batteryPercent: 10)
    #expect(!h.controller.start(.indefinitely, options: KeepAwakeOptions(lowBatteryThreshold: 20)))
    #expect(h.controller.status.lastStopReason == .lowBattery)
    h.expectFullyIdle()

    h.power.snapshot = PowerSourceSnapshot(isOnACPower: true, batteryPercent: 10)
    #expect(h.controller.start(.indefinitely, options: KeepAwakeOptions(lowBatteryThreshold: 20)))
    h.power.change(PowerSourceSnapshot(isOnACPower: true, batteryPercent: 5))
    #expect(h.controller.status.isActive)

    h.controller.updateOptions(KeepAwakeOptions(lowBatteryThreshold: nil))
    h.power.change(PowerSourceSnapshot(isOnACPower: false, batteryPercent: 5))
    #expect(h.controller.status.isActive)

    #expect(!PowerSourceSnapshot.acWithoutBattery.isBelowThreshold(100))
}

// MARK: - Closed lid

@Test("unsupported closed-lid mode leaves the normal session running")
@MainActor
func unsupportedClosedLid() {
    let h = Harness()
    defer { h.cleanUp() }
    h.lid.isSupported = false

    #expect(h.controller.start(.indefinitely, options: closedLidOptions))

    #expect(h.controller.status.isActive)
    #expect(h.assertions.count(.preventIdleSystemSleep) == 1)
    guard case .unavailable = h.controller.status.session?.closedLid else {
        Issue.record("expected unavailable")
        return
    }
    #expect(h.lid.writes.isEmpty)
    #expect(!h.marker)
}

@Test("rejected closed-lid request is never shown as on")
@MainActor
func rejectedClosedLid() {
    let h = Harness()
    defer { h.cleanUp() }
    h.lid.acceptsRequests = false

    #expect(h.controller.start(.indefinitely, options: closedLidOptions))

    #expect(h.controller.status.session?.closedLid != .on)
    #expect(h.controller.status.isActive)
    #expect(!h.lid.isObserving)
    #expect(!h.marker)
}

@Test("closed-lid mode is AC-only unless battery use is allowed")
@MainActor
func closedLidACOnly() {
    let h = Harness()
    defer { h.cleanUp() }
    h.power.snapshot = PowerSourceSnapshot(isOnACPower: false, batteryPercent: 90)

    h.controller.start(.indefinitely, options: closedLidOptions)
    #expect(h.controller.status.session?.closedLid == .waitingForPower)
    #expect(h.lid.writes.isEmpty)

    h.power.change(PowerSourceSnapshot(isOnACPower: true, batteryPercent: 90))
    #expect(h.controller.status.session?.closedLid == .on)
    #expect(h.lid.isDisabledNow && h.marker && h.lid.isObserving)

    // Unplugging drops only the closed-lid part.
    h.power.change(PowerSourceSnapshot(isOnACPower: false, batteryPercent: 90))
    #expect(h.controller.status.session?.closedLid == .waitingForPower)
    #expect(!h.lid.isDisabledNow && !h.marker)
    #expect(h.controller.status.isActive)

    var batteryOptions = closedLidOptions
    batteryOptions.closedLidAllowedOnBattery = true
    h.controller.updateOptions(batteryOptions)
    #expect(h.controller.status.session?.closedLid == .on)
}

@Test("closed-lid override is restored on stop, expiry, and when turned off")
@MainActor
func closedLidRestored() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.interval(60), options: closedLidOptions)
    #expect(h.controller.status.session?.closedLid == .on)
    h.scheduler.advance(by: 60)
    h.expectFullyIdle()

    h.controller.start(.indefinitely, options: closedLidOptions)
    h.controller.updateOptions(KeepAwakeOptions())
    #expect(h.controller.status.session?.closedLid == .off)
    #expect(!h.lid.isDisabledNow && !h.marker)
    h.controller.stop()
    h.expectFullyIdle()
}

@Test("closed-lid request is re-applied after wake and display changes")
@MainActor
func closedLidReappliedAfterWake() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.indefinitely, options: closedLidOptions)
    let writesAfterStart = h.lid.writes.count

    h.events.send(.didWake)
    h.events.send(.displaysChanged)

    #expect(h.lid.writes.count == writesAfterStart + 2)
    #expect(h.lid.isDisabledNow)

    // Battery-level-only changes do not rewrite the request.
    h.power.change(PowerSourceSnapshot(isOnACPower: true, batteryPercent: 79))
    #expect(h.lid.writes.count == writesAfterStart + 2)
}

@Test("lid policy change reapplies the override without abandoning the session")
@MainActor
func lidCloseFailureDetected() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.indefinitely, options: closedLidOptions)

    h.lid.lidCloseHandler?(false)
    #expect(h.controller.status.session?.closedLid == .on)

    let writesBeforeClose = h.lid.writes.count
    h.lid.lidCloseHandler?(true)
    #expect(h.lid.writes.count == writesBeforeClose + 1)
    #expect(h.controller.status.session?.closedLid == .on)
    #expect(h.lid.isDisabledNow && h.marker)

    h.events.send(.powerAssertionsChanged)
    #expect(h.lid.writes.count == writesBeforeClose + 2)
    #expect(h.controller.status.session?.closedLid == .on)

    // A rejected reapply reports unavailable and leaves ordinary sessions intact.
    h.lid.acceptsRequests = false
    h.lid.lidCloseHandler?(true)
    guard case .unavailable = h.controller.status.session?.closedLid else {
        Issue.record("expected unavailable after a failed lid close")
        return
    }
    #expect(!h.lid.isObserving && h.marker)

    // It stays unavailable after wake instead of claiming success again.
    h.events.send(.didWake)
    #expect(h.controller.status.session?.closedLid != .on)
    #expect(h.controller.status.isActive)
}

@Test("ordinary sessions do not rewrite lid policy on power assertion changes")
@MainActor
func ordinarySessionIgnoresAssertionChanges() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.start(.indefinitely, options: KeepAwakeOptions())
    h.events.send(.powerAssertionsChanged)
    #expect(h.lid.writes.isEmpty)
    #expect(h.assertions.count(.preventIdleSystemSleep) == 1)
    h.controller.stop()
    h.expectFullyIdle()
}

@Test("launch recovery clears a lid override left by a crash")
@MainActor
func launchRecovery() {
    let h = Harness()
    defer { h.cleanUp() }
    h.controller.recoverAfterUnexpectedExit()
    #expect(h.lid.writes.isEmpty)

    h.defaults.set(true, forKey: KeepAwakeController.closedLidMarkerKey)
    h.controller.recoverAfterUnexpectedExit()
    #expect(h.lid.writes == [false])
    #expect(!h.marker)
    #expect(h.controller.status == .inactive)
}

// MARK: - Model

@Test("duration presets map to the expected deadlines")
func durationPresets() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    #expect(KeepAwakeDurationPreset.indefinitely.duration.deadline(from: now) == nil)
    #expect(KeepAwakeDurationPreset.minutes15.duration.deadline(from: now) == now.addingTimeInterval(900))
    #expect(KeepAwakeDurationPreset.minutes5.duration.deadline(from: now) == now.addingTimeInterval(300))
    #expect(KeepAwakeDurationPreset.minutes45.duration.deadline(from: now) == now.addingTimeInterval(2700))
    #expect(KeepAwakeDurationPreset.hours2.duration.deadline(from: now) == now.addingTimeInterval(7200))
}

// MARK: - Preferences

@Test("keep awake preferences default off, persist, and never resume a session")
@MainActor
func keepAwakePreferencesPersistConfigurationOnly() {
    let h = Harness()
    defer { h.cleanUp() }

    let initial = NotchPreferences(defaults: h.defaults)
    #expect(initial.keepAwakeDurationPreset == .indefinitely)
    #expect(!initial.keepAwakeKeepsDisplayAwake)
    #expect(!initial.keepAwakeClosedLidEnabled)
    #expect(!initial.keepAwakeClosedLidAllowsBattery)
    #expect(initial.keepAwakeLowBatteryThreshold == 20)
    #expect(initial.keepAwakeOptions == KeepAwakeOptions())

    var forwarded: [KeepAwakeOptions] = []
    initial.onKeepAwakeOptionsChange = { forwarded.append($0) }
    initial.keepAwakeDurationPreset = .hour1
    initial.keepAwakeKeepsDisplayAwake = true
    initial.keepAwakeClosedLidEnabled = true
    initial.keepAwakeClosedLidAllowsBattery = true
    initial.keepAwakeLowBatteryThreshold = 0
    #expect(forwarded.count == 4)
    #expect(forwarded.last?.lowBatteryThreshold == nil)

    initial.keepAwakeLowBatteryThreshold = 500
    #expect(initial.keepAwakeLowBatteryThreshold == 95)

    // An active session in the old process must not carry over.
    h.controller.start(.indefinitely, options: initial.keepAwakeOptions)
    let reloaded = NotchPreferences(defaults: h.defaults)
    #expect(reloaded.keepAwakeDurationPreset == .hour1)
    #expect(reloaded.keepAwakeOptions.keepsDisplayAwake)
    #expect(reloaded.keepAwakeOptions.closedLidRequested)
    #expect(reloaded.keepAwakeOptions.closedLidAllowedOnBattery)

    let relaunched = KeepAwakeController(
        assertions: FakeAssertions(),
        closedLid: FakeClosedLid(),
        powerSource: FakePowerSource(),
        systemEvents: FakeSystemEvents(),
        scheduler: FakeScheduler(),
        defaults: h.defaults
    )
    #expect(relaunched.status == .inactive)
}

// MARK: - Presentation and menu

private func fixedPresentation() -> KeepAwakePresentation {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return KeepAwakePresentation(calendar: calendar, locale: Locale(identifier: "en_US"))
}

@Test("menu model shows static state, details, and the right action")
func keepAwakeMenuModel() {
    let presentation = fixedPresentation()
    let now = presentation.calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 0))!

    let off = KeepAwakeMenuModel.make(status: .inactive, defaultPreset: .hour1, now: now, presentation: presentation)
    #expect(off.statusTitle == "Keep Awake is off")
    #expect(off.toggleTitle == "Start Keep Awake (1 Hour)")
    #expect(off.detailLines.isEmpty)

    let session = KeepAwakeActiveSession(
        duration: .interval(100 * 60),
        startedAt: now,
        endsAt: now.addingTimeInterval(100 * 60),
        keepsDisplayAwake: true,
        closedLid: .waitingForPower
    )
    let on = KeepAwakeMenuModel.make(
        status: KeepAwakeStatus(session: session),
        defaultPreset: .hour1,
        now: now,
        presentation: presentation
    )
    #expect(on.isActive)
    #expect(on.statusTitle == "Keeping awake until 3:40\u{202F}PM")
    #expect(on.toggleTitle == "Stop Keep Awake")
    #expect(on.detailLines == ["Display stays on", "Lid closed: needs power adapter"])
    #expect(on.selectedPreset == nil)
    #expect(!on.isUntilTimeSelected)
    #expect(off.selectedPreset == nil)

    let hour = KeepAwakeMenuModel.make(
        status: KeepAwakeStatus(session: KeepAwakeActiveSession(
            duration: KeepAwakeDurationPreset.hour1.duration,
            startedAt: now,
            endsAt: now.addingTimeInterval(3600),
            keepsDisplayAwake: false,
            closedLid: .off
        )),
        defaultPreset: .indefinitely,
        now: now,
        presentation: presentation
    )
    #expect(hour.selectedPreset == .hour1)

    let until = KeepAwakeMenuModel.make(
        status: KeepAwakeStatus(session: KeepAwakeActiveSession(
            duration: .until(now.addingTimeInterval(600)),
            startedAt: now,
            endsAt: now.addingTimeInterval(600),
            keepsDisplayAwake: false,
            closedLid: .off
        )),
        defaultPreset: .indefinitely,
        now: now,
        presentation: presentation
    )
    #expect(until.isUntilTimeSelected && until.selectedPreset == nil)

    let lowBattery = KeepAwakeMenuModel.make(
        status: KeepAwakeStatus(session: nil, lastStopReason: .lowBattery),
        defaultPreset: .indefinitely,
        now: now,
        presentation: presentation
    )
    #expect(lowBattery.detailLines == ["Stopped because the battery is low"])
}

@Test("countdown text and end-time resolution")
func keepAwakePresentationText() {
    let presentation = fixedPresentation()
    let now = presentation.calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 23, minute: 30))!

    #expect(presentation.remainingText(until: now.addingTimeInterval(30), now: now) == "Less than a minute left")
    #expect(presentation.remainingText(until: now.addingTimeInterval(41 * 60 + 1), now: now) == "42 min left")
    #expect(presentation.remainingText(until: now.addingTimeInterval(2 * 3600), now: now) == "2 hr left")
    #expect(presentation.remainingText(until: now.addingTimeInterval(65 * 60), now: now) == "1 hr 5 min left")

    // A time earlier than now resolves to tomorrow; a later one to today.
    let picked = presentation.calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 7, minute: 15))!
    let tomorrow = presentation.nextOccurrence(ofTimeIn: picked, after: now)!
    #expect(tomorrow > now)
    #expect(presentation.calendar.component(.day, from: tomorrow) == 3)
    #expect(presentation.endTime(tomorrow, now: now).hasPrefix("tomorrow "))

    let later = presentation.calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 23, minute: 45))!
    let today = presentation.nextOccurrence(ofTimeIn: later, after: now)!
    #expect(presentation.calendar.component(.day, from: today) == 2)
}
