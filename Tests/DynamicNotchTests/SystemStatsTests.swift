import Foundation
import Testing
@testable import DynamicNotch

@Test("system snapshot clamps invalid percentages and derives memory usage")
func systemSnapshotClampsAndDerivesValues() {
    let battery = SystemBatterySnapshot(
        chargeFraction: 1.4,
        state: .charging,
        isPluggedIn: true
    )
    let snapshot = SystemStatsSnapshot(
        capturedAt: Date(timeIntervalSinceReferenceDate: 100),
        cpuUsage: -0.2,
        usedMemoryBytes: 3,
        totalMemoryBytes: 4,
        battery: battery
    )

    #expect(snapshot.cpuUsage == 0)
    #expect(snapshot.memoryUsage == 0.75)
    #expect(abs((snapshot.energyUsageEstimate ?? -1) - 0.15) < 0.0001)
    #expect(snapshot.battery?.chargeFraction == 1)
}

@Test("system stats sampling is idle until started and cancels on stop")
@MainActor
func systemStatsSamplingIsLifecycleBound() async {
    let sampler = MockSystemStatsSampler()
    let service = SystemStatsService(sampler: sampler, interval: 0.001)

    #expect(service.state == .stopped)
    #expect(sampler.sampleCount == 0)

    service.start()
    service.start()
    #expect(service.state == .sampling)
    #expect(sampler.sampleCount == 1)

    for _ in 0..<20 where sampler.sampleCount == 1 {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(sampler.sampleCount > 1)

    service.stop()
    let stoppedCount = sampler.sampleCount
    #expect(service.state == .stopped)
    #expect(service.snapshot == nil)

    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(sampler.sampleCount == stoppedCount)
}

@Test("collapsing resets the expanded page to media")
@MainActor
func collapsingResetsExpandedPage() {
    let state = AppState()
    state.setExpandedPage(.system)
    #expect(state.expandedPage == .system)

    state.collapse()

    #expect(state.expandedPage == .media)
}

@Test("native system sampler returns a local memory observation")
@MainActor
func nativeSystemSamplerReturnsMemoryObservation() {
    let snapshot = NativeSystemStatsSampler().sample()

    #expect(snapshot.totalMemoryBytes != nil)
    #expect(snapshot.totalMemoryBytes ?? 0 > 0)
    #expect(snapshot.usedMemoryBytes != nil)
    #expect((snapshot.usedMemoryBytes ?? 0) <= (snapshot.totalMemoryBytes ?? 0))
}

@MainActor
private final class MockSystemStatsSampler: SystemStatsSampling {
    private(set) var sampleCount = 0

    func sample() -> SystemStatsSnapshot {
        sampleCount += 1
        return SystemStatsSnapshot(
            cpuUsage: 0.25,
            usedMemoryBytes: 1,
            totalMemoryBytes: 2,
            battery: nil
        )
    }
}
