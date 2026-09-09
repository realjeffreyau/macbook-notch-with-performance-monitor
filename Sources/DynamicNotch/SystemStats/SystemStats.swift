import Darwin
import Foundation
import IOKit.ps

enum SystemBatteryState: Equatable, Sendable {
    case charging
    case discharging
    case full
    case unknown
}

struct SystemBatterySnapshot: Equatable, Sendable {
    let chargeFraction: Double?
    let state: SystemBatteryState
    let isPluggedIn: Bool?

    init(
        chargeFraction: Double?,
        state: SystemBatteryState,
        isPluggedIn: Bool?
    ) {
        if let chargeFraction, chargeFraction.isFinite {
            self.chargeFraction = min(max(chargeFraction, 0), 1)
        } else {
            self.chargeFraction = nil
        }
        self.state = state
        self.isPluggedIn = isPluggedIn
    }
}

/// One local system observation. Nil fields mean that the native API did not
/// provide a trustworthy value for that field; callers should render a neutral
/// unavailable state instead of inventing a number.
struct SystemStatsSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let cpuUsage: Double?
    let usedMemoryBytes: UInt64?
    let totalMemoryBytes: UInt64?
    let battery: SystemBatterySnapshot?

    init(
        capturedAt: Date = Date(),
        cpuUsage: Double?,
        usedMemoryBytes: UInt64?,
        totalMemoryBytes: UInt64?,
        battery: SystemBatterySnapshot?
    ) {
        self.capturedAt = capturedAt
        if let cpuUsage, cpuUsage.isFinite {
            self.cpuUsage = min(max(cpuUsage, 0), 1)
        } else {
            self.cpuUsage = nil
        }
        self.usedMemoryBytes = usedMemoryBytes
        self.totalMemoryBytes = totalMemoryBytes
        self.battery = battery
    }

    var memoryUsage: Double? {
        guard let usedMemoryBytes, let totalMemoryBytes, totalMemoryBytes > 0 else {
            return nil
        }
        return min(max(Double(usedMemoryBytes) / Double(totalMemoryBytes), 0), 1)
    }

    /// A bounded, relative energy-pressure estimate derived from the values
    /// already sampled for the Performance page. macOS does not expose a
    /// portable instantaneous energy percentage through the public APIs used
    /// here, so this deliberately avoids extra processes, private APIs, or a
    /// second sampling loop. It is a UI indicator, not a watt measurement.
    var energyUsageEstimate: Double? {
        guard let cpuUsage else { return nil }
        let memoryPressure = memoryUsage ?? cpuUsage
        return min(max((cpuUsage * 0.8) + (memoryPressure * 0.2), 0), 1)
    }
}

@MainActor
protocol SystemStatsSampling: AnyObject {
    func reset()
    func sample() -> SystemStatsSnapshot
}

extension SystemStatsSampling {
    func reset() {}
}

enum SystemStatsServiceState: Equatable, Sendable {
    case stopped
    case sampling
}

/// Samples only for an explicitly visible System page. The task is cancelled
/// synchronously when the page is hidden, so collapsed and media states do not
/// leave a timer or polling loop behind.
@MainActor
final class SystemStatsService {
    static let defaultInterval: TimeInterval = 2

    private let sampler: any SystemStatsSampling
    private let intervalNanoseconds: UInt64
    private var samplingTask: Task<Void, Never>?

    private(set) var state: SystemStatsServiceState = .stopped
    private(set) var snapshot: SystemStatsSnapshot?
    var onUpdate: (@MainActor (SystemStatsSnapshot?) -> Void)?

    init(
        sampler: any SystemStatsSampling = NativeSystemStatsSampler(),
        interval: TimeInterval = SystemStatsService.defaultInterval
    ) {
        self.sampler = sampler
        let safeInterval = interval.isFinite && interval > 0
            ? min(interval, 60)
            : Self.defaultInterval
        intervalNanoseconds = UInt64(safeInterval * 1_000_000_000)
    }

    func start() {
        guard samplingTask == nil else { return }

        state = .sampling
        sampler.reset()
        publish(sampler.sample())

        let intervalNanoseconds = self.intervalNanoseconds
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.sampleIfRunning()
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        state = .stopped
        snapshot = nil
        onUpdate?(nil)
    }

    private func sampleIfRunning() {
        guard state == .sampling else { return }
        publish(sampler.sample())
    }

    private func publish(_ snapshot: SystemStatsSnapshot?) {
        self.snapshot = snapshot
        onUpdate?(snapshot)
    }
}

/// Native, local-only system sampler. CPU and VM counters are read through
/// Mach; battery state comes from IOKit power sources. No shell command,
/// network request, or third-party process is involved.
@MainActor
final class NativeSystemStatsSampler: SystemStatsSampling {
    private struct CPUCounters {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var nice: UInt64 = 0
        var idle: UInt64 = 0

        var total: UInt64 { user + system + nice + idle }
    }

    private var previousCPUCounters: CPUCounters?

    func reset() {
        previousCPUCounters = nil
    }

    func sample() -> SystemStatsSnapshot {
        SystemStatsSnapshot(
            capturedAt: Date(),
            cpuUsage: sampleCPUUsage(),
            usedMemoryBytes: sampleUsedMemory(),
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            battery: sampleBattery()
        )
    }

    private func sampleCPUUsage() -> Double? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else { return nil }

        defer {
            let size = vm_size_t(
                Int(processorInfoCount) * MemoryLayout<integer_t>.stride
            )
            _ = vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: processorInfo),
                size
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var counters = CPUCounters()
        for processor in 0..<Int(processorCount) {
            let base = processor * stride
            counters.user += UInt64(processorInfo[base + Int(CPU_STATE_USER)])
            counters.system += UInt64(processorInfo[base + Int(CPU_STATE_SYSTEM)])
            counters.nice += UInt64(processorInfo[base + Int(CPU_STATE_NICE)])
            counters.idle += UInt64(processorInfo[base + Int(CPU_STATE_IDLE)])
        }

        defer { previousCPUCounters = counters }
        guard let previous = previousCPUCounters else { return nil }
        let totalDelta = counters.total >= previous.total
            ? counters.total - previous.total
            : 0
        let idleDelta = counters.idle >= previous.idle
            ? counters.idle - previous.idle
            : 0
        guard totalDelta > 0, idleDelta <= totalDelta else { return nil }
        return Double(totalDelta - idleDelta) / Double(totalDelta)
    }

    private func sampleUsedMemory() -> UInt64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { reboundPointer in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSizeBytes: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSizeBytes) == KERN_SUCCESS else {
            return nil
        }
        let pageSize = UInt64(pageSizeBytes)
        let residentPages = UInt64(statistics.active_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        return residentPages.multipliedReportingOverflow(by: pageSize).overflow
            ? nil
            : residentPages * pageSize
    }

    private func sampleBattery() -> SystemBatterySnapshot? {
        let powerSources = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let sourceList = IOPSCopyPowerSourcesList(powerSources)?.takeRetainedValue()
            as? [CFTypeRef],
            !sourceList.isEmpty
        else {
            return nil
        }

        for source in sourceList {
            guard let descriptionReference = IOPSGetPowerSourceDescription(powerSources, source),
                  let description = descriptionReference.takeUnretainedValue() as? [String: Any]
            else { continue }

            let current: Double? = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
            let maximum: Double? = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue
            let fraction: Double?
            if let current, let maximum, maximum > 0 {
                fraction = current / maximum
            } else {
                fraction = nil
            }

            let powerState = description[kIOPSPowerSourceStateKey as String] as? String
            let isPluggedIn = powerState == kIOPSACPowerValue
            let state: SystemBatteryState
            if let fraction, fraction >= 0.999 {
                state = .full
            } else if powerState == kIOPSACPowerValue {
                state = .charging
            } else if powerState == kIOPSBatteryPowerValue {
                state = .discharging
            } else {
                state = .unknown
            }

            return SystemBatterySnapshot(
                chargeFraction: fraction,
                state: state,
                isPluggedIn: isPluggedIn
            )
        }
        return nil
    }
}
