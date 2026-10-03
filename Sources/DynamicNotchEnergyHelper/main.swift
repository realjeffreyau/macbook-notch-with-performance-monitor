import Foundation
import EnergyHelperProtocol

// launchd starts this process on demand. One serial queue handles writes;
// a cancellable one-shot deadline exits after 15 seconds without requests.
final class EnergyHelper: NSObject, NSXPCListenerDelegate, EnergyModeHelperProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dynamicnotch.energy-helper", qos: .utility)
    private var idleExit: DispatchWorkItem?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = EnergyHelperIdentity.requirement(for: EnergyHelperIdentity.app) else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: EnergyModeHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        scheduleIdleExit()
        return true
    }

    func apply(batteryFlag: String, batteryValue: Int, adapterFlag: String, adapterValue: Int,
               reply: @escaping (Bool) -> Void) {
        guard let battery = EnergyHelperArguments.make(profile: "-b", flag: batteryFlag, value: batteryValue),
              let adapter = EnergyHelperArguments.make(profile: "-c", flag: adapterFlag, value: adapterValue)
        else { reply(false); return }
        // NSObject XPC callbacks aren't Sendable; keep the reply inside a
        // narrowly scoped transfer box and execute it exactly once.
        let completion = ReplyTransfer(reply)
        queue.async { [self] in
            idleExit?.cancel()
            let succeeded = run(battery) && run(adapter)
            completion.reply(succeeded)
            armIdleExit()
        }
    }

    private func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    func scheduleIdleExit() { queue.async { [self] in armIdleExit() } }
    private func armIdleExit() {
        idleExit?.cancel()
        let work = DispatchWorkItem { exit(0) }
        idleExit = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
    }
}

private final class ReplyTransfer: @unchecked Sendable {
    let reply: (Bool) -> Void
    init(_ reply: @escaping (Bool) -> Void) { self.reply = reply }
}

guard geteuid() == 0 else { exit(1) }
let helper = EnergyHelper()
let listener = NSXPCListener(machServiceName: EnergyHelperIdentity.service)
listener.delegate = helper
listener.resume()
helper.scheduleIdleExit()
RunLoop.main.run()
