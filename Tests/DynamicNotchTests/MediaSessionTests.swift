import Foundation
import Testing
@testable import DynamicNotchMedia
@testable import DynamicNotch

@Test("playing elapsed time advances at the supplied rate")
func playingElapsedTimeAdvancesAtSuppliedRate() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 100)
    let session = MediaSession(
        id: "track",
        duration: 120,
        elapsedTime: 10,
        observedAt: observedAt,
        playbackRate: 1.5,
        playbackState: .playing
    )

    #expect(session.elapsed(at: observedAt.addingTimeInterval(4)) == 16)
}

@Test("paused and non-positive-rate sessions do not advance")
func pausedAndNonPositiveRateSessionsDoNotAdvance() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 100)
    let paused = MediaSession(
        id: "paused",
        elapsedTime: 10,
        observedAt: observedAt,
        playbackRate: 1,
        playbackState: .paused
    )
    let stopped = MediaSession(
        id: "stopped",
        elapsedTime: 10,
        observedAt: observedAt,
        playbackRate: 0,
        playbackState: .playing
    )

    #expect(paused.elapsed(at: observedAt.addingTimeInterval(30)) == 10)
    #expect(stopped.elapsed(at: observedAt.addingTimeInterval(30)) == 10)
}

@Test("elapsed time clamps at zero and duration")
func elapsedTimeClampsAtZeroAndDuration() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 100)
    let negative = MediaSession(
        id: "negative",
        duration: 20,
        elapsedTime: -4,
        observedAt: observedAt,
        playbackState: .paused
    )
    let capped = MediaSession(
        id: "capped",
        duration: 20,
        elapsedTime: 19,
        observedAt: observedAt,
        playbackRate: 2,
        playbackState: .playing
    )

    #expect(negative.elapsedTime == 0)
    #expect(capped.elapsed(at: observedAt.addingTimeInterval(2)) == 20)
    #expect(capped.elapsed(at: observedAt.addingTimeInterval(-1)) == 19)
}

@Test("missing or invalid duration leaves elapsed time uncapped")
func missingOrInvalidDurationLeavesElapsedTimeUncapped() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 100)
    let session = MediaSession(
        id: "unknown-duration",
        duration: .infinity,
        elapsedTime: 10,
        observedAt: observedAt,
        playbackRate: 1,
        playbackState: .playing
    )

    #expect(session.duration == nil)
    #expect(session.elapsed(at: observedAt.addingTimeInterval(3)) == 13)
}

@Test("artwork is bounded and model identity remains value based")
func artworkIsBoundedAndModelIdentityRemainsValueBased() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 100)
    let artwork = MediaArtwork(data: Data([1, 2, 3]), mimeType: "image/png")
    let first = MediaSession(
        id: "same",
        title: "Title",
        artistOrChannel: "Artist",
        artwork: artwork,
        observedAt: observedAt,
        sourceApplication: MediaSourceApplication(displayIdentifier: "com.example.player")
    )
    let second = MediaSession(
        id: "same",
        title: "Title",
        artistOrChannel: "Artist",
        artwork: artwork,
        observedAt: observedAt,
        sourceApplication: MediaSourceApplication(displayIdentifier: "com.example.player")
    )

    #expect(first == second)
    #expect(MediaArtwork(data: Data(repeating: 0, count: MediaArtwork.maxByteCount + 1)) == nil)
    #expect(first.artwork?.data == Data([1, 2, 3]))
}

@Test("notch media view model reflects metadata and timestamp-derived progress")
func notchMediaViewModelReflectsMediaSession() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 100)
    let session = MediaSession(
        id: "track",
        title: "Title",
        artistOrChannel: "Artist",
        duration: 120,
        elapsedTime: 10,
        observedAt: observedAt,
        playbackRate: 1,
        playbackState: .playing,
        sourceApplication: MediaSourceApplication(displayName: "Spotify")
    )

    let model = NotchMediaViewModel(
        session: session,
        at: observedAt.addingTimeInterval(30)
    )

    #expect(model?.title == "Title")
    #expect(model?.detail == "Artist")
    #expect(model?.source == "Spotify")
    #expect(model?.playbackLabel == "Playing")
    #expect(model?.elapsedTime == 40)
    #expect(model?.progress == 1.0 / 3.0)
    #expect(NotchMediaViewModel(session: nil, at: observedAt) == nil)
}
