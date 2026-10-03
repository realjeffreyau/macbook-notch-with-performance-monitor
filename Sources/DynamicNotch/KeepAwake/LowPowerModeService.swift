import Foundation

struct EnergyModeSnapshot: Codable, Equatable, Sendable {
    enum Flag: String, Codable, Sendable {
        case lowPower = "lowpowermode"
        case powerMode = "powermode"
    }
    struct Profile: Codable, Equatable, Sendable {
        let flag: Flag
        let value: Int

        var isValid: Bool { (0...(flag == .lowPower ? 1 : 2)).contains(value) }
    }
    let battery: Profile
    let adapter: Profile

    var isValid: Bool { battery.isValid && adapter.isValid }
    var lowPower: Self {
        Self(battery: Profile(flag: battery.flag, value: 1),
             adapter: Profile(flag: adapter.flag, value: 1))
    }

    static func parse(_ text: String) -> Self? {
        var current: String?
        var profiles: [String: Profile] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Battery Power:" { current = "battery"; continue }
            if trimmed == "AC Power:" { current = "adapter"; continue }
            if trimmed.hasSuffix(":") { current = nil; continue }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard let first = parts.first, let flag = Flag(rawValue: String(first)) else { continue }
            guard let current, parts.count == 2, let value = Int(parts[1]),
                  profiles[current] == nil else { return nil }
            let profile = Profile(flag: flag, value: value)
            guard profile.isValid else { return nil }
            profiles[current] = profile
        }
        guard let battery = profiles["battery"], let adapter = profiles["adapter"] else { return nil }
        return Self(battery: battery, adapter: adapter)
    }
}

@MainActor
protocol EnergyModeBackend: AnyObject {
    func read() async throws -> EnergyModeSnapshot
    func write(_ snapshot: EnergyModeSnapshot) async throws
}

enum EnergyModeError: Error {
    case unavailable
    case authorizationOrWriteFailed
    case helperApprovalRequired
}

/// Bounded unprivileged reads; approved XPC helper writes. No password storage,
/// shell authorization on each change, sudoers rule, or polling.
@MainActor
final class MacEnergyModeBackend: EnergyModeBackend {
    func read() async throws -> EnergyModeSnapshot {
        let output = try await Self.run("/usr/bin/pmset", arguments: ["-g", "custom"])
        guard let snapshot = EnergyModeSnapshot.parse(output) else { throw EnergyModeError.unavailable }
        return snapshot
    }

    func write(_ snapshot: EnergyModeSnapshot) async throws {
        try await EnergyHelperClient.apply(snapshot)
    }

    private static func run(_ executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    continuation.resume(throwing: EnergyModeError.authorizationOrWriteFailed)
                }
            }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// The Settings opt-in follows the closed-lid switch, independently of session
/// duration. Save both profiles before writing, serialize rapid toggle changes,
/// and retain recovery data until restoration has been read back successfully.
@MainActor
final class LowPowerModeService {
    static let recoveryKey = "keepAwake.savedEnergyModes"
    var onStatusChange: (@MainActor (String) -> Void)?
    private let backend: any EnergyModeBackend
    private let defaults: UserDefaults
    private var operation: Task<Void, Never>?
    private var desired = false
    private var applied = false

    var needsRestoration: Bool {
        operation != nil || defaults.data(forKey: Self.recoveryKey) != nil
    }

    init(backend: any EnergyModeBackend, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Task<Void, Never> {
        desired = enabled
        if let operation { return operation }
        let task = Task { [weak self] in
            guard let self else { return }
            await reconcile()
            operation = nil
        }
        operation = task
        return task
    }

    func restoreForQuit() async -> Bool {
        desired = false
        await operation?.value
        await reconcile()
        return defaults.data(forKey: Self.recoveryKey) == nil
    }

    private func reconcile() async {
        repeat {
            let target = desired
            if target && applied { return }
            let savedData = defaults.data(forKey: Self.recoveryKey)
            if !target && savedData == nil { return }
            onStatusChange?(target ? "Enabling Low Power Mode…" : "Restoring previous energy modes…")
            do {
                let saved: EnergyModeSnapshot
                if let savedData {
                    saved = try JSONDecoder().decode(EnergyModeSnapshot.self, from: savedData)
                    guard saved.isValid else { throw EnergyModeError.unavailable }
                } else {
                    saved = try await backend.read()
                    defaults.set(try JSONEncoder().encode(saved), forKey: Self.recoveryKey)
                }
                let requested = target ? saved.lowPower : saved
                if try await backend.read() != requested {
                    try await backend.write(requested)
                }
                guard try await backend.read() == requested else { throw EnergyModeError.unavailable }
                applied = target
                if !target { defaults.removeObject(forKey: Self.recoveryKey) }
                onStatusChange?(target ? "Low Power Mode on for battery and power adapter" : "Previous energy modes restored")
            } catch EnergyModeError.helperApprovalRequired {
                applied = false
                onStatusChange?("Enable and approve the energy helper in Settings → Closed lid, then reopen Settings to retry. Saved modes are kept for recovery.")
                return
            } catch {
                applied = false
                onStatusChange?("Energy mode change was not confirmed. Check the energy helper, then toggle this option to retry. Saved modes are kept for recovery.")
                return
            }
            if desired == target { return }
        } while true
    }
}
