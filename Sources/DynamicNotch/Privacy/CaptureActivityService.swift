import AVFoundation
import Foundation

struct CaptureActivity: Equatable, Sendable {
    let microphoneActive: Bool
    let cameraActive: Bool

    static let inactive = CaptureActivity(microphoneActive: false, cameraActive: false)

    var isActive: Bool { microphoneActive || cameraActive }
}

enum CaptureActivityServiceStatus: Equatable, Sendable {
    case stopped
    case running
    case unavailable
}

@MainActor
protocol CaptureActivityService: AnyObject {
    var status: CaptureActivityServiceStatus { get }
    var currentActivity: CaptureActivity { get }
    var onActivityUpdate: (@MainActor (CaptureActivity) -> Void)? { get set }

    func start()
    func stop()
}

/// Event-driven, fail-closed capture activity observation. It never opens a
/// capture session or requests camera/microphone permission.
@MainActor
final class AVCaptureActivityService: CaptureActivityService, @unchecked Sendable {
    private(set) var status: CaptureActivityServiceStatus = .stopped
    private(set) var currentActivity = CaptureActivity.inactive
    var onActivityUpdate: (@MainActor (CaptureActivity) -> Void)?

    private var devices: [String: AVCaptureDevice] = [:]
    private var deviceObservers: [String: NSKeyValueObservation] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    func start() {
        guard status != .running else { return }
        status = .running
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.rescanDevices() }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.rescanDevices() }
            }
        ]
        rescanDevices()
    }

    func stop() {
        guard status == .running else {
            currentActivity = .inactive
            return
        }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        deviceObservers.removeAll()
        devices.removeAll()
        status = .stopped
        publish(.inactive)
    }

    private func rescanDevices() {
        guard status == .running else { return }
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        let microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        var nextDevices: [String: AVCaptureDevice] = [:]
        for device in cameras + microphones {
            nextDevices[device.uniqueID] = device
        }

        for identifier in devices.keys where nextDevices[identifier] == nil {
            deviceObservers.removeValue(forKey: identifier)
        }
        devices = nextDevices
        for device in devices.values where deviceObservers[device.uniqueID] == nil {
            deviceObservers[device.uniqueID] = device.observe(
                \AVCaptureDevice.isInUseByAnotherApplication,
                options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        guard status == .running else { return }
        publish(CaptureActivity(
            microphoneActive: devices.values.contains { $0.hasMediaType(.audio) && $0.isInUseByAnotherApplication },
            cameraActive: devices.values.contains { $0.hasMediaType(.video) && $0.isInUseByAnotherApplication }
        ))
    }

    private func publish(_ activity: CaptureActivity) {
        guard activity != currentActivity || activity.isActive else { return }
        currentActivity = activity
        onActivityUpdate?(activity)
    }
}
