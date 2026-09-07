import Foundation
import DynamicNotchMedia

@MainActor
final class MediaCoordinator: MediaProviderDelegate {
    private struct Candidate {
        let providerIdentifier: String
        let session: MediaSession
        let updateSequence: UInt64
    }

    private let providers: [any MediaProvider]
    private var candidates: [String: Candidate] = [:]
    private var nextUpdateSequence: UInt64 = 0
    private var hasOutputDeviceObservation = false
    private var latestOutputDevice: MediaOutputDevice?
    private(set) var selectedProviderIdentifier: String?
    private(set) var currentSession: MediaSession?
    private(set) var isStarted = false

    /// Called on the main actor whenever the selected media session changes.
    /// The coordinator deliberately exposes only the selected value so the
    /// app state does not need to know about provider arbitration.
    var onSessionUpdate: (@MainActor (MediaSession?) -> Void)?

    init(providers: [any MediaProvider]) {
        var uniqueProviders: [any MediaProvider] = []
        var identifiers = Set<String>()

        for provider in providers where identifiers.insert(provider.identifier).inserted {
            uniqueProviders.append(provider)
        }
        self.providers = uniqueProviders
        for provider in self.providers {
            provider.delegate = self
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        for provider in providers {
            provider.start()
            if let session = provider.currentSession {
                record(session, for: provider.identifier)
            }
        }
        selectBestCandidate()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        for provider in providers {
            provider.stop()
        }
        candidates.removeAll()
        let hadSelection = selectedProviderIdentifier != nil || currentSession != nil
        selectedProviderIdentifier = nil
        currentSession = nil
        hasOutputDeviceObservation = false
        latestOutputDevice = nil
        if hadSelection {
            onSessionUpdate?(nil)
        }
    }

    func send(_ command: MediaCommand) -> Result<Void, MediaProviderError> {
        guard let selectedProviderIdentifier,
              let candidate = candidates[selectedProviderIdentifier],
              let provider = providers.first(where: { $0.identifier == selectedProviderIdentifier })
        else {
            return .failure(.noSession)
        }

        guard provider.status == .running else {
            return .failure(provider.status == .unavailable ? .unavailable : .notStarted)
        }

        guard candidate.session.capabilities.supports(command) else {
            return .failure(.unsupported)
        }

        return provider.send(command)
    }

    /// Projects the locally observed CoreAudio output device onto the selected
    /// media session. This does not send a provider command and does not make
    /// output-device changes part of provider arbitration.
    func updateOutputDevice(_ outputDevice: MediaOutputDevice?) {
        hasOutputDeviceObservation = true
        latestOutputDevice = outputDevice

        guard let selectedProviderIdentifier,
              let candidate = candidates[selectedProviderIdentifier]
        else {
            return
        }

        let session = sessionWithOutputDevice(candidate.session)
        guard session != candidate.session else { return }

        candidates[selectedProviderIdentifier] = Candidate(
            providerIdentifier: candidate.providerIdentifier,
            session: session,
            updateSequence: candidate.updateSequence
        )
        currentSession = session
        onSessionUpdate?(session)
    }

    func mediaProvider(_ provider: any MediaProvider, didUpdate session: MediaSession?) {
        guard isStarted else { return }

        if let session {
            record(session, for: provider.identifier)
        } else {
            candidates.removeValue(forKey: provider.identifier)
            selectBestCandidate()
        }
    }

    private func record(_ session: MediaSession, for providerIdentifier: String) {
        nextUpdateSequence &+= 1
        candidates[providerIdentifier] = Candidate(
            providerIdentifier: providerIdentifier,
            session: sessionWithOutputDevice(session),
            updateSequence: nextUpdateSequence
        )
        selectBestCandidate()
    }

    private func sessionWithOutputDevice(_ session: MediaSession) -> MediaSession {
        guard hasOutputDeviceObservation else { return session }
        return session.withOutputDevice(latestOutputDevice)
    }

    private func selectBestCandidate() {
        let best = candidates.values.max { lhs, rhs in
            if lhs.session.playbackState != rhs.session.playbackState {
                return playbackPriority(lhs.session.playbackState) < playbackPriority(rhs.session.playbackState)
            }
            if lhs.session.observedAt != rhs.session.observedAt {
                return lhs.session.observedAt < rhs.session.observedAt
            }
            if lhs.updateSequence != rhs.updateSequence {
                return lhs.updateSequence < rhs.updateSequence
            }
            return lhs.providerIdentifier > rhs.providerIdentifier
        }

        let nextProviderIdentifier = best?.providerIdentifier
        let nextSession = best?.session
        guard selectedProviderIdentifier != nextProviderIdentifier || currentSession != nextSession else {
            return
        }

        selectedProviderIdentifier = nextProviderIdentifier
        currentSession = nextSession
        onSessionUpdate?(nextSession)
    }

    private func playbackPriority(_ state: MediaPlaybackState) -> Int {
        switch state {
        case .playing:
            3
        case .paused:
            2
        case .stopped:
            1
        case .unknown:
            0
        }
    }
}
