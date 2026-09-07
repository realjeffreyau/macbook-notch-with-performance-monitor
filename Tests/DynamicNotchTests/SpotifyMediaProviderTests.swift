import Foundation
import Testing
@testable import DynamicNotchMedia

@Test("Spotify artwork cache extracts only the image body after its URL key")
func spotifyArtworkCacheExtractsJPEGBody() {
    let key = Data("https://i.scdn.co/image/test-artwork".utf8)
    let jpeg = Data([0xff, 0xd8, 0xff, 0x01, 0x02, 0xff, 0xd9])
    let cacheEntry = Data("cache-header".utf8) + key + jpeg + Data("cache-footer".utf8)

    let artwork = SpotifyArtworkCache.extractArtwork(from: cacheEntry, matching: key)

    #expect(artwork?.mimeType == "image/jpeg")
    #expect(artwork?.data == jpeg)
}

@Test("Spotify artwork cache accepts a cached size variant")
func spotifyArtworkCacheAcceptsSizeVariant() throws {
    let requestedURL = URL(string: "https://i.scdn.co/image/ab67616d0000b273d040bc5b46915b49a64d7b1d")!
    let cachedURL = Data("https://i.scdn.co/image/ab67616d00001e02d040bc5b46915b49a64d7b1d".utf8)
    let jpeg = Data([0xff, 0xd8, 0xff, 0x03, 0x04, 0xff, 0xd9])
    let cacheEntry = Data("cache-header".utf8) + cachedURL + jpeg + Data("cache-footer".utf8)
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dynamic-notch-spotify-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    try cacheEntry.write(to: cacheDirectory.appendingPathComponent("artwork-entry"))

    let artwork = SpotifyArtworkCache.artwork(for: requestedURL, cacheDirectory: cacheDirectory)

    #expect(requestedURL.path.hasSuffix("d040bc5b46915b49a64d7b1d"))
    #expect(artwork?.mimeType == "image/jpeg")
    #expect(artwork?.data == jpeg)
}

@Test("Spotify snapshot mapping preserves metadata and remains read-only by default")
func spotifySnapshotMappingPreservesMetadata() {
    let snapshot = SpotifyPlaybackSnapshot(
        identifier: "spotify:track:test",
        title: "Title",
        artist: "Artist",
        duration: 180,
        elapsedTime: 12.5,
        playbackState: .playing
    )

    let session = SpotifyMediaSessionMapper.session(
        from: snapshot,
        observedAt: Date(timeIntervalSinceReferenceDate: 100)
    )

    #expect(session?.id == "spotify:track:test")
    #expect(session?.title == "Title")
    #expect(session?.artistOrChannel == "Artist")
    #expect(session?.duration == 180)
    #expect(session?.elapsedTime == 12.5)
    #expect(session?.playbackState == .playing)
    #expect(session?.sourceApplication.displayIdentifier == "com.spotify.client")
    #expect(session?.capabilities == MediaCapabilities())
}

@Test("Spotify Tahoe duration values are normalized from milliseconds")
@MainActor
func spotifyTahoeDurationIsNormalized() {
    let duration = SpotifyAppleEventsClientImplementation.normalizedDuration(
        212_565,
        elapsedTime: 1.13
    )

    #expect(duration != nil)
    #expect(abs(duration! - 212.565) < 0.000_001)
    #expect(
        SpotifyAppleEventsClientImplementation.normalizedDuration(
            212,
            elapsedTime: 1.13
        ) == 212
    )
}

@Test("empty Spotify snapshots do not create a fake session")
func emptySpotifySnapshotDoesNotCreateSession() {
    let snapshot = SpotifyPlaybackSnapshot(playbackState: .stopped)

    #expect(SpotifyMediaSessionMapper.session(
        from: snapshot,
        observedAt: Date()
    ) == nil)

    let positionOnlySnapshot = SpotifyPlaybackSnapshot(
        elapsedTime: 0,
        playbackState: .stopped
    )
    #expect(SpotifyMediaSessionMapper.session(
        from: positionOnlySnapshot,
        observedAt: Date()
    ) == nil)
}

@Test("disabled Spotify provider performs no observation or Apple Events")
@MainActor
func disabledSpotifyProviderIsIdle() {
    let client = MockSpotifyAppleEventsClient()
    let notifications = MockSpotifyNotificationSource()
    let provider = SpotifyMediaProvider(client: client, notifications: notifications)

    provider.start()

    #expect(provider.isEnabled == false)
    #expect(provider.status == .stopped)
    #expect(client.readCount == 0)
    #expect(notifications.startCount == 0)
    #expect(isFailure(provider.send(.play), .permissionRequired))
}

@Test("explicit Spotify activation is one-shot and event driven")
@MainActor
func explicitSpotifyActivationIsEventDriven() {
    let client = MockSpotifyAppleEventsClient(snapshot: SpotifyPlaybackSnapshot(
        identifier: "track",
        title: "Title",
        playbackState: .paused
    ))
    let notifications = MockSpotifyNotificationSource()
    let delegate = MockSpotifyProviderDelegate()
    let provider = SpotifyMediaProvider(
        enabled: true,
        client: client,
        notifications: notifications
    )
    provider.delegate = delegate

    provider.start()
    provider.start()
    #expect(provider.status == .running)
    #expect(client.readCount == 1)
    #expect(notifications.startCount == 1)
    #expect(provider.currentSession?.id == "track")

    notifications.emit()
    #expect(client.readCount == 2)

    provider.stop()
    #expect(provider.status == .stopped)
    #expect(notifications.stopCount == 1)
    #expect(delegate.updates.last! == nil)

    notifications.emit()
    #expect(client.readCount == 2)
}

@Test("Spotify no-session result stays running without publishing metadata")
@MainActor
func spotifyNoSessionResult() {
    let client = MockSpotifyAppleEventsClient(snapshot: nil)
    let notifications = MockSpotifyNotificationSource()
    let delegate = MockSpotifyProviderDelegate()
    let provider = SpotifyMediaProvider(
        enabled: true,
        client: client,
        notifications: notifications
    )
    provider.delegate = delegate

    provider.start()

    #expect(provider.status == .running)
    #expect(provider.currentSession == nil)
    #expect(delegate.updates.last! == nil)
    #expect(provider.lastError == nil)
}

@Test("Spotify permission failure disables the active observation")
@MainActor
func spotifyPermissionFailure() {
    let client = MockSpotifyAppleEventsClient(
        readResult: .failure(.permissionDenied)
    )
    let notifications = MockSpotifyNotificationSource()
    let provider = SpotifyMediaProvider(
        enabled: true,
        client: client,
        notifications: notifications
    )

    provider.start()

    #expect(provider.status == .unavailable)
    #expect(provider.lastError == .permissionDenied)
    #expect(notifications.startCount == 1)
    #expect(notifications.stopCount == 1)

    notifications.emit()
    #expect(client.readCount == 1)
}

@Test("malformed Spotify responses clear metadata without stopping observation")
@MainActor
func spotifyMalformedResponse() {
    let client = MockSpotifyAppleEventsClient(
        readResult: .failure(.malformedResponse)
    )
    let notifications = MockSpotifyNotificationSource()
    let delegate = MockSpotifyProviderDelegate()
    let provider = SpotifyMediaProvider(
        enabled: true,
        client: client,
        notifications: notifications
    )
    provider.delegate = delegate

    provider.start()

    #expect(provider.status == .running)
    #expect(provider.currentSession == nil)
    #expect(provider.lastError == .malformedResponse)
    #expect(notifications.startCount == 1)
    #expect(notifications.stopCount == 0)
    #expect(delegate.updates.last! == nil)
}

@Test("Spotify commands require a separate explicit opt-in")
@MainActor
func spotifyCommandsNeedExplicitOptIn() {
    let snapshot = SpotifyPlaybackSnapshot(
        identifier: "track",
        title: "Title",
        playbackState: .playing
    )
    let readOnlyClient = MockSpotifyAppleEventsClient(snapshot: snapshot)
    let readOnlyProvider = SpotifyMediaProvider(
        enabled: true,
        client: readOnlyClient,
        notifications: MockSpotifyNotificationSource()
    )
    readOnlyProvider.start()

    #expect(readOnlyProvider.currentSession?.capabilities.canPause == false)
    #expect(isFailure(readOnlyProvider.send(.pause), .permissionRequired))
    #expect(readOnlyClient.sentCommands.isEmpty)

    let commandClient = MockSpotifyAppleEventsClient(snapshot: snapshot)
    let commandProvider = SpotifyMediaProvider(
        enabled: true,
        commandsEnabled: true,
        client: commandClient,
        notifications: MockSpotifyNotificationSource()
    )
    commandProvider.start()

    #expect(commandProvider.currentSession?.capabilities.canPause == true)
    #expect(isSuccess(commandProvider.send(.pause)))
    #expect(commandClient.sentCommands == [.pause])
}

@Test("Spotify target absence never starts an observer")
@MainActor
func spotifyTargetAbsenceIsUnavailable() {
    let client = MockSpotifyAppleEventsClient(targetIsRunning: false)
    let notifications = MockSpotifyNotificationSource()
    let provider = SpotifyMediaProvider(
        enabled: true,
        client: client,
        notifications: notifications
    )

    provider.start()

    #expect(provider.status == .unavailable)
    #expect(notifications.startCount == 0)
    #expect(client.readCount == 0)
}

@MainActor
private final class MockSpotifyAppleEventsClient: SpotifyAppleEventsClient {
    var isTargetRunning: Bool
    var readResult: Result<SpotifyPlaybackSnapshot?, SpotifyAppleEventsError>
    var sendResult: Result<Void, SpotifyAppleEventsError> = .success(())
    private(set) var readCount = 0
    private(set) var sentCommands: [MediaCommand] = []

    init(
        targetIsRunning: Bool = true,
        snapshot: SpotifyPlaybackSnapshot? = nil,
        readResult: Result<SpotifyPlaybackSnapshot?, SpotifyAppleEventsError>? = nil
    ) {
        isTargetRunning = targetIsRunning
        self.readResult = readResult ?? .success(snapshot)
    }

    func readSnapshot() -> Result<SpotifyPlaybackSnapshot?, SpotifyAppleEventsError> {
        readCount += 1
        return readResult
    }

    func send(_ command: MediaCommand) -> Result<Void, SpotifyAppleEventsError> {
        sentCommands.append(command)
        return sendResult
    }
}

@MainActor
private final class MockSpotifyNotificationSource: SpotifyPlaybackNotificationSource {
    private var handler: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(handler: @escaping () -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit() {
        handler?()
    }
}

@MainActor
private final class MockSpotifyProviderDelegate: MediaProviderDelegate {
    private(set) var updates: [MediaSession?] = []

    func mediaProvider(_ provider: any MediaProvider, didUpdate session: MediaSession?) {
        updates.append(session)
    }
}

private func isSuccess(_ result: Result<Void, MediaProviderError>) -> Bool {
    if case .success = result { return true }
    return false
}

private func isFailure(
    _ result: Result<Void, MediaProviderError>,
    _ expected: MediaProviderError
) -> Bool {
    guard case let .failure(error) = result else { return false }
    return error == expected
}
