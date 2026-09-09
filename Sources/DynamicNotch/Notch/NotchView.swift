import AppKit
import DynamicNotchMedia
import SwiftUI

enum NotchDesignTokens {
    // Give the media title enough horizontal room while keeping the panel
    // compact around the physical notch.
    static let expandedWidth: CGFloat = 430
    // The media card owns metadata, progress, optional transport controls,
    // and the local output route. Leave enough vertical room for those
    // rows below the physical camera cutout without clipping the footer.
    static let expandedHeight: CGFloat = 252
    static let expandedCornerRadius: CGFloat = 24
    static let collapsedCornerRadius: CGFloat = 8
    static let privacyIndicatorGutter: CGFloat = 14
    static let horizontalPadding: CGFloat = 24
    // Keep one shared inset for every expanded page so switching tabs does not
    // make the System or Files content jump relative to Media, while leaving
    // a clear breathing gap below the page tabs.
    static let expandedPageContentTopPadding: CGFloat = 12
    static let expandedArtworkSize: CGFloat = 72
    static let expandedContentBottomPadding: CGFloat = 12
    static let expandedContentVerticalOffset: CGFloat = -4
    static let animationDuration: TimeInterval = 0.30
    static let reducedMotionAnimationDuration: TimeInterval = 0.16
    static let expandedTransitionScale: CGFloat = 0.96
    static let reducedMotionTransitionScale: CGFloat = 0.995
}

/// The value the notch renders for one media observation. It deliberately
/// keeps timestamp-derived progress as a value so the view never needs to
/// mutate session state or ask a provider to refresh.
struct NotchMediaViewModel: Equatable {
    let title: String
    let detail: String?
    let source: String?
    let artwork: MediaArtwork?
    let playbackState: MediaPlaybackState
    let playbackLabel: String
    let elapsedTime: TimeInterval
    let duration: TimeInterval?
    let progress: Double?
    let outputDevice: MediaOutputDevice?

    init?(session: MediaSession?, at date: Date) {
        guard let session else { return nil }

        let source = session.sourceApplication.displayName
            ?? session.sourceApplication.displayIdentifier
        let title = session.title ?? session.artistOrChannel ?? source ?? "Now Playing"
        let detail: String?
        if let artist = session.artistOrChannel, artist != title {
            detail = artist
        } else {
            detail = source
        }

        let elapsedTime = session.elapsed(at: date)
        let progress: Double?
        if let duration = session.duration, duration > 0 {
            progress = min(max(elapsedTime / duration, 0), 1)
        } else {
            progress = nil
        }

        self.title = title
        self.detail = detail
        self.source = source
        self.artwork = session.artwork
        self.playbackState = session.playbackState
        self.playbackLabel = Self.playbackLabel(for: session.playbackState)
        self.elapsedTime = elapsedTime
        self.duration = session.duration
        self.progress = progress
        self.outputDevice = session.outputDevice
    }

    private static func playbackLabel(for state: MediaPlaybackState) -> String {
        switch state {
        case .playing:
            "Playing"
        case .paused:
            "Paused"
        case .stopped:
            "Stopped"
        case .unknown:
            "Media"
        }
    }
}

/// The transport commands that the selected provider explicitly advertises.
/// A missing command is represented as nil so the view can disable both the
/// button and its action without guessing what a provider supports.
struct MediaControlAvailability: Equatable {
    let playPauseCommand: MediaCommand?
    let previousCommand: MediaCommand?
    let nextCommand: MediaCommand?
    let canSeek: Bool

    init(session: MediaSession?) {
        guard let session else {
            playPauseCommand = nil
            previousCommand = nil
            nextCommand = nil
            canSeek = false
            return
        }

        if session.playbackState == .playing {
            if session.capabilities.canPause {
                playPauseCommand = .pause
            } else if session.capabilities.canTogglePlayPause {
                playPauseCommand = .togglePlayPause
            } else {
                playPauseCommand = nil
            }
        } else if session.capabilities.canPlay {
            playPauseCommand = .play
        } else if session.capabilities.canTogglePlayPause {
            playPauseCommand = .togglePlayPause
        } else {
            playPauseCommand = nil
        }

        previousCommand = session.capabilities.canPrevious ? .previous : nil
        nextCommand = session.capabilities.canNext ? .next : nil
        canSeek = session.capabilities.canSeek
            && session.duration.map { $0 > 0 } == true
    }
}

/// Local state for the expanded seek gesture. Slider value changes only update
/// this value; `finish()` creates one provider command and clears the pending
/// value so repeated gesture-end callbacks cannot send duplicates.
struct MediaSeekInteraction: Equatable {
    private(set) var pendingPosition: TimeInterval?
    private var duration: TimeInterval?

    init() {
        pendingPosition = nil
        duration = nil
    }

    mutating func begin(at position: TimeInterval, duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else {
            cancel()
            return
        }

        self.duration = duration
        pendingPosition = Self.clamp(position, duration: duration)
    }

    mutating func update(position: TimeInterval) {
        guard let duration else { return }
        pendingPosition = Self.clamp(position, duration: duration)
    }

    mutating func finish() -> MediaCommand? {
        defer {
            pendingPosition = nil
            duration = nil
        }
        guard let pendingPosition else { return nil }
        return .seek(pendingPosition)
    }

    mutating func cancel() {
        pendingPosition = nil
        duration = nil
    }

    private static func clamp(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), duration)
    }
}

struct NotchView: View {
    let state: AppState
    let preferences: NotchPreferences
    let onToggle: () -> Void
    let onOpenSettings: () -> Void
    let onExpandedPageChange: (NotchExpandedPage) -> Void
    let onMediaCommand: @MainActor (MediaCommand) -> Result<Void, MediaProviderError>
    let onFileShelfReveal: (FileShelfItem) -> Void
    let onFileShelfQuickLook: (FileShelfItem) -> Void
    let onFileShelfRemove: (UUID) -> Void
    let onFileShelfClear: () -> Void

    var body: some View {
        Group {
            switch state.presentationState {
            case .collapsed:
                Button(action: onToggle) {
                    CollapsedNotchView(
                        session: state.mediaSession,
                        captureActivity: state.captureActivity,
                        notchWidth: state.geometry?.notchRect.width ?? 1,
                        showMediaIndicators: preferences.showCollapsedMediaIndicators,
                        showArtwork: preferences.showArtwork,
                        showPrivacyIndicators: preferences.showPrivacyIndicators
                    )
                        .transition(.opacity)
                }
                .buttonStyle(.plain)
            case .dropTarget:
                FileShelfDropTargetView()
            case .expanded:
                    ExpandedNotchView(
                        session: state.mediaSession,
                        notchHeight: state.geometry?.notchRect.height ?? 0,
                        captureActivity: state.captureActivity,
                        expandedPage: state.expandedPage,
                        systemStats: state.systemStats,
                        fileShelfItems: state.fileShelfItems,
                        preferences: preferences,
                        onExpandedPageChange: onExpandedPageChange,
                        onOpenSettings: onOpenSettings,
                        onMediaCommand: onMediaCommand,
                        onFileShelfReveal: onFileShelfReveal,
                        onFileShelfQuickLook: onFileShelfQuickLook,
                        onFileShelfRemove: onFileShelfRemove,
                        onFileShelfClear: onFileShelfClear
                    )
                    .transition(
                        .opacity.combined(
                            with: .scale(
                                scale: state.reduceMotion
                                    ? NotchDesignTokens.reducedMotionTransitionScale
                                    : NotchDesignTokens.expandedTransitionScale,
                                anchor: .top
                            )
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            state.presentationState == .expanded
                ? "Click outside the notch to collapse"
                : "Click to expand"
        )
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        if state.presentationState == .dropTarget {
            return "Dynamic Notch file drop target"
        }

        guard let session = state.mediaSession else {
            return state.presentationState == .expanded
                ? "Dynamic Notch expanded, no media playing"
                : "Dynamic Notch, no media playing"
        }

        let metadata = [session.title, session.artistOrChannel]
            .compactMap { $0 }
            .joined(separator: " by ")
        let suffix = metadata.isEmpty ? "media" : metadata
        return state.presentationState == .expanded
            ? "Dynamic Notch expanded, \(suffix)"
            : "Dynamic Notch, \(suffix)"
    }
}

private struct CollapsedNotchView: View {
    let session: MediaSession?
    let captureActivity: CaptureActivity
    let notchWidth: CGFloat
    let showMediaIndicators: Bool
    let showArtwork: Bool
    let showPrivacyIndicators: Bool

    var body: some View {
        ZStack {
            Color.clear

            RoundedRectangle(
                cornerRadius: NotchDesignTokens.collapsedCornerRadius,
                style: .continuous
            )
            .fill(Color.black)
            .frame(width: max(1, notchWidth))

            HStack {
                if showPrivacyIndicators && captureActivity.microphoneActive {
                    PrivacyIndicatorDot(color: .orange, label: "Microphone active")
                } else {
                    Spacer(minLength: 4)
                }

                Spacer(minLength: 0)

                if showPrivacyIndicators && captureActivity.cameraActive {
                    PrivacyIndicatorDot(color: .green, label: "Camera active")
                } else {
                    Spacer(minLength: 4)
                }
            }
            .padding(.horizontal, 2)

            if showMediaIndicators,
               let model = NotchMediaViewModel(session: session, at: Date()) {
                HStack(spacing: 7) {
                    MediaArtworkView(
                        artwork: showArtwork ? model.artwork : nil,
                        size: 20
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let detail = model.detail {
                            Text(detail)
                                .font(.system(size: 9, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: model.playbackState == .playing ? "waveform" : "music.note")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 9)
                .frame(width: max(1, notchWidth))
                .transition(.opacity)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: NotchDesignTokens.collapsedCornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }
}

private struct PrivacyIndicatorRow: View {
    let activity: CaptureActivity

    var body: some View {
        HStack(spacing: 8) {
            if activity.cameraActive {
                PrivacyIndicatorDot(color: .green, label: "Camera active")
            }
            if activity.microphoneActive {
                PrivacyIndicatorDot(color: .orange, label: "Microphone active")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch (activity.cameraActive, activity.microphoneActive) {
        case (true, true):
            "Camera and microphone active"
        case (true, false):
            "Camera active"
        case (false, true):
            "Microphone active"
        case (false, false):
            ""
        }
    }
}

private struct PrivacyIndicatorDot: View {
    let color: Color
    let label: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.45), radius: 2)
            .accessibilityLabel(label)
    }
}

private struct ExpandedNotchView: View {
    let session: MediaSession?
    let notchHeight: CGFloat
    let captureActivity: CaptureActivity
    let expandedPage: NotchExpandedPage
    let systemStats: SystemStatsSnapshot?
    let fileShelfItems: [FileShelfItem]
    let preferences: NotchPreferences
    let onExpandedPageChange: (NotchExpandedPage) -> Void
    let onOpenSettings: () -> Void
    let onMediaCommand: @MainActor (MediaCommand) -> Result<Void, MediaProviderError>
    let onFileShelfReveal: (FileShelfItem) -> Void
    let onFileShelfQuickLook: (FileShelfItem) -> Void
    let onFileShelfRemove: (UUID) -> Void
    let onFileShelfClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 34, height: 4)
                // The panel's top edge is the display's top edge. Keep the
                // media row below the physical camera cutout instead of
                // allowing the hardware black region to cover its title.
                .padding(.top, max(12, notchHeight + 8))

            ExpandedPagePicker(
                selection: expandedPage,
                pages: NotchExpandedPage.available(
                    systemStatsEnabled: preferences.systemStatsEnabled,
                    fileShelfEnabled: preferences.fileShelfEnabled
                ),
                onSettings: onOpenSettings,
                onSelect: onExpandedPageChange
            )
            .padding(.top, 8)

            if preferences.showPrivacyIndicators && captureActivity.isActive {
                PrivacyIndicatorRow(activity: captureActivity)
                    .padding(.top, 6)
            }

            Group {
                switch expandedPage {
                case .media:
                    if let session {
                        // Progress is refreshed only while the expanded media
                        // card is visible. The collapsed notch never owns a
                        // progress timer.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ExpandedMediaContent(
                                session: session,
                                model: NotchMediaViewModel(session: session, at: context.date)
                                    .map { $0 },
                                showArtwork: preferences.showArtwork,
                                showOutputDevice: preferences.showOutputDevice,
                                onMediaCommand: onMediaCommand
                            )
                            .id(session.id)
                        }
                    } else {
                        ExpandedNoMediaContent()
                    }
                case .system:
                    SystemStatsPageView(snapshot: systemStats)
                case .files:
                    FileShelfPageView(
                        items: fileShelfItems,
                        onReveal: onFileShelfReveal,
                        onQuickLook: onFileShelfQuickLook,
                        onRemove: onFileShelfRemove,
                        onClear: onFileShelfClear
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(.top, NotchDesignTokens.expandedPageContentTopPadding)
            // The header above reserves the full physical notch height. Lift
            // only the body by a few points; it remains below the cutout while
            // the outer inset keeps the lower edge visually breathable.
            .offset(y: NotchDesignTokens.expandedContentVerticalOffset)

            if preferences.showResourceDiagnostics {
                Text("Event-driven · no idle polling")
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
                    .padding(.bottom, 4)
                    .accessibilityLabel("Resource diagnostics: event-driven, no idle polling")
            }
        }
        // This is outside the media page so system/files content gets the
        // same lower edge clearance during the finite panel resize.
        .padding(.bottom, NotchDesignTokens.expandedContentBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, NotchDesignTokens.horizontalPadding)
        .background(
            RoundedRectangle(
                cornerRadius: NotchDesignTokens.expandedCornerRadius,
                style: .continuous
            )
            .fill(Color.black)
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: NotchDesignTokens.expandedCornerRadius,
                style: .continuous
            )
        )
    }
}

private struct ExpandedMediaContent: View {
    let session: MediaSession
    let model: NotchMediaViewModel?
    let showArtwork: Bool
    let showOutputDevice: Bool
    let onMediaCommand: @MainActor (MediaCommand) -> Result<Void, MediaProviderError>
    @State private var seekInteraction = MediaSeekInteraction()

    var body: some View {
        if let model {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    MediaArtworkView(
                        artwork: showArtwork ? model.artwork : nil,
                        size: NotchDesignTokens.expandedArtworkSize
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.title)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        if let detail = model.detail {
                            Text(detail)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }

                        HStack(spacing: 5) {
                            Circle()
                                .fill(model.playbackState == .playing ? .green : .white.opacity(0.48))
                                .frame(width: 6, height: 6)
                            Text(model.playbackLabel)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }

                        if showOutputDevice,
                           let outputDevice = model.outputDevice,
                           let outputName = outputDevice.name ?? outputDevice.identifier {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 9, weight: .medium))
                                    .accessibilityHidden(true)
                                Text(outputName)
                                    .font(.system(size: 10, weight: .regular, design: .rounded))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white.opacity(0.55))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Output device")
                            .accessibilityValue(outputName)
                        }
                    }

                    Spacer(minLength: 0)
                }
                // The page-level inset above is shared with System and Files;
                // keeping this row's local inset at zero preserves one tab
                // baseline while giving the larger art its intended room.

                Spacer(minLength: 8)

                if let duration = session.duration, duration > 0 {
                    let availability = MediaControlAvailability(session: session)
                    let elapsed = seekInteraction.pendingPosition ?? model.elapsedTime
                    if availability.canSeek {
                        Slider(
                            value: Binding(
                                get: { elapsed },
                                set: { seekInteraction.update(position: $0) }
                            ),
                            in: 0...duration,
                            onEditingChanged: { isEditing in
                                if isEditing {
                                    seekInteraction.begin(at: model.elapsedTime, duration: duration)
                                } else if let command = seekInteraction.finish() {
                                    _ = onMediaCommand(command)
                                } else {
                                    seekInteraction.cancel()
                                }
                            }
                        )
                        .tint(.white)
                        .accessibilityLabel("Playback progress")
                        .accessibilityValue("\(Int((elapsed / duration) * 100)) percent")
                    } else if let progress = model.progress {
                        // Keep the read-only path bright. A disabled native
                        // Slider is intentionally not used because AppKit
                        // renders it dimmed, which makes passive progress
                        // look unavailable rather than simply read-only.
                        MediaProgressBar(progress: progress)
                    }
                    HStack {
                        Text(formatTime(elapsed))
                        Spacer(minLength: 0)
                        Text(formatTime(duration))
                    }
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 1)
                }

                MediaTransportControls(
                    availability: MediaControlAvailability(session: session),
                    onMediaCommand: onMediaCommand
                )
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ExpandedNoMediaContent()
        }
    }

    private func formatTime(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct MediaTransportControls: View {
    let availability: MediaControlAvailability
    let onMediaCommand: @MainActor (MediaCommand) -> Result<Void, MediaProviderError>

    var body: some View {
        if hasAnyCommand {
            HStack(spacing: 18) {
                commandButton(availability.previousCommand, systemName: "backward.fill", label: "Previous")
                commandButton(
                    availability.playPauseCommand,
                    systemName: playPauseSystemName,
                    label: playPauseLabel
                )
                .font(.system(size: 16, weight: .semibold))
                commandButton(availability.nextCommand, systemName: "forward.fill", label: "Next")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var hasAnyCommand: Bool {
        availability.playPauseCommand != nil
            || availability.previousCommand != nil
            || availability.nextCommand != nil
    }

    private var playPauseSystemName: String {
        switch availability.playPauseCommand {
        case .play: "play.fill"
        case .pause: "pause.fill"
        default: "playpause.fill"
        }
    }

    private var playPauseLabel: String {
        switch availability.playPauseCommand {
        case .play: "Play"
        case .pause: "Pause"
        default: "Play or pause"
        }
    }

    @ViewBuilder
    private func commandButton(
        _ command: MediaCommand?,
        systemName: String,
        label: String
    ) -> some View {
        Button {
            guard let command else { return }
            _ = onMediaCommand(command)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(command == nil ? .white.opacity(0.22) : .white.opacity(0.88))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(command == nil)
        .accessibilityLabel(label)
    }
}

private struct MediaProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.32))

                Capsule()
                    .fill(Color.white.opacity(0.98))
                    .frame(width: max(5, proxy.size.width * progress))
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

private struct ExpandedNoMediaContent: View {
    var body: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 8)

            Image(systemName: "music.note")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityHidden(true)

            Text("No media playing")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Play something to see it here.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.58))

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MediaArtworkView: View {
    let artwork: MediaArtwork?
    let size: CGFloat

    var body: some View {
        Group {
            if let artwork, let image = MediaArtworkImageCache.image(for: artwork) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: min(10, size / 3), style: .continuous))
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Album art is rendered by both the collapsed surface and the expanded
/// progress timeline. Keep decoded images bounded so a once-per-second
/// progress refresh does not repeatedly decode the same bytes or retain every
/// track ever observed.
@MainActor
private enum MediaArtworkImageCache {
    private static let cache: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    static func image(for artwork: MediaArtwork) -> NSImage? {
        let key = artwork.data as NSData
        if let image = cache.object(forKey: key) {
            return image
        }

        guard let image = NSImage(data: artwork.data) else { return nil }
        cache.setObject(image, forKey: key, cost: artwork.data.count)
        return image
    }
}
