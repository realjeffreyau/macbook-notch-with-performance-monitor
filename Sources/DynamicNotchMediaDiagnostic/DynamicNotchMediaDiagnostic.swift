import CoreFoundation
import Darwin
import Foundation
import DynamicNotchMedia

@MainActor
final class MediaDiagnosticRunner: MediaDiagnosticObservationDelegate {
    static let defaultDeadlineSeconds: TimeInterval = 12

    private let observationFactory: () -> any MediaDiagnosticObservation
    private let deadlineSeconds: TimeInterval
    private var observation: (any MediaDiagnosticObservation)?
    private var providerIdentifier = "system-media-remote"
    private var deadlineTimer: CFRunLoopTimer?
    private var startedAt = Date()
    private var initialProviderStatus: MediaProviderStatus = .unavailable
    private var frameworkAvailable = false
    private var state = MediaDiagnosticState()

    init(
        deadlineSeconds: TimeInterval = MediaDiagnosticRunner.defaultDeadlineSeconds,
        observationFactory: @escaping () -> any MediaDiagnosticObservation = {
            ReadOnlyMediaObservation(provider: PrivateMediaRemoteProvider())
        }
    ) {
        self.deadlineSeconds = deadlineSeconds.isFinite && deadlineSeconds > 0
            ? deadlineSeconds
            : Self.defaultDeadlineSeconds
        self.observationFactory = observationFactory
    }

    func run() -> Int32 {
        startedAt = Date()
        let observation = observationFactory()
        self.observation = observation
        providerIdentifier = observation.identifier
        initialProviderStatus = observation.status
        frameworkAvailable = observation.status != .unavailable
        observation.delegate = self

        // This is flushed immediately before the single provider start.
        MediaDiagnosticOutput.writeLine(
            "diagnostic=media schema_version=1 status=startup provider_identifier=\(observation.identifier) timeout_seconds=\(deadlineSeconds)"
        )

        if observation.status == .unavailable {
            observation.start()
            reduce(.providerUnavailable)
        } else {
            installDeadline()
            if state.completion == nil {
                observation.start()
            }
            if state.completion == nil {
                CFRunLoopRunInMode(
                    CFRunLoopMode.defaultMode,
                    CFTimeInterval.greatestFiniteMagnitude,
                    false
                )
            }
            if state.completion == nil {
                reduce(.internalError("run-loop-returned"))
            }
        }

        return state.completion?.exitCode ?? MediaDiagnosticCompletion.internalError.exitCode
    }

    func mediaDiagnosticObservation(
        _ observation: any MediaDiagnosticObservation,
        didUpdate session: MediaSession?
    ) {
        reduce(.callback(session))
    }

    private func installDeadline() {
        var context = CFRunLoopTimerContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let fireDate = CFAbsoluteTimeGetCurrent() + deadlineSeconds
        guard let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            fireDate,
            0,
            0,
            0,
            mediaDiagnosticDeadlineCallout,
            &context
        ) else {
            reduce(.internalError("deadline-install-failed"))
            return
        }

        deadlineTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, CFRunLoopMode.defaultMode)
    }

    private func reduce(_ event: MediaDiagnosticEvent) {
        guard state.reduce(event), let completion = state.completion else { return }

        if let deadlineTimer {
            CFRunLoopRemoveTimer(CFRunLoopGetMain(), deadlineTimer, CFRunLoopMode.defaultMode)
            CFRunLoopTimerInvalidate(deadlineTimer)
            self.deadlineTimer = nil
        }

        observation?.delegate = nil
        observation?.stop()
        let finalProviderStatus = observation?.status ?? initialProviderStatus
        observation = nil

        let durationMilliseconds = Int(
            max(0, Date().timeIntervalSince(startedAt) * 1_000)
        )
        let summary = MediaDiagnosticSummary(
            providerIdentifier: providerIdentifier,
            frameworkAvailable: frameworkAvailable,
            initialProviderStatus: initialProviderStatus,
            finalProviderStatus: finalProviderStatus,
            completion: completion,
            state: state,
            durationMilliseconds: durationMilliseconds
        )
        MediaDiagnosticOutput.writeLine(summary.rendered)
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

private func mediaDiagnosticDeadlineCallout(
    _ timer: CFRunLoopTimer?,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let runner = Unmanaged<MediaDiagnosticRunner>
        .fromOpaque(info)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        runner.mediaDiagnosticDeadlineElapsed()
    }
}

private extension MediaDiagnosticRunner {
    func mediaDiagnosticDeadlineElapsed() {
        reduce(.timeout)
    }
}

@main
@MainActor
struct DynamicNotchMediaDiagnostic {
    static func main() {
        switch MediaDiagnosticArguments.parse(CommandLine.arguments) {
        case .run:
            let runner = MediaDiagnosticRunner()
            let code = withExtendedLifetime(runner) {
                runner.run()
            }
            Darwin.exit(code)
        case .help:
            MediaDiagnosticOutput.writeLine(MediaDiagnosticArguments.usage)
            Darwin.exit(0)
        case .invalid:
            MediaDiagnosticOutput.writeLine(
                "diagnostic=media schema_version=1 status=error error=invalid-arguments"
            )
            MediaDiagnosticOutput.writeLine(MediaDiagnosticArguments.usage)
            Darwin.exit(MediaDiagnosticCompletion.internalError.exitCode)
        }
    }
}
