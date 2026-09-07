import Testing
@testable import DynamicNotch

@Test("Spotify activation is disabled without an explicit read switch")
func spotifyActivationDefaultsToDisabled() {
    let configuration = SpotifyActivationConfiguration(arguments: ["DynamicNotch"])

    #expect(configuration.appleEventsEnabled == false)
    #expect(configuration.commandsEnabled == false)
}

@Test("raw SwiftPM executable cannot request Spotify Automation")
func rawSwiftPMExecutableCannotRequestAppleEvents() {
    // Unit tests run from an .xctest bundle, not the manually packaged
    // DynamicNotch.app used for the explicit first-use path.
    #expect(SpotifyActivationConfiguration.canRequestAppleEvents() == false)
}

@Test("Spotify command activation cannot bypass read activation")
func spotifyCommandSwitchRequiresReadSwitch() {
    let configuration = SpotifyActivationConfiguration(arguments: [
        "DynamicNotch",
        SpotifyActivationConfiguration.commandsArgument
    ])

    #expect(configuration.appleEventsEnabled == false)
    #expect(configuration.commandsEnabled == false)
}

@Test("Spotify read and command switches are independently explicit")
func spotifyReadAndCommandSwitchesAreExplicit() {
    let readOnly = SpotifyActivationConfiguration(arguments: [
        "DynamicNotch",
        SpotifyActivationConfiguration.readArgument
    ])
    let withCommands = SpotifyActivationConfiguration(arguments: [
        "DynamicNotch",
        SpotifyActivationConfiguration.readArgument,
        SpotifyActivationConfiguration.commandsArgument
    ])

    #expect(readOnly.appleEventsEnabled)
    #expect(readOnly.commandsEnabled == false)
    #expect(withCommands.appleEventsEnabled)
    #expect(withCommands.commandsEnabled)
}
