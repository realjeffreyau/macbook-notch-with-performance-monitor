import AppKit

/// Owns the accessory application's always-available menu-bar recovery path.
///
/// The status item is event-driven: its menu state is refreshed when the menu
/// opens and after the one explicit toggle action. It does not use a timer,
/// polling loop, global event monitor, helper process, network, or login-item
/// API. Keeping it separate from the notch panel means the user can reopen
/// Settings and re-enable the panel after disabling it there.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let preferences: NotchPreferences
    private let onOpenOrExpandNotch: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let openOrExpandItem: NSMenuItem
    private let toggleNotchItem: NSMenuItem
    private let settingsItem: NSMenuItem
    private let quitItem: NSMenuItem

    init(
        preferences: NotchPreferences,
        onOpenOrExpandNotch: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.preferences = preferences
        self.onOpenOrExpandNotch = onOpenOrExpandNotch
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        openOrExpandItem = NSMenuItem(
            title: "Open / Expand Notch",
            action: #selector(openOrExpandNotchAction),
            keyEquivalent: ""
        )
        toggleNotchItem = NSMenuItem(
            title: "Disable Dynamic Notch",
            action: #selector(toggleNotchAction),
            keyEquivalent: ""
        )
        settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        quitItem = NSMenuItem(
            title: "Quit Dynamic Notch",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )

        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(openOrExpandItem)
        menu.addItem(toggleNotchItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        for item in [openOrExpandItem, toggleNotchItem, settingsItem, quitItem] {
            item.target = self
        }

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "rectangle.topthird.inset.filled",
                accessibilityDescription: "Dynamic Notch"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Dynamic Notch"
            button.setAccessibilityLabel("Dynamic Notch menu")
        }
        statusItem.menu = menu
        refreshMenuState()
    }

    func stop() {
        menu.delegate = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func refreshMenuState() {
        let model = MenuBarMenuModel.current(isNotchEnabled: preferences.isNotchEnabled)
        openOrExpandItem.title = model.openOrExpandTitle
        openOrExpandItem.isEnabled = model.openOrExpandEnabled
        toggleNotchItem.title = model.toggleTitle
        toggleNotchItem.state = model.toggleState == .on ? .on : .off
    }

    @objc private func openOrExpandNotchAction() {
        onOpenOrExpandNotch()
    }

    @objc private func toggleNotchAction() {
        let nextValue = MenuBarMenuModel.nextNotchEnabledValue(
            after: .toggleNotch,
            currentValue: preferences.isNotchEnabled
        )
        preferences.isNotchEnabled = nextValue
        refreshMenuState()
    }

    @objc private func openSettingsAction() {
        onOpenSettings()
    }

    @objc private func quitAction() {
        onQuit()
    }
}
