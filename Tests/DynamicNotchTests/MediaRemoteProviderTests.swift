import Foundation
import Testing
@testable import DynamicNotchMedia
@testable import DynamicNotch

@Test("MediaRemote mapping preserves familiar metadata and source identity")
func mediaRemoteMappingPreservesMetadataAndSourceIdentity() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 500)
    let session = MediaRemoteInfoMapper.session(
        from: [
            "kMRMediaRemoteNowPlayingInfoTitle": "A title",
            "kMRMediaRemoteNowPlayingInfoArtist": "An artist",
            "kMRMediaRemoteNowPlayingInfoUniqueIdentifier": "track-1",
            "kMRMediaRemoteNowPlayingInfoDuration": 180.0,
            "kMRMediaRemoteNowPlayingInfoElapsedTime": 12.5,
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1.0,
            "kMRMediaRemoteNowPlayingInfoArtworkData": Data([1, 2, 3]),
            "kMRMediaRemoteNowPlayingInfoArtworkMIMEType": "image/png"
        ],
        sourceDisplayIdentifier: "com.example.player",
        sourceProcessIdentifier: 42,
        observedAt: observedAt
    )

    #expect(session?.id == "track-1")
    #expect(session?.title == "A title")
    #expect(session?.artistOrChannel == "An artist")
    #expect(session?.duration == 180)
    #expect(session?.elapsedTime == 12.5)
    #expect(session?.playbackState == .playing)
    #expect(session?.sourceApplication.displayIdentifier == "com.example.player")
    #expect(session?.sourceApplication.processIdentifier == 42)
    #expect(session?.artwork?.mimeType == "image/png")
    #expect(session?.capabilities == MediaCapabilities())
}

@Test("MediaRemote mapping rejects dictionaries with no usable familiar values")
func mediaRemoteMappingRejectsUnknownOrMalformedValues() {
    let malformed: [String: Any] = [
        "kMRMediaRemoteNowPlayingInfoTitle": 123,
        "kMRMediaRemoteNowPlayingInfoArtworkData": "not data",
        "kMRMediaRemoteNowPlayingInfoPlaybackRate": "not a number"
    ]

    #expect(MediaRemoteInfoMapper.session(
        from: malformed,
        sourceDisplayIdentifier: nil,
        sourceProcessIdentifier: 0,
        observedAt: Date()
    ) == nil)
}

@Test("MediaRemote mapping drops oversized artwork and sanitizes the source PID")
func mediaRemoteMappingDropsOversizedArtworkAndSanitizesSourcePID() {
    let session = MediaRemoteInfoMapper.session(
        from: [
            "kMRMediaRemoteNowPlayingInfoTitle": "Title",
            "kMRMediaRemoteNowPlayingInfoArtworkData": Data(
                repeating: 0,
                count: MediaArtwork.maxByteCount + 1
            ),
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": 0.0
        ],
        sourceDisplayIdentifier: "com.example.player",
        sourceProcessIdentifier: 0,
        observedAt: Date()
    )

    #expect(session?.artwork == nil)
    #expect(session?.sourceApplication.processIdentifier == nil)
    #expect(session?.playbackState == .paused)
    #expect(session?.capabilities.canPlay == false)
    #expect(session?.capabilities.canPause == false)
    #expect(session?.capabilities.canPrevious == false)
    #expect(session?.capabilities.canNext == false)
    #expect(session?.capabilities.canSeek == false)
}
