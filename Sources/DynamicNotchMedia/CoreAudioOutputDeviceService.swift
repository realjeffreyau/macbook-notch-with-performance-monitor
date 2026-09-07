import CoreAudio
import Foundation

/// Lifecycle state for the local CoreAudio output-device observer.
public enum MediaOutputDeviceServiceStatus: Equatable, Sendable {
    case stopped
    case running
    case unavailable
}

/// Reads the system's default output device and receives CoreAudio change
/// notifications. The service has no sampling timer: after the initial read,
/// it refreshes only when CoreAudio reports a property change.
@MainActor
public protocol MediaOutputDeviceService: AnyObject {
    var status: MediaOutputDeviceServiceStatus { get }
    var currentDevice: MediaOutputDevice? { get }
    var onDeviceUpdate: (@MainActor (MediaOutputDevice?) -> Void)? { get set }

    func start()
    func stop()
}

/// A small, local-only CoreAudio adapter for the default output device.
///
/// CoreAudio's default-device property and device UID/name properties are
/// public APIs. The listener is installed on the main queue so callbacks can
/// update the main-actor media projection without introducing a polling loop.
@MainActor
public final class CoreAudioOutputDeviceService: MediaOutputDeviceService, @unchecked Sendable {
    public private(set) var status: MediaOutputDeviceServiceStatus = .stopped
    public private(set) var currentDevice: MediaOutputDevice?
    public var onDeviceUpdate: (@MainActor (MediaOutputDevice?) -> Void)?

    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let listenerQueue = DispatchQueue.main
    private var listenerInstalled = false
    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        // CoreAudio dispatches this block on `listenerQueue` (the main queue).
        // The explicit hop makes the actor boundary obvious to Swift 6 while
        // still doing one event-driven refresh per device notification.
        DispatchQueue.main.async { [weak self] in
            self?.refreshFromListener()
        }
    }

    private var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var deviceNameAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var deviceUIDAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    public init() {}

    public func start() {
        guard status != .running else { return }

        var address = defaultOutputAddress
        let addStatus = AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &address,
            listenerQueue,
            listenerBlock
        )
        guard addStatus == noErr else {
            status = .unavailable
            currentDevice = nil
            return
        }

        listenerInstalled = true
        status = .running
        refresh(notifyEvenIfUnchanged: true)
    }

    public func stop() {
        guard status == .running else {
            currentDevice = nil
            return
        }

        if listenerInstalled {
            var address = defaultOutputAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                systemObjectID,
                &address,
                listenerQueue,
                listenerBlock
            )
            listenerInstalled = false
        }

        status = .stopped
        currentDevice = nil
    }

    private func refreshFromListener() {
        guard status == .running else { return }
        refresh(notifyEvenIfUnchanged: false)
    }

    private func refresh(notifyEvenIfUnchanged: Bool) {
        let nextDevice = Self.readDefaultOutputDevice()
        guard notifyEvenIfUnchanged || nextDevice != currentDevice else { return }

        currentDevice = nextDevice
        onDeviceUpdate?(nextDevice)
    }

    private static func readDefaultOutputDevice() -> MediaOutputDevice? {
        guard let deviceID = readObjectID(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ), deviceID != kAudioObjectUnknown else {
            return nil
        }

        let uid = readString(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        let name = readString(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )

        // A device without either stable identity or a displayable name is
        // not useful to the media surface and should not become fake state.
        guard uid != nil || name != nil else { return nil }
        return MediaOutputDevice(identifier: uid, name: name)
    }

    private static func readObjectID(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> AudioObjectID? {
        var mutableAddress = address
        var value = AudioObjectID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &byteCount,
                pointer
            )
        }
        guard status == noErr, byteCount >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return nil
        }
        return value
    }

    private static func readString(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> String? {
        var mutableAddress = address
        var unmanagedValue: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedValue) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &byteCount,
                pointer
            )
        }
        guard status == noErr, let unmanagedValue else { return nil }

        let value = unmanagedValue.takeUnretainedValue() as String
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
