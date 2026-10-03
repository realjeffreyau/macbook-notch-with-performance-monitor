import AppKit

/// Owns the accessory application's always-available menu-bar recovery path.
///
/// The status item is event-driven: its menu state is refreshed when the menu
/// opens and after the one explicit toggle action. It does not use a timer,
/// polling loop, global event monitor, helper process, network, or login-item
/// API. Keeping it separate from the notch panel means the user can reopen
/// Settings and re-enable the panel after disabling it there.
///
/// Keep Awake controls live here too, so sessions stay reachable when the
/// notch is disabled or the built-in display is closed. The menu shows a
/// static end time; it never runs a countdown.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let idleSymbol = "rectangle.topthird.inset.filled"
    private static let keepAwakeSymbol = "cup.and.saucer.fill"

    private let preferences: NotchPreferences
    private let keepAwakeStatus: @MainActor () -> KeepAwakeStatus
    private let onKeepAwakeStart: @MainActor (KeepAwakeDuration) -> Void
    private let onKeepAwakeStop: @MainActor () -> Void
    private let onOpenOrExpandNotch: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void
    private let presentation = KeepAwakePresentation()
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let openOrExpandItem: NSMenuItem
    private let toggleNotchItem: NSMenuItem
    private let keepAwakeStatusItem: NSMenuItem
    private let keepAwakeToggleItem: NSMenuItem
    private let keepAwakeDurationItem: NSMenuItem
    private let settingsItem: NSMenuItem
    private let quitItem: NSMenuItem
    private var keepAwakeDetailItems: [NSMenuItem] = []

    init(
        preferences: NotchPreferences,
        keepAwakeStatus: @escaping @MainActor () -> KeepAwakeStatus,
        onKeepAwakeStart: @escaping @MainActor (KeepAwakeDuration) -> Void,
        onKeepAwakeStop: @escaping @MainActor () -> Void,
        onOpenOrExpandNotch: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.preferences = preferences
        self.keepAwakeStatus = keepAwakeStatus
        self.onKeepAwakeStart = onKeepAwakeStart
        self.onKeepAwakeStop = onKeepAwakeStop
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
        keepAwakeStatusItem = NSMenuItem(title: "Keep Awake is off", action: nil, keyEquivalent: "")
        keepAwakeToggleItem = NSMenuItem(
            title: "Start Keep Awake",
            action: #selector(toggleKeepAwakeAction),
            keyEquivalent: ""
        )
        keepAwakeDurationItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
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

        keepAwakeDurationItem.submenu = makeDurationMenu()

        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(openOrExpandItem)
        menu.addItem(toggleNotchItem)
        menu.addItem(.separator())
        menu.addItem(keepAwakeStatusItem)
        menu.addItem(keepAwakeToggleItem)
        menu.addItem(keepAwakeDurationItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        for item in [openOrExpandItem, toggleNotchItem, keepAwakeToggleItem, settingsItem, quitItem] {
            item.target = self
        }
        keepAwakeStatusItem.isEnabled = false

        if let button = statusItem.button {
            button.setAccessibilityLabel("Dynamic Notch menu")
        }
        setKeepAwakeActive(false)
        statusItem.menu = menu
        refreshMenuState()
    }

    func stop() {
        menu.delegate = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Swaps the existing status item's symbol while a session runs; this is
    /// the only always-visible Keep Awake indicator and adds no second item.
    func setKeepAwakeActive(_ isActive: Bool) {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: isActive ? Self.keepAwakeSymbol : Self.idleSymbol,
            accessibilityDescription: isActive ? "Dynamic Notch, Keep Awake on" : "Dynamic Notch"
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = isActive ? "Dynamic Notch · Keep Awake on" : "Dynamic Notch"
    }

    /// Asks for an end time with a native, keyboard-accessible picker.
    func presentUntilTimePicker() {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Date().addingTimeInterval(60 * 60)
        picker.sizeToFit()
        picker.setAccessibilityLabel("End time")

        let alert = NSAlert()
        alert.icon = NSImage(
            systemSymbolName: Self.idleSymbol,
            accessibilityDescription: "Dynamic Notch"
        )
        alert.messageText = "Keep awake until"
        alert.informativeText = "If that time has already passed today, Keep Awake runs until then tomorrow."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = picker
        // Lay out first so the actual dialog sits below screen center.
        // Choose the screen where the user invoked the control.
        alert.layout()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let screen {
            let visibleFrame = screen.visibleFrame
            let size = alert.window.frame.size
            alert.window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: max(visibleFrame.minY + 16, visibleFrame.midY - size.height / 2 - 80)
            ))
        } else {
            alert.window.center()
        }

        guard alert.runModal() == .alertFirstButtonReturn,
              let end = presentation.nextOccurrence(ofTimeIn: picker.dateValue, after: Date())
        else { return }
        onKeepAwakeStart(.until(end))
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

        let keepAwake = KeepAwakeMenuModel.make(
            status: keepAwakeStatus(),
            defaultPreset: preferences.keepAwakeDurationPreset,
            now: Date(),
            presentation: presentation
        )
        keepAwakeStatusItem.title = keepAwake.statusTitle
        keepAwakeToggleItem.title = keepAwake.toggleTitle
        for item in keepAwakeDurationItem.submenu?.items ?? [] {
            if let rawValue = item.representedObject as? String {
                item.state = rawValue == keepAwake.selectedPreset?.rawValue ? .on : .off
            } else if item.action == #selector(startUntilTimeAction) {
                item.state = keepAwake.isUntilTimeSelected ? .on : .off
            }
        }

        for item in keepAwakeDetailItems {
            menu.removeItem(item)
        }
        keepAwakeDetailItems = keepAwake.detailLines.map { line in
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            return item
        }
        let insertionIndex = menu.index(of: keepAwakeStatusItem) + 1
        for (offset, item) in keepAwakeDetailItems.enumerated() {
            menu.insertItem(item, at: insertionIndex + offset)
        }
    }

    private func makeDurationMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for preset in KeepAwakeDurationPreset.allCases {
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(startPresetAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.rawValue
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let untilItem = NSMenuItem(
            title: "Until a Time…",
            action: #selector(startUntilTimeAction),
            keyEquivalent: ""
        )
        untilItem.target = self
        submenu.addItem(untilItem)
        return submenu
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

    @objc private func toggleKeepAwakeAction() {
        if keepAwakeStatus().isActive {
            onKeepAwakeStop()
        } else {
            onKeepAwakeStart(preferences.keepAwakeDurationPreset.duration)
        }
    }

    @objc private func startPresetAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = KeepAwakeDurationPreset(rawValue: rawValue) else { return }
        onKeepAwakeStart(preset.duration)
    }

    @objc private func startUntilTimeAction() {
        presentUntilTimePicker()
    }

    @objc private func openSettingsAction() {
        onOpenSettings()
    }

    @objc private func quitAction() {
        onQuit()
    }
}
