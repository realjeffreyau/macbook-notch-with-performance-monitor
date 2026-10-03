import Foundation
import ServiceManagement
import EnergyHelperProtocol

@MainActor
enum EnergyHelperSetup {
    static var service: SMAppService { .daemon(plistName: EnergyHelperIdentity.plist) }
    static var isApproved: Bool { service.status == .enabled }
    static var statusMessage: String {
        switch service.status {
        case .enabled: "Energy helper approved. Energy changes need no password."
        case .requiresApproval: "Approve Dynamic Notch in System Settings → General → Login Items & Extensions."
        case .notRegistered: "Enable the energy helper once to avoid repeated password prompts."
        case .notFound: "Energy helper has no registration. Enable it to create the background entry."
        @unknown default: "Energy helper is unavailable."
        }
    }

    static func register() throws {
        // macOS can return notFound for a bundled daemon with no BTM record,
        // even when its plist and executable exist. Registration creates it.
        if service.status == .notRegistered || service.status == .notFound {
            try service.register()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static func unregister() async throws {
        if service.status != .notRegistered { try await service.unregister() }
    }
}

private final class EnergyHelperReply: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Void, Error>
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ success: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        if success { continuation.resume() }
        else { continuation.resume(throwing: EnergyModeError.authorizationOrWriteFailed) }
    }
}

@MainActor
enum EnergyHelperClient {
    static func apply(_ snapshot: EnergyModeSnapshot) async throws {
        guard snapshot.isValid else { throw EnergyModeError.unavailable }
        guard EnergyHelperSetup.isApproved else { throw EnergyModeError.helperApprovalRequired }
        guard let requirement = EnergyHelperIdentity.requirement(for: EnergyHelperIdentity.service) else {
            throw EnergyModeError.unavailable
        }
        let connection = NSXPCConnection(machServiceName: EnergyHelperIdentity.service, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: EnergyModeHelperProtocol.self)
        defer { connection.invalidate() }
        try await withCheckedThrowingContinuation { continuation in
            let reply = EnergyHelperReply(continuation)
            connection.invalidationHandler = { reply.finish(false) }
            connection.interruptionHandler = { reply.finish(false) }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(false) })
                as? EnergyModeHelperProtocol else { reply.finish(false); return }
            proxy.apply(batteryFlag: snapshot.battery.flag.rawValue, batteryValue: snapshot.battery.value,
                        adapterFlag: snapshot.adapter.flag.rawValue, adapterValue: snapshot.adapter.value) {
                reply.finish($0)
            }
        }
    }
}
