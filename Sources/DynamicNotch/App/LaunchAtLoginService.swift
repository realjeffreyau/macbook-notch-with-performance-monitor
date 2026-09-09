import ServiceManagement

/// Owns the optional native macOS login-item registration.
///
/// Registration is intentionally explicit and idempotent. The app does not
/// register itself during normal startup unless the persisted preference is
/// already enabled; the default preference is off.
@MainActor
final class LaunchAtLoginService {
    @discardableResult
    func apply(enabled: Bool) -> Bool {
        let service = SMAppService.mainApp

        do {
            if enabled {
                guard service.status != .enabled,
                      service.status != .requiresApproval
                else { return true }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return true }
                try service.unregister()
            }
            return true
        } catch {
            fputs("Dynamic Notch: unable to update startup registration: \(error)\n", stderr)
            return false
        }
    }
}
