import Foundation
import DynamicNotchMedia

/// Explicit launch switches keep Spotify's Apple Events boundary opt-in. The
/// command switch is intentionally independent from read activation so a
/// metadata-only launch never advertises playback control.
struct SpotifyActivationConfiguration: Equatable, Sendable {
    static let readArgument = "--enable-spotify-read"
    static let commandsArgument = "--enable-spotify-commands"

    let appleEventsEnabled: Bool
    let commandsEnabled: Bool

    init(arguments: [String]) {
        let switches = Set(arguments.dropFirst())
        let readEnabled = switches.contains(Self.readArgument)
        appleEventsEnabled = readEnabled
        commandsEnabled = readEnabled && switches.contains(Self.commandsArgument)
    }

    static func fromProcessArguments() -> Self {
        Self(arguments: ProcessInfo.processInfo.arguments)
    }

    /// SwiftPM's executable product is a raw Mach-O binary. Sending Apple
    /// Events from that binary has no stable bundle identity or usage
    /// description for TCC, so only an explicitly packaged `.app` may activate
    /// the Spotify adapter.
    static func canRequestAppleEvents(bundle: Bundle = .main) -> Bool {
        guard bundle.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let usageDescription = bundle.object(
                  forInfoDictionaryKey: "NSAppleEventsUsageDescription"
              ) as? String
        else {
            return false
        }

        return !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
func makeSystemMediaCoordinator(
    spotifyAppleEventsEnabled: Bool = false,
    spotifyCommandsEnabled: Bool = false
) -> MediaCoordinator {
    var providers: [any MediaProvider] = [PrivateMediaRemoteProvider()]
    if spotifyAppleEventsEnabled {
        providers.append(SpotifyMediaProvider(
            enabled: true,
            commandsEnabled: spotifyCommandsEnabled
        ))
    }
    return MediaCoordinator(providers: providers)
}
