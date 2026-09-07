import Testing
@testable import DynamicNotch

@Test("menu model keeps the recovery actions available by preference state")
func menuModelKeepsRecoveryActionsAvailableByPreferenceState() {
    let enabled = MenuBarMenuModel.current(isNotchEnabled: true)
    #expect(enabled.openOrExpandTitle == "Open / Expand Notch")
    #expect(enabled.openOrExpandEnabled)
    #expect(enabled.toggleTitle == "Disable Dynamic Notch")
    #expect(enabled.toggleState == .on)

    let disabled = MenuBarMenuModel.current(isNotchEnabled: false)
    #expect(disabled.openOrExpandTitle == "Open / Expand Notch")
    #expect(!disabled.openOrExpandEnabled)
    #expect(disabled.toggleTitle == "Enable Dynamic Notch")
    #expect(disabled.toggleState == .off)
}

@Test("menu toggle reducer changes only the notch enabled preference")
func menuToggleReducerChangesOnlyNotchEnabledPreference() {
    #expect(
        MenuBarMenuModel.nextNotchEnabledValue(
            after: .toggleNotch,
            currentValue: true
        ) == false
    )
    #expect(
        MenuBarMenuModel.nextNotchEnabledValue(
            after: .toggleNotch,
            currentValue: false
        ) == true
    )
    #expect(
        MenuBarMenuModel.nextNotchEnabledValue(
            after: .openSettings,
            currentValue: false
        ) == false
    )
    #expect(
        MenuBarMenuModel.nextNotchEnabledValue(
            after: .quit,
            currentValue: true
        ) == true
    )
}
