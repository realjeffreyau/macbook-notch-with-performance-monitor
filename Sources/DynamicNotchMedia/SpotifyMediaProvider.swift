import AppKit
import Foundation

/// The fields Spotify exposes through its local scripting dictionary. Artwork
/// is represented by its local-cache key; the provider never contacts the
/// Spotify Web API or resolves the URL over the network.
public struct SpotifyPlaybackSnapshot: Equatable, Sendable {
    public let identifier: String?
    public let title: String?
    public let artist: String?
    public let duration: TimeInterval?
    public let elapsedTime: TimeInterval?
    public let playbackState: MediaPlaybackState
    public let artworkURL: URL?

    public init(
        identifier: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        duration: TimeInterval? = nil,
        elapsedTime: TimeInterval? = nil,
        playbackState: MediaPlaybackState = .unknown,
        artworkURL: URL? = nil
    ) {
        self.identifier = Self.cleaned(identifier)
        self.title = Self.cleaned(title)
        self.artist = Self.cleaned(artist)
        self.duration = Self.validNumber(duration)
        self.elapsedTime = Self.validNumber(elapsedTime)
        self.playbackState = playbackState
        self.artworkURL = Self.validArtworkURL(artworkURL)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validNumber(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func validArtworkURL(_ value: URL?) -> URL? {
        guard let value,
              let scheme = value.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              value.host != nil
        else {
            return nil
        }
        return value
    }
}

public enum SpotifyAppleEventsError: Error, Equatable, Sendable {
    case targetUnavailable
    case permissionDenied
    case scriptUnavailable
    case malformedResponse
    case unsupported
    case executionFailed
}

/// External Apple Events are isolated behind this protocol so tests never
/// target a real application and production can keep the boundary explicit.
@MainActor
public protocol SpotifyAppleEventsClient: AnyObject {
    var isTargetRunning: Bool { get }

    func readSnapshot() -> Result<SpotifyPlaybackSnapshot?, SpotifyAppleEventsError>
    func send(_ command: MediaCommand) -> Result<Void, SpotifyAppleEventsError>
}

/// The notification source is separate from the Apple Events client. Starting
/// it installs one observer; it never creates periodic sampling work.
@MainActor
public protocol SpotifyPlaybackNotificationSource: AnyObject {
    func start(handler: @escaping () -> Void)
    func stop()
}

public enum SpotifyMediaSessionMapper {
    public static func session(
        from snapshot: SpotifyPlaybackSnapshot,
        observedAt: Date,
        commandsEnabled: Bool = false,
        artwork: MediaArtwork? = nil
    ) -> MediaSession? {
        // A position of zero is returned even when Spotify has no current
        // track. Require at least one track identity field so that an empty
        // player cannot become a synthetic `spotify-current` session.
        guard snapshot.identifier != nil || snapshot.title != nil || snapshot.artist != nil else {
            return nil
        }

        let identifier = snapshot.identifier
            ?? [snapshot.title, snapshot.artist].compactMap { $0 }.joined(separator: " - ")
            .ifEmpty(default: "spotify-current")
        let isPlaying = snapshot.playbackState == .playing
        let capabilities = commandsEnabled
            ? MediaCapabilities(
                canPlay: true,
                canPause: true,
                canTogglePlayPause: true,
                canPrevious: true,
                canNext: true
            )
            : MediaCapabilities()

        return MediaSession(
            id: identifier,
            title: snapshot.title,
            artistOrChannel: snapshot.artist,
            artwork: artwork,
            duration: snapshot.duration,
            elapsedTime: snapshot.elapsedTime ?? 0,
            observedAt: observedAt,
            playbackRate: isPlaying ? 1 : 0,
            playbackState: snapshot.playbackState,
            sourceApplication: MediaSourceApplication(
                displayIdentifier: "com.spotify.client",
                displayName: "Spotify"
            ),
            capabilities: capabilities
        )
    }
}

/// A Spotify provider is deliberately opt-in. Constructing it and the default
/// factory do not send Apple Events, ask for Automation permission, or observe
/// Spotify. Callers must explicitly enable it, and commands require a second
/// explicit opt-in.
@MainActor
public final class SpotifyMediaProvider: MediaProvider {
    public let identifier = "spotify-apple-events"
    public let isEnabled: Bool
    public let commandsEnabled: Bool
    public private(set) var status: MediaProviderStatus
    public private(set) var currentSession: MediaSession?
    public private(set) var lastError: SpotifyAppleEventsError?
    public weak var delegate: (any MediaProviderDelegate)?

    private let client: any SpotifyAppleEventsClient
    private let notifications: any SpotifyPlaybackNotificationSource
    private let artworkResolver: any SpotifyArtworkResolver
    private var artworkLoadTask: Task<Void, Never>?
    private var artworkLoadKey: String?

    public init(
        enabled: Bool = false,
        commandsEnabled: Bool = false,
        client: any SpotifyAppleEventsClient = SpotifyAppleEventsClientImplementation(),
        notifications: any SpotifyPlaybackNotificationSource = SpotifyDistributedNotificationSource(),
        artworkResolver: any SpotifyArtworkResolver = SpotifyLocalArtworkResolver()
    ) {
        isEnabled = enabled
        self.commandsEnabled = enabled && commandsEnabled
        self.client = client
        self.notifications = notifications
        self.artworkResolver = artworkResolver
        status = .stopped
        if enabled && !client.isTargetRunning {
            status = .unavailable
        }
    }

    public func start() {
        guard isEnabled else { return }
        guard status != .running else { return }
        guard client.isTargetRunning else {
            status = .unavailable
            return
        }

        status = .running
        notifications.start { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    public func stop() {
        guard status == .running else { return }
        notifications.stop()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        artworkLoadKey = nil
        status = .stopped
        lastError = nil
        publish(nil)
    }

    /// Performs one read only when the caller explicitly requests it. Event
    /// callbacks call the same method; there is no background sampling path.
    public func refresh() {
        guard status == .running else { return }

        switch client.readSnapshot() {
        case let .success(snapshot):
            lastError = nil
            let session: MediaSession? = snapshot.flatMap { snapshot -> MediaSession? in
                guard let mappedSession = SpotifyMediaSessionMapper.session(
                    from: snapshot,
                    observedAt: Date(),
                    commandsEnabled: commandsEnabled
                ) else {
                    return nil
                }
                guard mappedSession.id == currentSession?.id else {
                    return mappedSession
                }
                return mappedSession.withArtwork(currentSession?.artwork)
            }
            publish(session)
            scheduleArtworkLoad(for: session, snapshot: snapshot)
        case let .failure(error):
            lastError = error
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadKey = nil
            if error == .permissionDenied || error == .targetUnavailable {
                status = .unavailable
                notifications.stop()
            }
            publish(nil)
        }
    }

    public func send(_ command: MediaCommand) -> Result<Void, MediaProviderError> {
        guard isEnabled else { return .failure(.permissionRequired) }
        guard commandsEnabled else { return .failure(.permissionRequired) }
        guard status == .running else {
            return .failure(status == .unavailable ? .unavailable : .notStarted)
        }
        guard let session = currentSession else { return .failure(.noSession) }
        guard session.capabilities.supports(command) else { return .failure(.unsupported) }

        switch client.send(command) {
        case .success:
            return .success(())
        case .failure(.permissionDenied):
            markUnavailable(after: .permissionDenied)
            return .failure(.permissionRequired)
        case .failure(.targetUnavailable):
            markUnavailable(after: .targetUnavailable)
            return .failure(.unavailable)
        case .failure(.unsupported):
            return .failure(.unsupported)
        case let .failure(error):
            return .failure(.failed(String(describing: error)))
        }
    }

    private func publish(_ session: MediaSession?) {
        currentSession = session
        delegate?.mediaProvider(self, didUpdate: session)
    }

    private func scheduleArtworkLoad(
        for session: MediaSession?,
        snapshot: SpotifyPlaybackSnapshot?
    ) {
        guard let session,
              let artworkURL = snapshot?.artworkURL
        else {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadKey = nil
            return
        }

        let key = "\(session.id)|\(artworkURL.absoluteString)"
        guard session.artwork == nil, artworkLoadKey != key else { return }

        artworkLoadTask?.cancel()
        artworkLoadKey = key
        let resolver = artworkResolver
        artworkLoadTask = Task { [weak self] in
            let artwork = await resolver.artwork(for: artworkURL)
            guard !Task.isCancelled else { return }
            self?.applyLoadedArtwork(artwork, sessionID: session.id, loadKey: key)
        }
    }

    private func applyLoadedArtwork(
        _ artwork: MediaArtwork?,
        sessionID: String,
        loadKey: String
    ) {
        guard status == .running,
              artworkLoadKey == loadKey,
              let session = currentSession,
              session.id == sessionID,
              let artwork
        else {
            return
        }

        artworkLoadTask = nil
        let enrichedSession = session.withArtwork(artwork)
        guard enrichedSession != session else { return }
        currentSession = enrichedSession
        delegate?.mediaProvider(self, didUpdate: enrichedSession)
    }

    private func markUnavailable(after error: SpotifyAppleEventsError) {
        lastError = error
        status = .unavailable
        notifications.stop()
        publish(nil)
    }
}

/// Uses the one playback-state notification embedded in the installed Spotify
/// binary. The notification is only a wake-up; metadata is read through the
/// injected Apple Events client and never taken from notification userInfo.
@MainActor
public final class SpotifyDistributedNotificationSource: NSObject, SpotifyPlaybackNotificationSource {
    public static let playbackStateChangedNotification =
        Notification.Name("com.spotify.client.PlaybackStateChanged")

    private let center: DistributedNotificationCenter
    private var handler: (() -> Void)?
    private var isObserving = false

    public init(center: DistributedNotificationCenter = .default()) {
        self.center = center
    }

    public func start(handler: @escaping () -> Void) {
        guard !isObserving else { return }
        self.handler = handler
        center.addObserver(
            self,
            selector: #selector(notificationReceived(_:)),
            name: Self.playbackStateChangedNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        isObserving = true
    }

    public func stop() {
        guard isObserving else {
            handler = nil
            return
        }
        center.removeObserver(self, name: Self.playbackStateChangedNotification, object: nil)
        isObserving = false
        handler = nil
    }

    @objc private func notificationReceived(_ notification: Notification) {
        // Distributed notifications may arrive off-main. Hop once to the
        // provider's actor; this is event delivery, not a polling mechanism.
        DispatchQueue.main.async { [weak self] in
            self?.handler?()
        }
    }
}

/// Production Apple Events implementation. It reads only Spotify's local
/// scripting dictionary fields. Artwork is later resolved from Spotify's
/// on-disk cache, never over the network.
@MainActor
public final class SpotifyAppleEventsClientImplementation: SpotifyAppleEventsClient {
    public static let bundleIdentifier = "com.spotify.client"

    // Keep this source read-only. Each field is guarded independently so an
    // unavailable optional Spotify property does not discard the rest of a
    // usable track snapshot. The returned list has seven positions;
    // `missing value` is decoded as nil below.
    private static let snapshotScript = """
    tell application id "com.spotify.client"
        set currentTrack to missing value
        set trackIdentifier to missing value
        set trackName to missing value
        set trackArtist to missing value
        set trackDuration to missing value
        set trackPosition to missing value
        set currentState to missing value
        set trackArtworkURL to missing value

        try
            set currentTrack to current track
        end try

        if currentTrack is not missing value then
            try
                set trackIdentifier to id of currentTrack as text
            end try
            try
                set trackName to name of currentTrack as text
            end try
            try
                set trackArtist to artist of currentTrack as text
            end try
            try
                set trackDuration to duration of currentTrack as real
            end try
            try
                set trackArtworkURL to artwork url of currentTrack as text
            end try
        end if

        try
            set trackPosition to player position as real
        end try
        try
            set currentState to player state as text
        end try

        return {trackIdentifier, trackName, trackArtist, trackDuration, trackPosition, currentState, trackArtworkURL}
    end tell
    """

    public init() {}

    public var isTargetRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).isEmpty
    }

    public func readSnapshot() -> Result<SpotifyPlaybackSnapshot?, SpotifyAppleEventsError> {
        guard isTargetRunning else { return .failure(.targetUnavailable) }
        guard let script = NSAppleScript(source: Self.snapshotScript) else {
            return .failure(.scriptUnavailable)
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil {
            return .failure(Self.error(from: error))
        }
        return Self.decode(result)
    }

    public func send(_ command: MediaCommand) -> Result<Void, SpotifyAppleEventsError> {
        guard isTargetRunning else { return .failure(.targetUnavailable) }
        let commandSource: String
        switch command {
        case .play:
            commandSource = "play"
        case .pause:
            commandSource = "pause"
        case .togglePlayPause:
            commandSource = "playpause"
        case .previous:
            commandSource = "previous track"
        case .next:
            commandSource = "next track"
        case .seek:
            return .failure(.unsupported)
        }

        let source = "tell application id \"com.spotify.client\" to " + commandSource
        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptUnavailable)
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if error != nil {
            return .failure(Self.error(from: error))
        }
        return .success(())
    }

    private static func decode(
        _ descriptor: NSAppleEventDescriptor
    ) -> Result<SpotifyPlaybackSnapshot?, SpotifyAppleEventsError> {
        guard descriptor.descriptorType == typeAEList else {
            return .failure(.malformedResponse)
        }
        guard descriptor.numberOfItems > 0 else { return .success(nil) }
        guard descriptor.numberOfItems >= 6 else {
            return .failure(.malformedResponse)
        }

        let identifier = string(at: 1, in: descriptor)
        let title = string(at: 2, in: descriptor)
        let artist = string(at: 3, in: descriptor)
        let elapsedTime = number(at: 5, in: descriptor)
        // Spotify's current Tahoe build returns the track's documented
        // seconds field as milliseconds (for example, 212565 for a roughly
        // 212.565-second track). Keep the provider contract in seconds while
        // accepting the older/documented representation as well.
        let duration = normalizedDuration(number(at: 4, in: descriptor), elapsedTime: elapsedTime)
        let state = playbackState(at: 6, in: descriptor)
        let artworkURL = string(at: 7, in: descriptor).flatMap(URL.init(string:))
        guard identifier != nil || title != nil || artist != nil || duration != nil
                || elapsedTime != nil
        else {
            return .success(nil)
        }

        return .success(SpotifyPlaybackSnapshot(
            identifier: identifier,
            title: title,
            artist: artist,
            duration: duration,
            elapsedTime: elapsedTime,
            playbackState: state,
            artworkURL: artworkURL
        ))
    }

    private static func string(at index: Int, in descriptor: NSAppleEventDescriptor) -> String? {
        guard let value = descriptor.atIndex(index), value.descriptorType != typeNull else {
            return nil
        }
        let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return string?.isEmpty == false ? string : nil
    }

    private static func number(at index: Int, in descriptor: NSAppleEventDescriptor) -> Double? {
        guard let value = descriptor.atIndex(index), value.descriptorType != typeNull else {
            return nil
        }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    static func normalizedDuration(_ value: TimeInterval?, elapsedTime: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }

        // A normal song/podcast duration expressed in seconds is well below
        // one day. Values above that threshold are treated as milliseconds
        // only when converting them produces a finite, positive value that
        // still contains the observed playback position. This avoids
        // needlessly changing the documented seconds representation.
        guard value > 86_400 else { return value }
        let seconds = value / 1_000
        guard seconds.isFinite, seconds >= 0 else {
            return value
        }
        if let elapsedTime, seconds < elapsedTime {
            return value
        }
        return seconds
    }

    private static func playbackState(
        at index: Int,
        in descriptor: NSAppleEventDescriptor
    ) -> MediaPlaybackState {
        switch string(at: index, in: descriptor)?.lowercased() {
        case "playing":
            .playing
        case "paused":
            .paused
        case "stopped":
            .stopped
        default:
            .unknown
        }
    }

    private static func error(from error: NSDictionary?) -> SpotifyAppleEventsError {
        guard let code = error?[NSAppleScript.errorNumber] as? NSNumber else {
            return .executionFailed
        }
        switch code.intValue {
        case -1743, -1744:
            return .permissionDenied
        case -600, -609:
            return .targetUnavailable
        default:
            return .executionFailed
        }
    }
}

private extension String {
    func ifEmpty(default fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
