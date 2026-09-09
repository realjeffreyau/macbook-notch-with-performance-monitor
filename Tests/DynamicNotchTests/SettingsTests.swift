import Foundation
import Testing
@testable import DynamicNotch

@Test("settings use safe defaults and persist a round trip")
@MainActor
func settingsUseSafeDefaultsAndPersistRoundTrip() {
    let suiteName = "DynamicNotchSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initial = NotchPreferences(defaults: defaults)

    #expect(initial.isNotchEnabled)
    #expect(initial.motionPreference == .followSystem)
    #expect(initial.showCollapsedMediaIndicators)
    #expect(initial.showArtwork)
    #expect(initial.showOutputDevice)
    #expect(initial.showPrivacyIndicators)
    #expect(initial.systemStatsEnabled)
    #expect(initial.fileShelfEnabled)
    #expect(initial.fileShelfMaximumItems == FileShelfLimits.maximumItemCount)
    #expect(!initial.showResourceDiagnostics)
    #expect(!initial.startAtLogin)

    initial.isNotchEnabled = false
    initial.motionPreference = .reduceMotion
    initial.showArtwork = false
    initial.showOutputDevice = false
    initial.showPrivacyIndicators = false
    initial.systemStatsEnabled = false
    initial.fileShelfEnabled = false
    initial.fileShelfMaximumItems = 3
    initial.showResourceDiagnostics = true
    initial.startAtLogin = true

    let reloaded = NotchPreferences(defaults: defaults)
    #expect(!reloaded.isNotchEnabled)
    #expect(reloaded.motionPreference == .reduceMotion)
    #expect(!reloaded.showArtwork)
    #expect(!reloaded.showOutputDevice)
    #expect(!reloaded.showPrivacyIndicators)
    #expect(!reloaded.systemStatsEnabled)
    #expect(!reloaded.fileShelfEnabled)
    #expect(reloaded.fileShelfMaximumItems == 3)
    #expect(reloaded.showResourceDiagnostics)
    #expect(reloaded.startAtLogin)
}

@Test("startup preference reverts when registration is rejected")
@MainActor
func startupPreferenceRevertsWhenRegistrationIsRejected() {
    let suiteName = "DynamicNotchSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = NotchPreferences(defaults: defaults)
    var requestedValue: Bool?
    preferences.onStartAtLoginChange = { enabled in
        requestedValue = enabled
        return false
    }

    preferences.startAtLogin = true

    #expect(requestedValue == true)
    #expect(!preferences.startAtLogin)
    #expect(defaults.object(forKey: NotchPreferences.Key.startAtLogin) == nil)
}

@Test("settings clamp the File Shelf bound and notify synchronously")
@MainActor
func settingsClampFileShelfBoundAndNotifySynchronously() {
    let suiteName = "DynamicNotchSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = NotchPreferences(defaults: defaults)
    var changeCount = 0
    preferences.onChange = { changeCount += 1 }

    preferences.fileShelfMaximumItems = 0
    #expect(preferences.fileShelfMaximumItems == 1)
    #expect(changeCount == 1)

    preferences.fileShelfMaximumItems = FileShelfLimits.maximumItemCount + 1
    #expect(preferences.fileShelfMaximumItems == FileShelfLimits.maximumItemCount)
    #expect(changeCount == 2)
    #expect(defaults.integer(forKey: NotchPreferences.Key.fileShelfMaximumItems)
        == FileShelfLimits.maximumItemCount)
}

@Test("motion preference follows the system or its explicit override")
@MainActor
func motionPreferenceFollowsSystemOrExplicitOverride() {
    let suiteName = "DynamicNotchSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = NotchPreferences(defaults: defaults)

    #expect(preferences.shouldReduceMotion(systemValue: true))
    #expect(!preferences.shouldReduceMotion(systemValue: false))

    preferences.motionPreference = .reduceMotion
    #expect(preferences.shouldReduceMotion(systemValue: false))

    preferences.motionPreference = .animate
    #expect(!preferences.shouldReduceMotion(systemValue: true))
}

@Test("expanded pages remain bounded by enabled local features")
@MainActor
func expandedPagesRemainBoundedByEnabledLocalFeatures() {
    #expect(
        NotchExpandedPage.available(systemStatsEnabled: true, fileShelfEnabled: true)
            == [.media, .system, .files]
    )
    #expect(
        NotchExpandedPage.available(systemStatsEnabled: false, fileShelfEnabled: true)
            == [.media, .files]
    )
    #expect(
        NotchExpandedPage.available(systemStatsEnabled: true, fileShelfEnabled: false)
            == [.media, .system]
    )
    #expect(
        NotchExpandedPage.available(systemStatsEnabled: false, fileShelfEnabled: false)
            == [.media]
    )
}
