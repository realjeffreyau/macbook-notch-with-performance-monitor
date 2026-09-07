import Foundation

public enum MediaPlaybackState: String, Equatable, Hashable, Sendable {
    case unknown
    case stopped
    case paused
    case playing
}

public struct MediaSourceApplication: Equatable, Hashable, Sendable {
    public let displayIdentifier: String?
    public let processIdentifier: Int32?
    public let displayName: String?

    public init(
        displayIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        displayName: String? = nil
    ) {
        self.displayIdentifier = displayIdentifier
        self.processIdentifier = processIdentifier
        self.displayName = displayName
    }

    public static let unknown = MediaSourceApplication()
}

public struct MediaArtwork: Equatable, Sendable {
    public static let maxByteCount = 1_048_576

    public let data: Data
    public let mimeType: String?

    public init?(data: Data, mimeType: String? = nil, maxByteCount: Int = Self.maxByteCount) {
        guard !data.isEmpty, maxByteCount > 0, data.count <= maxByteCount else {
            return nil
        }

        self.data = data
        self.mimeType = mimeType?.isEmpty == false ? mimeType : nil
    }
}

public struct MediaOutputDevice: Equatable, Hashable, Sendable {
    public let identifier: String?
    public let name: String?

    public init(identifier: String? = nil, name: String? = nil) {
        self.identifier = identifier
        self.name = name
    }
}

public struct MediaCapabilities: Equatable, Sendable {
    public let canPlay: Bool
    public let canPause: Bool
    public let canTogglePlayPause: Bool
    public let canPrevious: Bool
    public let canNext: Bool
    public let canSeek: Bool

    public init(
        canPlay: Bool = false,
        canPause: Bool = false,
        canTogglePlayPause: Bool = false,
        canPrevious: Bool = false,
        canNext: Bool = false,
        canSeek: Bool = false
    ) {
        self.canPlay = canPlay
        self.canPause = canPause
        self.canTogglePlayPause = canTogglePlayPause
        self.canPrevious = canPrevious
        self.canNext = canNext
        self.canSeek = canSeek
    }

    public func supports(_ command: MediaCommand) -> Bool {
        switch command {
        case .play:
            canPlay
        case .pause:
            canPause
        case .togglePlayPause:
            canTogglePlayPause
        case .previous:
            canPrevious
        case .next:
            canNext
        case .seek:
            canSeek
        }
    }
}

public enum MediaCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case previous
    case next
    case seek(TimeInterval)
}

public enum MediaProviderError: Error, Equatable, Sendable {
    case unavailable
    case notStarted
    case permissionRequired
    case noSession
    case unsupported
    case failed(String)
}

public enum MediaProviderStatus: Equatable, Sendable {
    case stopped
    case running
    case unavailable
}

public struct MediaSession: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let artistOrChannel: String?
    public let artwork: MediaArtwork?
    public let duration: TimeInterval?
    public let elapsedTime: TimeInterval
    public let observedAt: Date
    public let playbackRate: Double
    public let playbackState: MediaPlaybackState
    public let sourceApplication: MediaSourceApplication
    public let outputDevice: MediaOutputDevice?
    public let capabilities: MediaCapabilities

    public init(
        id: String,
        title: String? = nil,
        artistOrChannel: String? = nil,
        artwork: MediaArtwork? = nil,
        duration: TimeInterval? = nil,
        elapsedTime: TimeInterval = 0,
        observedAt: Date,
        playbackRate: Double = 0,
        playbackState: MediaPlaybackState = .unknown,
        sourceApplication: MediaSourceApplication = .unknown,
        outputDevice: MediaOutputDevice? = nil,
        capabilities: MediaCapabilities = MediaCapabilities()
    ) {
        self.id = id
        self.title = title
        self.artistOrChannel = artistOrChannel
        self.artwork = artwork
        self.duration = Self.validDuration(duration)
        self.elapsedTime = Self.clamp(elapsedTime, duration: Self.validDuration(duration))
        self.observedAt = observedAt
        self.playbackRate = playbackRate.isFinite ? playbackRate : 0
        self.playbackState = playbackState
        self.sourceApplication = sourceApplication
        self.outputDevice = outputDevice
        self.capabilities = capabilities
    }

    /// Infers progress at a caller-supplied instant without starting any work.
    /// A future observation never moves progress backwards, and a non-playing
    /// session remains at the last reported position.
    public func elapsed(at date: Date) -> TimeInterval {
        let elapsed: TimeInterval
        if playbackState == .playing, playbackRate > 0 {
            let delta = max(0, date.timeIntervalSince(observedAt))
            elapsed = elapsedTime + delta * playbackRate
        } else {
            elapsed = elapsedTime
        }

        return Self.clamp(elapsed, duration: duration)
    }

    /// Returns the same provider observation with a locally observed output
    /// device attached. Output routing is an app-local overlay and must not
    /// alter the provider's identity, timestamp, playback position, or
    /// advertised command capabilities.
    public func withOutputDevice(_ outputDevice: MediaOutputDevice?) -> MediaSession {
        MediaSession(
            id: id,
            title: title,
            artistOrChannel: artistOrChannel,
            artwork: artwork,
            duration: duration,
            elapsedTime: elapsedTime,
            observedAt: observedAt,
            playbackRate: playbackRate,
            playbackState: playbackState,
            sourceApplication: sourceApplication,
            outputDevice: outputDevice,
            capabilities: capabilities
        )
    }

    /// Returns the same provider observation with locally resolved artwork
    /// attached. Artwork enrichment is deliberately separate from provider
    /// metadata so a slow or unavailable cache lookup cannot alter playback
    /// identity, timing, or command capabilities.
    public func withArtwork(_ artwork: MediaArtwork?) -> MediaSession {
        MediaSession(
            id: id,
            title: title,
            artistOrChannel: artistOrChannel,
            artwork: artwork,
            duration: duration,
            elapsedTime: elapsedTime,
            observedAt: observedAt,
            playbackRate: playbackRate,
            playbackState: playbackState,
            sourceApplication: sourceApplication,
            outputDevice: outputDevice,
            capabilities: capabilities
        )
    }

    private static func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        return duration
    }

    private static func clamp(_ value: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        if value.isNaN || value < 0 {
            return 0
        }
        if value == .infinity {
            return duration ?? .greatestFiniteMagnitude
        }

        let nonNegativeValue = max(0, value)
        guard let duration else { return nonNegativeValue }
        return min(nonNegativeValue, duration)
    }
}
