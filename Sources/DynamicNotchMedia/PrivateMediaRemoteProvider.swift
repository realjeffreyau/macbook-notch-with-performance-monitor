import Foundation
import MediaRemoteBridge

/// Maps only the MediaRemote keys that have been observed in the Tahoe
/// runtime. The mapper is deliberately pure so malformed private-framework
/// dictionaries cannot affect the rest of the app.
public struct MediaRemoteInfoMapper {
    private static let titleKey = "kMRMediaRemoteNowPlayingInfoTitle"
    private static let artistKey = "kMRMediaRemoteNowPlayingInfoArtist"
    private static let uniqueIdentifierKey = "kMRMediaRemoteNowPlayingInfoUniqueIdentifier"
    private static let artworkDataKey = "kMRMediaRemoteNowPlayingInfoArtworkData"
    private static let artworkMIMETypeKey = "kMRMediaRemoteNowPlayingInfoArtworkMIMEType"
    private static let durationKey = "kMRMediaRemoteNowPlayingInfoDuration"
    private static let elapsedTimeKey = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    private static let playbackRateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

    public static func session(
        from info: [String: Any],
        sourceDisplayIdentifier: String?,
        sourceProcessIdentifier: Int32,
        observedAt: Date
    ) -> MediaSession? {
        let title = string(for: titleKey, in: info)
        let artist = string(for: artistKey, in: info)
        let uniqueIdentifier = string(for: uniqueIdentifierKey, in: info)
        let artwork = artwork(from: info)
        let duration = number(for: durationKey, in: info)
        let elapsedTime = number(for: elapsedTimeKey, in: info) ?? 0
        let playbackRate = number(for: playbackRateKey, in: info)

        // Do not turn an unrelated or malformed notification into a fake
        // session. At least one familiar value must be usable.
        guard title != nil || artist != nil || uniqueIdentifier != nil || artwork != nil
                || duration != nil || number(for: elapsedTimeKey, in: info) != nil
                || playbackRate != nil
        else {
            return nil
        }

        let sourceApplication = MediaSourceApplication(
            displayIdentifier: sourceDisplayIdentifier,
            processIdentifier: sourceProcessIdentifier > 0 ? sourceProcessIdentifier : nil
        )
        let identifier = uniqueIdentifier
            ?? sourceDisplayIdentifier
            ?? [title, artist].compactMap { $0 }.joined(separator: " - ")
            .ifEmpty(default: "media-remote-current")
        let playbackState: MediaPlaybackState
        if let playbackRate {
            playbackState = playbackRate > 0 ? .playing : .paused
        } else {
            playbackState = .unknown
        }

        return MediaSession(
            id: identifier,
            title: title,
            artistOrChannel: artist,
            artwork: artwork,
            duration: duration,
            elapsedTime: elapsedTime,
            observedAt: observedAt,
            playbackRate: playbackRate ?? 0,
            playbackState: playbackState,
            sourceApplication: sourceApplication,
            outputDevice: nil,
            // The supported-command callback ABI is private and was not
            // safely verified. False is safer than claiming control support.
            capabilities: MediaCapabilities()
        )
    }

    private static func string(for key: String, in info: [String: Any]) -> String? {
        if let value = info[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = info[key] as? NSString {
            let trimmed = (value as String).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func number(for key: String, in info: [String: Any]) -> Double? {
        guard let value = info[key] else { return nil }
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? Double {
            number = value
        } else if let value = value as? Int {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func artwork(from info: [String: Any]) -> MediaArtwork? {
        let data: Data?
        if let value = info[artworkDataKey] as? NSData {
            guard value.length <= MediaArtwork.maxByteCount else { return nil }
            data = value as Data
        } else if let value = info[artworkDataKey] as? Data {
            guard value.count <= MediaArtwork.maxByteCount else { return nil }
            data = value
        } else {
            data = nil
        }

        guard let data else { return nil }
        return MediaArtwork(data: data, mimeType: string(for: artworkMIMETypeKey, in: info))
    }
}

@MainActor
public final class PrivateMediaRemoteProvider: MediaProvider {
    public let identifier = "system-media-remote"
    public private(set) var status: MediaProviderStatus
    public private(set) var currentSession: MediaSession?
    public weak var delegate: (any MediaProviderDelegate)?

    private let bridge: MediaRemoteBridgeOwner

    public init() {
        bridge = MediaRemoteBridgeOwner()
        status = bridge.isAvailable ? .stopped : .unavailable
    }

    public func start() {
        guard status != .running else { return }
        guard bridge.isAvailable else {
            status = .unavailable
            return
        }

        status = .running
        bridge.start(
            callback: Self.updateCallback,
            context: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    public func stop() {
        guard status == .running else { return }
        bridge.stop()
        status = .stopped
        currentSession = nil
        delegate?.mediaProvider(self, didUpdate: nil)
    }

    public func send(_ command: MediaCommand) -> Result<Void, MediaProviderError> {
        guard status == .running else {
            return .failure(status == .unavailable ? .unavailable : .notStarted)
        }
        guard let session = currentSession else { return .failure(.noSession) }
        guard session.capabilities.supports(command) else { return .failure(.unsupported) }

        let rawCommand: Int32
        let position: Double
        let hasPosition: Bool
        switch command {
        case .play:
            rawCommand = Int32(DNMediaRemoteCommandPlay.rawValue)
            position = 0
            hasPosition = false
        case .pause:
            rawCommand = Int32(DNMediaRemoteCommandPause.rawValue)
            position = 0
            hasPosition = false
        case .togglePlayPause:
            rawCommand = Int32(DNMediaRemoteCommandTogglePlayPause.rawValue)
            position = 0
            hasPosition = false
        case .previous:
            rawCommand = Int32(DNMediaRemoteCommandPreviousTrack.rawValue)
            position = 0
            hasPosition = false
        case .next:
            rawCommand = Int32(DNMediaRemoteCommandNextTrack.rawValue)
            position = 0
            hasPosition = false
        case let .seek(positionValue):
            guard positionValue.isFinite else { return .failure(.failed("invalid seek position")) }
            rawCommand = Int32(DNMediaRemoteCommandSeekToPlaybackPosition.rawValue)
            position = positionValue
            hasPosition = true
        }

        guard bridge.sendCommand(
            rawCommand,
            playbackPosition: position,
            hasPlaybackPosition: hasPosition
        ) else {
            return .failure(.failed("MediaRemote rejected the command"))
        }
        return .success(())
    }

    private static let updateCallback: DNMediaRemoteInfoCallback = {
        info,
        sourceDisplayIdentifier,
        sourceProcessIdentifier,
        context in
        guard let context else { return }
        let provider = Unmanaged<PrivateMediaRemoteProvider>
            .fromOpaque(context)
            .takeUnretainedValue()
        let session = PrivateMediaRemoteProvider.mapSession(
            info: info,
            sourceDisplayIdentifier: sourceDisplayIdentifier,
            sourceProcessIdentifier: sourceProcessIdentifier
        )

        // The bridge always schedules callbacks on the main queue. This
        // assertion keeps the provider's lifecycle and delegate synchronous.
        MainActor.assumeIsolated {
            provider.receive(session: session)
        }
    }

    private static func mapSession(
        info: CFDictionary?,
        sourceDisplayIdentifier: CFString?,
        sourceProcessIdentifier: Int32
    ) -> MediaSession? {
        guard let info else {
            return nil
        }

        let dictionary = info as NSDictionary
        var values: [String: Any] = [:]
        values.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            if let key = key as? String {
                values[key] = value
            }
        }

        let sourceIdentifier = sourceDisplayIdentifier.map { $0 as String }
        return MediaRemoteInfoMapper.session(
            from: values,
            sourceDisplayIdentifier: sourceIdentifier,
            sourceProcessIdentifier: sourceProcessIdentifier,
            observedAt: Date()
        )
    }

    private func receive(session: MediaSession?) {
        guard status == .running else { return }
        publish(session)
    }

    private func publish(_ session: MediaSession?) {
        currentSession = session
        delegate?.mediaProvider(self, didUpdate: session)
    }
}

/// Owns the C bridge and balances its dynamic framework handle and observers.
/// `@unchecked Sendable` is limited to teardown because the provider itself is
/// main-actor isolated and never shares this owner with another actor.
private final class MediaRemoteBridgeOwner: @unchecked Sendable {
    private let pointer: OpaquePointer?

    init() {
        pointer = DNMediaRemoteBridgeCreate()
    }

    var isAvailable: Bool {
        guard let pointer else { return false }
        return DNMediaRemoteBridgeIsAvailable(pointer)
    }

    func start(callback: DNMediaRemoteInfoCallback, context: UnsafeMutableRawPointer) {
        guard let pointer else { return }
        DNMediaRemoteBridgeStart(pointer, callback, context)
    }

    func stop() {
        guard let pointer else { return }
        DNMediaRemoteBridgeStop(pointer)
    }

    func sendCommand(
        _ command: Int32,
        playbackPosition: Double,
        hasPlaybackPosition: Bool
    ) -> Bool {
        guard let pointer else { return false }
        return DNMediaRemoteBridgeSendCommand(
            pointer,
            command,
            playbackPosition,
            hasPlaybackPosition
        )
    }

    deinit {
        if let pointer {
            DNMediaRemoteBridgeDestroy(pointer)
        }
    }
}

private extension String {
    func ifEmpty(default fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
