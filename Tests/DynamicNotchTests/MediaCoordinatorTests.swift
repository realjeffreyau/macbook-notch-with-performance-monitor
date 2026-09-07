import Foundation
import Testing
@testable import DynamicNotchMedia
@testable import DynamicNotch

@MainActor
private final class MockMediaProvider: MediaProvider {
    let identifier: String
    var status: MediaProviderStatus = .stopped
    var currentSession: MediaSession?
    weak var delegate: (any MediaProviderDelegate)?
    var startCount = 0
    var stopCount = 0
    var sentCommands: [MediaCommand] = []
    var sendResult: Result<Void, MediaProviderError> = .success(())

    init(identifier: String, currentSession: MediaSession? = nil) {
        self.identifier = identifier
        self.currentSession = currentSession
    }

    func start() {
        startCount += 1
        status = .running
    }

    func stop() {
        stopCount += 1
        status = .stopped
    }

    func send(_ command: MediaCommand) -> Result<Void, MediaProviderError> {
        sentCommands.append(command)
        return sendResult
    }

    func publish(_ session: MediaSession?) {
        currentSession = session
        delegate?.mediaProvider(self, didUpdate: session)
    }
}

@Test("coordinator prefers playing over newer paused metadata")
@MainActor
func coordinatorPrefersPlayingOverNewerPausedMetadata() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let playing = session(
        id: "playing",
        observedAt: now,
        state: .playing
    )
    let paused = session(
        id: "paused",
        observedAt: now.addingTimeInterval(10),
        state: .paused
    )
    let first = MockMediaProvider(identifier: "first")
    let second = MockMediaProvider(identifier: "second")
    let coordinator = MediaCoordinator(providers: [first, second])

    coordinator.start()
    first.publish(playing)
    second.publish(paused)

    #expect(coordinator.selectedProviderIdentifier == "first")
    #expect(coordinator.currentSession?.id == "playing")
}

@Test("coordinator uses observation recency and a deterministic tie break")
@MainActor
func coordinatorUsesObservationRecencyAndDeterministicTieBreak() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 100)
    let older = MockMediaProvider(identifier: "older")
    let newer = MockMediaProvider(identifier: "newer")
    let coordinator = MediaCoordinator(providers: [older, newer])

    coordinator.start()
    older.publish(session(id: "old", observedAt: observedAt, state: .paused))
    newer.publish(session(id: "new", observedAt: observedAt.addingTimeInterval(1), state: .paused))
    #expect(coordinator.selectedProviderIdentifier == "newer")

    let first = MockMediaProvider(identifier: "z-provider")
    let second = MockMediaProvider(identifier: "a-provider")
    let tieCoordinator = MediaCoordinator(providers: [first, second])
    tieCoordinator.start()
    first.publish(session(id: "z", observedAt: observedAt, state: .paused))
    second.publish(session(id: "a", observedAt: observedAt, state: .paused))

    #expect(tieCoordinator.selectedProviderIdentifier == "a-provider")
}

@Test("nil provider updates remove candidates and clear the session")
@MainActor
func nilProviderUpdatesRemoveCandidatesAndClearSession() {
    let provider = MockMediaProvider(identifier: "player")
    let coordinator = MediaCoordinator(providers: [provider])
    coordinator.start()
    provider.publish(session(id: "track", observedAt: Date(), state: .paused))
    #expect(coordinator.currentSession != nil)

    provider.publish(nil)

    #expect(coordinator.selectedProviderIdentifier == nil)
    #expect(coordinator.currentSession == nil)
    #expect(isFailure(coordinator.send(.next), .noSession))
}

@Test("commands stay bound to the selected provider and capabilities")
@MainActor
func commandsStayBoundToSelectedProviderAndCapabilities() {
    let selected = MockMediaProvider(identifier: "selected")
    let other = MockMediaProvider(identifier: "other")
    let coordinator = MediaCoordinator(providers: [selected, other])
    coordinator.start()
    selected.publish(session(
        id: "selected-track",
        observedAt: Date(timeIntervalSinceReferenceDate: 100),
        state: .playing,
        capabilities: MediaCapabilities(canPause: true)
    ))
    other.publish(session(
        id: "other-track",
        observedAt: Date(timeIntervalSinceReferenceDate: 100),
        state: .paused,
        capabilities: MediaCapabilities(canNext: true)
    ))

    #expect(coordinator.selectedProviderIdentifier == "selected")
    #expect(isSuccess(coordinator.send(.pause)))
    #expect(selected.sentCommands == [.pause])
    #expect(other.sentCommands.isEmpty)
    #expect(isFailure(coordinator.send(.next), .unsupported))
    #expect(other.sentCommands.isEmpty)
}

@Test("coordinator dispatches a supported seek only to the selected provider")
@MainActor
func coordinatorDispatchesSupportedSeekOnlyToSelectedProvider() {
    let selected = MockMediaProvider(identifier: "selected")
    let other = MockMediaProvider(identifier: "other")
    let coordinator = MediaCoordinator(providers: [selected, other])
    coordinator.start()

    selected.publish(session(
        id: "selected-track",
        observedAt: Date(timeIntervalSinceReferenceDate: 100),
        state: .playing,
        capabilities: MediaCapabilities(canSeek: true)
    ))
    other.publish(session(
        id: "other-track",
        observedAt: Date(timeIntervalSinceReferenceDate: 100),
        state: .paused,
        capabilities: MediaCapabilities(canSeek: true)
    ))

    #expect(isSuccess(coordinator.send(.seek(42))))
    #expect(selected.sentCommands == [.seek(42)])
    #expect(other.sentCommands.isEmpty)
}

@Test("output-device updates stay local and follow the selected session")
@MainActor
func outputDeviceUpdatesStayLocalAndFollowSelectedSession() {
    let provider = MockMediaProvider(identifier: "player")
    let coordinator = MediaCoordinator(providers: [provider])
    coordinator.start()

    let track = session(
        id: "track",
        observedAt: Date(timeIntervalSinceReferenceDate: 100),
        state: .playing
    )
    provider.publish(track)
    coordinator.updateOutputDevice(MediaOutputDevice(identifier: "device-1", name: "Built-in Speakers"))

    #expect(coordinator.currentSession?.outputDevice == MediaOutputDevice(
        identifier: "device-1",
        name: "Built-in Speakers"
    ))
    #expect(provider.currentSession?.outputDevice == nil)

    provider.publish(track)
    #expect(coordinator.currentSession?.outputDevice?.name == "Built-in Speakers")

    coordinator.stop()
    #expect(coordinator.currentSession == nil)
}

@Test("seek interaction sends one command when the gesture ends")
func seekInteractionSendsOneCommandAtGestureEnd() {
    var interaction = MediaSeekInteraction()
    interaction.begin(at: 10, duration: 100)
    interaction.update(position: 45)
    interaction.update(position: 60)

    #expect(interaction.finish() == .seek(60))
    #expect(interaction.finish() == nil)
}

@Test("coordinator reports no-session and provider lifecycle deterministically")
@MainActor
func coordinatorReportsNoSessionAndProviderLifecycleDeterministically() {
    let provider = MockMediaProvider(identifier: "player")
    let coordinator = MediaCoordinator(providers: [provider])

    #expect(isFailure(coordinator.send(.play), .noSession))
    coordinator.start()
    coordinator.start()
    coordinator.stop()
    coordinator.stop()

    #expect(provider.startCount == 1)
    #expect(provider.stopCount == 1)
    #expect(isFailure(coordinator.send(.play), .noSession))
}

@Test("coordinator publishes selected sessions through its main-actor update closure")
@MainActor
func coordinatorPublishesSelectedSessionToAppState() {
    let state = AppState()
    let provider = MockMediaProvider(identifier: "player")
    let coordinator = MediaCoordinator(providers: [provider])
    coordinator.onSessionUpdate = { session in
        state.updateMediaSession(session)
    }

    coordinator.start()
    let track = session(
        id: "track",
        observedAt: Date(timeIntervalSinceReferenceDate: 100),
        state: .playing
    )
    provider.publish(track)

    #expect(state.mediaSession == track)

    provider.publish(nil)
    #expect(state.mediaSession == nil)

    coordinator.stop()
    #expect(state.mediaSession == nil)
}

@Test("coordinator does not republish an unchanged selection")
@MainActor
func coordinatorDoesNotRepublishAnUnchangedSelection() {
    let provider = MockMediaProvider(identifier: "player")
    let coordinator = MediaCoordinator(providers: [provider])
    var updateCount = 0
    coordinator.onSessionUpdate = { _ in
        updateCount += 1
    }

    coordinator.start()
    let track = session(
        id: "track",
        observedAt: Date(timeIntervalSinceReferenceDate: 100),
        state: .playing
    )
    provider.publish(track)
    provider.publish(track)
    coordinator.stop()

    #expect(updateCount == 2)
}

private func session(
    id: String,
    observedAt: Date,
    state: MediaPlaybackState,
    capabilities: MediaCapabilities = MediaCapabilities()
) -> MediaSession {
    MediaSession(
        id: id,
        title: id,
        observedAt: observedAt,
        playbackRate: state == .playing ? 1 : 0,
        playbackState: state,
        capabilities: capabilities
    )
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
