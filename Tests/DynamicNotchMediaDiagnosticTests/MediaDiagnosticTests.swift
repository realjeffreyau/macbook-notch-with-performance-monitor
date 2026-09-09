import Foundation
import Testing
@testable import DynamicNotchMedia
@testable import DynamicNotchMediaDiagnostic

@Test("diagnostic exit code mapping is stable")
func diagnosticExitCodeMappingIsStable() {
    #expect(MediaDiagnosticCompletion.sessionFound.exitCode == 0)
    #expect(MediaDiagnosticCompletion.internalError.exitCode == 1)
    #expect(MediaDiagnosticCompletion.noSession.exitCode == 2)
    #expect(MediaDiagnosticCompletion.providerUnavailable.exitCode == 3)
    #expect(MediaDiagnosticCompletion.timeout.exitCode == 4)
}

@Test("nil callback is no-session and duplicate or late events are ignored")
func nilCallbackAndLateEventsAreOneShot() {
    var state = MediaDiagnosticState()

    let accepted = state.reduce(.callback(nil))
    #expect(accepted)
    #expect(state.completion == .noSession)
    #expect(state.callbackArrived)
    #expect(state.session == nil)
    let lateTimeout = state.reduce(.timeout)
    let lateCallback = state.reduce(.callback(sampleSession()))
    #expect(lateTimeout == false)
    #expect(lateCallback == false)
    #expect(state.completion == .noSession)
    #expect(state.session == nil)
}

@Test("each terminal event is accepted once")
func eachTerminalEventIsAcceptedOnce() {
    let events: [(MediaDiagnosticEvent, MediaDiagnosticCompletion)] = [
        (.callback(sampleSession()), .sessionFound),
        (.providerUnavailable, .providerUnavailable),
        (.timeout, .timeout),
        (.internalError("bad\nstatus"), .internalError)
    ]

    for (event, expected) in events {
        var state = MediaDiagnosticState()
        let accepted = state.reduce(event)
        #expect(accepted)
        #expect(state.completion == expected)
        let duplicate = state.reduce(.providerUnavailable)
        #expect(duplicate == false)
    }
}

@Test("summary redacts metadata and preserves stable presence schema")
func summaryRedactsMetadata() {
    let session = MediaSession(
        id: "synthetic-session-id",
        title: "Private title",
        artistOrChannel: "Private artist",
        artwork: MediaArtwork(data: Data([1, 2, 3, 4]), mimeType: "image/png"),
        duration: 180,
        elapsedTime: 12.5,
        observedAt: Date(timeIntervalSinceReferenceDate: 500),
        playbackRate: 1,
        playbackState: .playing,
        sourceApplication: MediaSourceApplication(
            displayIdentifier: "com.example/player\nwith-controls"
        )
    )
    var state = MediaDiagnosticState()
    let accepted = state.reduce(.callback(session))
    #expect(accepted)

    let rendered = MediaDiagnosticSummary(
        providerIdentifier: "system-media-remote",
        frameworkAvailable: true,
        initialProviderStatus: .running,
        finalProviderStatus: .stopped,
        completion: .sessionFound,
        state: state,
        durationMilliseconds: 42
    ).rendered

    #expect(rendered.contains("title_present=true"))
    #expect(rendered.contains("title_length=13"))
    #expect(rendered.contains("artist_present=true"))
    #expect(rendered.contains("artist_length=14"))
    #expect(rendered.contains("artwork_present=true"))
    #expect(rendered.contains("artwork_byte_count=4"))
    #expect(rendered.contains("source_display_identifier=com.example_player_with-controls"))
    #expect(rendered.contains("playback_state=playing"))
    #expect(rendered.contains("duration_plausible=true"))
    #expect(rendered.contains("elapsed_plausible=true"))
    #expect(rendered.contains("elapsed_within_duration=true"))
    #expect(rendered.contains("Private title") == false)
    #expect(rendered.contains("Private artist") == false)
    #expect(rendered.contains("synthetic-session-id") == false)
    #expect(rendered.contains("1, 2, 3, 4") == false)
    #expect(rendered.contains("processIdentifier") == false)
    #expect(rendered.contains("displayName") == false)
}

@Test("source identifier sanitization is bounded and control safe")
func sourceIdentifierSanitizationIsBoundedAndControlSafe() {
    let input = "A\nB\tC/" + String(repeating: "x", count: 200)
    let sanitized = MediaDiagnosticSummary.sanitizedSourceIdentifier(input)
    #expect(sanitized.count == 96)
    #expect(sanitized.contains("\n") == false)
    #expect(sanitized.contains("\t") == false)
    #expect(sanitized.contains("/") == false)
}

@Test("argument parsing only accepts the executable's explicit help")
func argumentParsingIsExplicit() {
    #expect(MediaDiagnosticArguments.parse(["DynamicNotchMediaDiagnostic"]) == .run)
    #expect(MediaDiagnosticArguments.parse(["DynamicNotchMediaDiagnostic", "--help"]) == .help)
    #expect(MediaDiagnosticArguments.parse(["DynamicNotchMediaDiagnostic", "--unexpected-flag"]) == .invalid)
    #expect(MediaDiagnosticArguments.parse(["DynamicNotchMediaDiagnostic", "--timeout-seconds", "1"]) == .invalid)
}

@Test("absent session summary maps callback and status without metadata")
func absentSessionSummary() {
    var state = MediaDiagnosticState()
    let accepted = state.reduce(.callback(nil))
    #expect(accepted)
    let summary = MediaDiagnosticSummary(
        providerIdentifier: "system-media-remote",
        frameworkAvailable: true,
        initialProviderStatus: .running,
        finalProviderStatus: .stopped,
        completion: .noSession,
        state: state,
        durationMilliseconds: 12
    )

    #expect(summary.sessionArrived == false)
    #expect(summary.rendered.contains("completion=no-session"))
    #expect(summary.rendered.contains("callback_arrived=true"))
    #expect(summary.rendered.contains("source_display_identifier=absent"))
    #expect(summary.rendered.contains("elapsed_within_duration=not-applicable"))
    #expect(summary.rendered.contains("exit_code=2"))
}

@Test("live runner timeout stops a no-callback observation once")
@MainActor
func liveRunnerTimeoutStopsNoCallbackObservationOnce() {
    let observation = NoCallbackObservation()
    let startedAt = Date()
    let runner = MediaDiagnosticRunner(deadlineSeconds: 0.05) {
        observation
    }

    let exitCode = runner.run()
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(exitCode == MediaDiagnosticCompletion.timeout.exitCode)
    #expect(observation.startCount == 1)
    #expect(observation.stopCount == 1)
    #expect(observation.status == .stopped)
    #expect(observation.delegate == nil)
    #expect(elapsed < 2)

    // Keep a captured late callback target so teardown is exercised against a
    // real post-timeout callback, not only the pure reducer.
    observation.emitLateCallback()
    #expect(observation.stopCount == 1)
}

private func sampleSession() -> MediaSession {
    MediaSession(
        id: "sample",
        title: "sample",
        observedAt: Date(timeIntervalSinceReferenceDate: 1),
        playbackState: .paused
    )
}

@MainActor
private final class NoCallbackObservation: MediaDiagnosticObservation {
    let identifier = "offline-no-callback"
    private(set) var status: MediaProviderStatus = .stopped
    private(set) var startCount = 0
    private(set) var stopCount = 0

    private weak var currentDelegate: (any MediaDiagnosticObservationDelegate)?
    private var lateCallbackDelegate: (any MediaDiagnosticObservationDelegate)?

    var delegate: (any MediaDiagnosticObservationDelegate)? {
        get { currentDelegate }
        set {
            currentDelegate = newValue
            if let newValue {
                lateCallbackDelegate = newValue
            }
        }
    }

    func start() {
        startCount += 1
        status = .running
    }

    func stop() {
        stopCount += 1
        status = .stopped
    }

    func emitLateCallback() {
        lateCallbackDelegate?.mediaDiagnosticObservation(self, didUpdate: nil)
    }
}
