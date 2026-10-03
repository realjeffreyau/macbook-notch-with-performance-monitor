import Foundation
import Testing
import EnergyHelperProtocol
@testable import DynamicNotch

@Test("privileged helper accepts only bounded energy modes, never arbitrary commands")
func energyHelperBoundary() {
    #expect(EnergyHelperArguments.make(profile: "-b", flag: "lowpowermode", value: 1) == ["-b", "lowpowermode", "1"])
    #expect(EnergyHelperArguments.make(profile: "-c", flag: "powermode", value: 2) == ["-c", "powermode", "2"])
    #expect(EnergyHelperArguments.make(profile: "-a", flag: "lowpowermode", value: 1) == nil)
    #expect(EnergyHelperArguments.make(profile: "-b", flag: "disablesleep", value: 1) == nil)
    #expect(EnergyHelperArguments.make(profile: "-b", flag: "lowpowermode; /bin/sh", value: 1) == nil)
    #expect(EnergyHelperArguments.make(profile: "-b", flag: "lowpowermode", value: 2) == nil)
    #expect(EnergyHelperArguments.make(profile: "-c", flag: "powermode", value: -1) == nil)
    #expect(EnergyHelperArguments.make(profile: "-c", flag: "powermode", value: Int.max) == nil)
}

@MainActor
private final class FakeEnergyModes: EnergyModeBackend {
    var modes = EnergyModeSnapshot(
        battery: .init(flag: .lowPower, value: 0),
        adapter: .init(flag: .powerMode, value: 2)
    )
    var writes: [EnergyModeSnapshot] = []
    var rejectWrite = false
    var ignoreWrite = false
    var beforeWrite: (() -> Void)?
    func read() async throws -> EnergyModeSnapshot { modes }
    func write(_ snapshot: EnergyModeSnapshot) async throws {
        beforeWrite?()
        if rejectWrite { throw EnergyModeError.authorizationOrWriteFailed }
        writes.append(snapshot)
        if !ignoreWrite { modes = snapshot }
    }
}

@Test("energy-mode parsing preserves independent battery and high-power adapter modes")
func parseEnergyModes() {
    let parsed = EnergyModeSnapshot.parse("Battery Power:\n lowpowermode 0\n sleep 1\nAC Power:\n powermode 2\n sleep 1")
    #expect(parsed?.battery.value == 0)
    #expect(parsed?.adapter.value == 2)
    #expect(parsed?.adapter.flag == .powerMode)
    #expect(parsed?.lowPower.adapter.value == 1)
    #expect(EnergyModeSnapshot.parse("Battery Power:\n lowpowermode 0") == nil)
    #expect(EnergyModeSnapshot.parse("Battery Power:\n lowpowermode 3\nAC Power:\n lowpowermode 0") == nil)
    #expect(EnergyModeSnapshot.parse("Battery Power:\n lowpowermode 0\n lowpowermode 1\nAC Power:\n lowpowermode 0") == nil)
}

@Test("low-power opt-in defaults off and persists without affecting sleep options")
@MainActor
func energyPreference() {
    let name = "EnergyPreference.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = NotchPreferences(defaults: defaults)
    #expect(!preferences.keepAwakeLowPowerWithClosedLid)
    preferences.keepAwakeLowPowerWithClosedLid = true
    #expect(NotchPreferences(defaults: defaults).keepAwakeLowPowerWithClosedLid)
    #expect(preferences.keepAwakeOptions == KeepAwakeOptions())
}

@Test("low power applies once and restores both original modes on quit")
@MainActor
func energyRestoration() async {
    let name = "EnergyRestoration.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let backend = FakeEnergyModes()
    let original = backend.modes
    let service = LowPowerModeService(backend: backend, defaults: defaults)
    await service.setEnabled(false).value
    #expect(backend.writes.isEmpty)
    await service.setEnabled(true).value
    #expect(backend.modes == original.lowPower)
    #expect(defaults.data(forKey: LowPowerModeService.recoveryKey) != nil)
    await service.setEnabled(true).value
    #expect(backend.writes.count == 1)
    #expect(await service.restoreForQuit())
    #expect(backend.modes == original)
    #expect(defaults.data(forKey: LowPowerModeService.recoveryKey) == nil)
}

@Test("unconfirmed energy writes retain recovery and never report success")
@MainActor
func unconfirmedEnergyWrite() async {
    let name = "EnergyFailure.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let backend = FakeEnergyModes()
    backend.ignoreWrite = true
    let service = LowPowerModeService(backend: backend, defaults: defaults)
    var message = ""
    service.onStatusChange = { message = $0 }
    await service.setEnabled(true).value
    #expect(message.contains("not confirmed"))
    #expect(defaults.data(forKey: LowPowerModeService.recoveryKey) != nil)
    #expect(await service.restoreForQuit())
}

@Test("denied restoration keeps backup for next-launch recovery")
@MainActor
func deniedEnergyRestoration() async {
    let name = "EnergyRecovery.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let backend = FakeEnergyModes()
    let original = backend.modes
    let service = LowPowerModeService(backend: backend, defaults: defaults)
    await service.setEnabled(true).value
    backend.rejectWrite = true
    #expect(!(await service.restoreForQuit()))
    #expect(defaults.data(forKey: LowPowerModeService.recoveryKey) != nil)
    backend.rejectWrite = false
    let recovered = LowPowerModeService(backend: backend, defaults: defaults)
    await recovered.setEnabled(false).value
    #expect(backend.modes == original)
    #expect(defaults.data(forKey: LowPowerModeService.recoveryKey) == nil)
}

@Test("switching off during an energy change restores the saved modes")
@MainActor
func energyRapidToggle() async {
    let name = "EnergyRapidToggle.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let backend = FakeEnergyModes()
    let original = backend.modes
    let service = LowPowerModeService(backend: backend, defaults: defaults)
    backend.beforeWrite = { [weak service] in
        backend.beforeWrite = nil
        service?.setEnabled(false)
    }
    await service.setEnabled(true).value
    #expect(backend.modes == original)
    #expect(backend.writes == [original.lowPower, original])
    #expect(defaults.data(forKey: LowPowerModeService.recoveryKey) == nil)
}
