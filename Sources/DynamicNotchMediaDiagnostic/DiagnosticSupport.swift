import Foundation
import DynamicNotchMedia

enum MediaDiagnosticArguments {
    enum ParseResult: Equatable {
        case run
        case help
        case invalid
    }

    static func parse(_ arguments: [String]) -> ParseResult {
        switch Array(arguments.dropFirst()) {
        case []:
            .run
        case ["--help"]:
            .help
        default:
            .invalid
        }
    }

    static let usage = "usage: swift run DynamicNotchMediaDiagnostic [--help]"
}

enum MediaDiagnosticCompletion: String, Equatable, Sendable {
    case sessionFound = "session-found"
    case noSession = "no-session"
    case providerUnavailable = "provider-unavailable"
    case timeout
    case internalError = "internal-error"

    var exitCode: Int32 {
        switch self {
        case .sessionFound:
            0
        case .internalError:
            1
        case .noSession:
            2
        case .providerUnavailable:
            3
        case .timeout:
            4
        }
    }
}

enum MediaDiagnosticEvent {
    case callback(MediaSession?)
    case providerUnavailable
    case timeout
    case internalError(String)
}

/// Pure terminal-state reducer used by the live runner and offline tests.
struct MediaDiagnosticState: Equatable {
    private(set) var completion: MediaDiagnosticCompletion?
    private(set) var callbackArrived = false
    private(set) var session: MediaSession?
    private(set) var error: String?

    @discardableResult
    mutating func reduce(_ event: MediaDiagnosticEvent) -> Bool {
        guard completion == nil else { return false }

        switch event {
        case let .callback(session):
            callbackArrived = true
            self.session = session
            completion = session == nil ? .noSession : .sessionFound
        case .providerUnavailable:
            completion = .providerUnavailable
        case .timeout:
            completion = .timeout
        case let .internalError(error):
            completion = .internalError
            self.error = error
        }
        return true
    }
}

@MainActor
protocol MediaDiagnosticObservationDelegate: AnyObject {
    func mediaDiagnosticObservation(
        _ observation: any MediaDiagnosticObservation,
        didUpdate session: MediaSession?
    )
}

/// Read-only adapter: the diagnostic cannot issue MediaProvider commands.
@MainActor
protocol MediaDiagnosticObservation: AnyObject {
    var identifier: String { get }
    var status: MediaProviderStatus { get }
    var delegate: (any MediaDiagnosticObservationDelegate)? { get set }

    func start()
    func stop()
}

@MainActor
final class ReadOnlyMediaObservation: MediaDiagnosticObservation, MediaProviderDelegate {
    private let provider: PrivateMediaRemoteProvider
    weak var delegate: (any MediaDiagnosticObservationDelegate)?

    init(provider: PrivateMediaRemoteProvider) {
        self.provider = provider
        provider.delegate = self
    }

    var identifier: String { provider.identifier }
    var status: MediaProviderStatus { provider.status }

    func start() {
        provider.start()
    }

    func stop() {
        provider.stop()
    }

    func mediaProvider(_ provider: any MediaProvider, didUpdate session: MediaSession?) {
        delegate?.mediaDiagnosticObservation(self, didUpdate: session)
    }
}

struct MediaDiagnosticSummary: Equatable {
    let providerIdentifier: String
    let frameworkAvailable: Bool
    let initialProviderStatus: MediaProviderStatus
    let finalProviderStatus: MediaProviderStatus
    let completion: MediaDiagnosticCompletion
    let callbackArrived: Bool
    let sessionArrived: Bool
    let titlePresent: Bool
    let titleLength: Int
    let artistPresent: Bool
    let artistLength: Int
    let artworkPresent: Bool
    let artworkByteCount: Int
    let sourceDisplayIdentifier: String
    let playbackState: String
    let durationPresent: Bool
    let durationPlausible: Bool
    let elapsedPlausible: Bool
    let elapsedWithinDuration: Bool?
    let capabilities: MediaCapabilities
    let error: String
    let durationMilliseconds: Int

    init(
        providerIdentifier: String,
        frameworkAvailable: Bool,
        initialProviderStatus: MediaProviderStatus,
        finalProviderStatus: MediaProviderStatus,
        completion: MediaDiagnosticCompletion,
        state: MediaDiagnosticState,
        durationMilliseconds: Int
    ) {
        self.providerIdentifier = providerIdentifier
        self.frameworkAvailable = frameworkAvailable
        self.initialProviderStatus = initialProviderStatus
        self.finalProviderStatus = finalProviderStatus
        self.completion = completion
        callbackArrived = state.callbackArrived
        sessionArrived = state.session != nil

        if let session = state.session {
            titlePresent = session.title != nil
            titleLength = session.title?.count ?? 0
            artistPresent = session.artistOrChannel != nil
            artistLength = session.artistOrChannel?.count ?? 0
            artworkPresent = session.artwork != nil
            artworkByteCount = session.artwork?.data.count ?? 0
            sourceDisplayIdentifier = Self.sanitizedSourceIdentifier(
                session.sourceApplication.displayIdentifier
            )
            playbackState = session.playbackState.rawValue
            durationPresent = session.duration != nil
            durationPlausible = session.duration.map { $0.isFinite && $0 >= 0 } ?? false
            elapsedPlausible = session.elapsedTime.isFinite && session.elapsedTime >= 0
            elapsedWithinDuration = session.duration.map {
                session.elapsedTime.isFinite && session.elapsedTime >= 0
                    && session.elapsedTime <= $0
            }
            capabilities = session.capabilities
        } else {
            titlePresent = false
            titleLength = 0
            artistPresent = false
            artistLength = 0
            artworkPresent = false
            artworkByteCount = 0
            sourceDisplayIdentifier = "absent"
            playbackState = "none"
            durationPresent = false
            durationPlausible = false
            elapsedPlausible = false
            elapsedWithinDuration = nil
            capabilities = MediaCapabilities()
        }

        error = Self.sanitizedStatus(state.error ?? Self.defaultError(for: completion))
        self.durationMilliseconds = max(0, durationMilliseconds)
    }

    /// Stable line-oriented schema. No identifier, title, artist, URL, PID,
    /// display name, raw dictionary, or artwork bytes are emitted.
    var rendered: String {
        let withinDuration = elapsedWithinDuration.map(String.init) ?? "not-applicable"
        return [
            "diagnostic=media",
            "schema_version=1",
            "provider_identifier=\(providerIdentifier)",
            "framework_available=\(frameworkAvailable)",
            "provider_status_initial=\(Self.statusLabel(initialProviderStatus))",
            "provider_status_final=\(Self.statusLabel(finalProviderStatus))",
            "lifecycle=stopped",
            "completion=\(completion.rawValue)",
            "exit_code=\(completion.exitCode)",
            "callback_arrived=\(callbackArrived)",
            "session_arrived=\(sessionArrived)",
            "title_present=\(titlePresent)",
            "title_length=\(titleLength)",
            "artist_present=\(artistPresent)",
            "artist_length=\(artistLength)",
            "artwork_present=\(artworkPresent)",
            "artwork_byte_count=\(artworkByteCount)",
            "source_display_identifier=\(sourceDisplayIdentifier)",
            "playback_state=\(playbackState)",
            "duration_present=\(durationPresent)",
            "duration_plausible=\(durationPlausible)",
            "elapsed_plausible=\(elapsedPlausible)",
            "elapsed_within_duration=\(withinDuration)",
            "capabilities=play:\(capabilities.canPlay),pause:\(capabilities.canPause),toggle:\(capabilities.canTogglePlayPause),previous:\(capabilities.canPrevious),next:\(capabilities.canNext),seek:\(capabilities.canSeek)",
            "error=\(error)",
            "duration_ms=\(durationMilliseconds)"
        ].joined(separator: " ")
    }

    static func sanitizedSourceIdentifier(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "absent" }

        let sanitized = identifier.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                Character(String(scalar))
            default:
                "_"
            }
        }
        let bounded = String(sanitized.prefix(96))
        return bounded.isEmpty ? "absent" : bounded
    }

    private static func statusLabel(_ status: MediaProviderStatus) -> String {
        switch status {
        case .stopped:
            "stopped"
        case .running:
            "running"
        case .unavailable:
            "unavailable"
        }
    }

    private static func defaultError(for completion: MediaDiagnosticCompletion) -> String {
        switch completion {
        case .sessionFound, .noSession:
            "none"
        case .providerUnavailable:
            "provider-unavailable"
        case .timeout:
            "timeout"
        case .internalError:
            "internal-error"
        }
    }

    private static func sanitizedStatus(_ value: String) -> String {
        let sanitized = value.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                Character(String(scalar))
            default:
                "_"
            }
        }
        return String(sanitized.prefix(96))
    }
}

enum MediaDiagnosticOutput {
    static func writeLine(_ line: String) {
        fputs(line + "\n", stdout)
        fflush(stdout)
    }
}
