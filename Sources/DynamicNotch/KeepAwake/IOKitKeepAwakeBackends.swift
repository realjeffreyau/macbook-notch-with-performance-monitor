import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import PowerNotificationBridge

/// Documented IOKit power assertions. powerd releases them automatically if
/// the process exits or crashes, so they cannot outlive the app.
@MainActor
final class IOKitPowerAssertionBackend: PowerAssertionBackend {
    func acquire(_ kind: PowerAssertionKind, name: String) throws(PowerAssertionError) -> UInt32 {
        // String values of kIOPMAssertPreventUserIdleSystemSleep and
        // kIOPMAssertPreventUserIdleDisplaySleep (IOPMLib.h).
        let type = switch kind {
        case .preventIdleSystemSleep: "PreventUserIdleSystemSleep"
        case .preventIdleDisplaySleep: "PreventUserIdleDisplaySleep"
        }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError(code: result)
        }
        return id
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}

/// Closed-lid control through the IOPMrootDomain user-client selector
/// `kPMSetClamshellSleepState` (declared in IOPMLibDefs.h; behavior is not
/// documented by Apple and may change across macOS releases).
///
/// The request lives only in kernel memory: it is not saved and a restart
/// clears it, but it is not released if this process crashes. The
/// controller's launch marker covers that case.
@MainActor
final class IOKitClosedLidBackend: ClosedLidBackend {
    /// iokit_family_msg(sub_iokit_powermanagement, 0x100) from IOPM.h.
    private static let clamshellStateChangeMessage: UInt32 = 0xE003_4100
    private static let clamshellClosedBit: UInt = 1 << 0
    private static let clamshellSleepBit: UInt = 1 << 1

    private var notificationPort: IONotificationPortRef?
    private var interestNotifier: io_object_t = IO_OBJECT_NULL
    private var lidCloseHandler: (@MainActor (Bool) -> Void)?

    var isSupported: Bool {
        withRootDomain { rootDomain in
            // IOPMrootDomain publishes AppleClamshellState only when a lid exists.
            IORegistryEntryCreateCFProperty(
                rootDomain,
                "AppleClamshellState" as CFString,
                kCFAllocatorDefault,
                0
            ) != nil
        } ?? false
    }

    func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        withRootDomain { rootDomain in
            var connection: io_connect_t = IO_OBJECT_NULL
            guard IOServiceOpen(rootDomain, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
                return false
            }
            defer { IOServiceClose(connection) }
            var input: UInt64 = disabled ? 1 : 0
            return IOConnectCallScalarMethod(
                connection,
                UInt32(kPMSetClamshellSleepState),
                &input,
                1,
                nil,
                nil
            ) == KERN_SUCCESS
        } ?? false
    }

    func startObservingLidClose(_ handler: @escaping @MainActor (Bool) -> Void) {
        stopObservingLidClose()
        lidCloseHandler = handler
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .commonModes
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = withRootDomain { rootDomain in
            IOServiceAddInterestNotification(
                port,
                rootDomain,
                "IOGeneralInterest",
                { refcon, _, messageType, argument in
                    guard messageType == IOKitClosedLidBackend.clamshellStateChangeMessage,
                          let refcon else { return }
                    let bits = UInt(bitPattern: argument)
                    guard bits & IOKitClosedLidBackend.clamshellClosedBit != 0 else { return }
                    let causesSleep = bits & IOKitClosedLidBackend.clamshellSleepBit != 0
                    // The port's run-loop source is on the main run loop.
                    MainActor.assumeIsolated {
                        let backend = Unmanaged<IOKitClosedLidBackend>.fromOpaque(refcon).takeUnretainedValue()
                        backend.lidCloseHandler?(causesSleep)
                    }
                },
                refcon,
                &interestNotifier
            )
        }
    }

    func stopObservingLidClose() {
        lidCloseHandler = nil
        if interestNotifier != IO_OBJECT_NULL {
            IOObjectRelease(interestNotifier)
            interestNotifier = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    private func withRootDomain<T>(_ body: (io_service_t) -> T) -> T? {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(rootDomain) }
        return body(rootDomain)
    }
}

/// Power-source changes from IOKit's notification run-loop source. It is
/// installed only while a session is active; there is no battery polling.
@MainActor
final class IOKitPowerSourceMonitor: PowerSourceMonitoring {
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@MainActor (PowerSourceSnapshot) -> Void)?

    func currentSnapshot() -> PowerSourceSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .acWithoutBattery
        }
        // kIOPMACPowerKey
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let isOnAC = providing == "AC Power"

        var batteryPercent: Int?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let maximum = description["Max Capacity"] as? Int,
                  maximum > 0
            else { continue }
            batteryPercent = current * 100 / maximum
            break
        }
        return PowerSourceSnapshot(isOnACPower: isOnAC, batteryPercent: batteryPercent)
    }

    func start(_ handler: @escaping @MainActor (PowerSourceSnapshot) -> Void) {
        stop()
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<IOKitPowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handler?(monitor.currentSnapshot())
            }
        }, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        handler = nil
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
            self.runLoopSource = nil
        }
    }
}

/// Wake, display-configuration, and clock-change notifications. Observers
/// exist only while a session is active.
@MainActor
final class WorkspaceKeepAwakeSystemEvents: KeepAwakeSystemEvents {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var assertionNotificationToken: Int32?

    func start(_ handler: @escaping @MainActor (KeepAwakeSystemEvent) -> Void) {
        stop()
        let registrations: [(NotificationCenter, Notification.Name, KeepAwakeSystemEvent)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, .didWake),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, .displaysChanged),
            (NotificationCenter.default, .NSSystemClockDidChange, .clockChanged),
        ]
        for (center, name, event) in registrations {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    handler(event)
                }
            }
            observers.append((center, token))
        }
        // powerd shares our clamshell-disable bit and can clear it when
        // aggregate power assertions change. Notify coalesces these events.
        let token = DNObservePowerAssertions {
            MainActor.assumeIsolated { handler(.powerAssertionsChanged) }
        }
        if token >= 0 {
            assertionNotificationToken = token
        }
    }

    func stop() {
        if let assertionNotificationToken {
            DNCancelPowerAssertionObservation(assertionNotificationToken)
            self.assertionNotificationToken = nil
        }
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
    }
}

/// One wall-clock deadline per session. A wall deadline keeps counting while
/// the Mac sleeps, so an overdue session ends promptly after wake.
@MainActor
final class DispatchKeepAwakeScheduler: KeepAwakeScheduler {
    var now: Date { Date() }

    func schedule(at date: Date, _ handler: @escaping @MainActor () -> Void) -> any KeepAwakeCancellable {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            wallDeadline: .now() + max(0, date.timeIntervalSinceNow),
            repeating: .never,
            leeway: .seconds(1)
        )
        timer.setEventHandler {
            MainActor.assumeIsolated {
                handler()
            }
        }
        timer.resume()
        return DispatchKeepAwakeDeadline(timer: timer)
    }
}

@MainActor
private final class DispatchKeepAwakeDeadline: KeepAwakeCancellable {
    private let timer: any DispatchSourceTimer

    init(timer: any DispatchSourceTimer) {
        self.timer = timer
    }

    func cancel() {
        timer.cancel()
    }
}
