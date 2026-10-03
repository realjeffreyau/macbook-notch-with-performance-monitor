import AppKit
import DynamicNotchMedia

/// Bridges NSWorkspace's concurrent launch completion back to the main actor
/// without capturing the AppDelegate in a background callback. The relay is
/// short-lived and is retained by the completion closure until the launch
/// either succeeds or fails.
private final class RestartCompletionRelay: @unchecked Sendable {
    private let handler: @MainActor (String?) -> Void

    init(handler: @escaping @MainActor (String?) -> Void) {
        self.handler = handler
    }

    func complete(errorMessage: String?) {
        let handler = self.handler
        Task { @MainActor in
            handler(errorMessage)
        }
    }
}

/// NSWorkspace invokes its completion handler on a concurrent Launch Services
/// queue. Build that closure outside the AppDelegate's MainActor context so it
/// can safely forward only a Sendable error message through the relay.
private func makeRestartCompletionHandler(
    relay: RestartCompletionRelay
) -> @Sendable (NSRunningApplication?, Error?) -> Void {
    { _, error in
        relay.complete(errorMessage: error?.localizedDescription)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var notchWindowController: NotchWindowController?
    private var mediaCoordinator: MediaCoordinator?
    private var outputDeviceService: (any MediaOutputDeviceService)?
    private var captureActivityService: CaptureActivityService?
    private var systemStatsService: SystemStatsService?
    private var fileShelfService: FileShelfService?
    private var launchAtLoginService: LaunchAtLoginService?
    private var settingsWindowController: SettingsWindowController?
    private var menuBarController: MenuBarController?
    private var keepAwakeController: KeepAwakeController?
    private var lowPowerModeService: LowPowerModeService?
    private var terminationSignalSource: (any DispatchSourceSignal)?
    private var isRestarting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory policy keeps the app out of the Dock; the dedicated
        // status item below is the only intentional menu-bar surface.
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        let launchAtLoginService = LaunchAtLoginService()
        self.launchAtLoginService = launchAtLoginService
        state.preferences.onStartAtLoginChange = { @MainActor enabled in
            launchAtLoginService.apply(enabled: enabled)
        }

        // The default is false, so normal startup never registers a login
        // item. A previously opted-in user is synchronized only because the
        // persisted preference explicitly requests it.
        if state.preferences.startAtLogin,
           !launchAtLoginService.apply(enabled: true) {
            state.preferences.startAtLogin = false
        }

        // Media discovery remains provider-agnostic, while the selected
        // session is projected into the notch state for the media surface.
        // The generic provider remains the default. Spotify Apple Events are
        // only constructed after an explicit launch switch, so normal startup
        // does not ask for Automation permission or read another application.
        let spotifyActivation = SpotifyActivationConfiguration.fromProcessArguments()
        let packagedSpotifyActivation = spotifyActivation.appleEventsEnabled
            && SpotifyActivationConfiguration.canRequestAppleEvents()

        if spotifyActivation.appleEventsEnabled && !packagedSpotifyActivation {
            // Keep a raw `swift run` executable from accidentally sending an
            // Apple Event without a stable TCC identity and usage description.
            // The explicit launch switch remains harmless until the caller
            // follows the packaged-app steps in README.md.
            fputs(
                "Dynamic Notch: Spotify read requested, but this executable is not a packaged app with NSAppleEventsUsageDescription; Spotify remains disabled. See README.md.\n",
                stderr
            )
        }
        let mediaCoordinator = makeSystemMediaCoordinator(
            spotifyAppleEventsEnabled: packagedSpotifyActivation,
            spotifyCommandsEnabled: packagedSpotifyActivation && spotifyActivation.commandsEnabled
        )
        mediaCoordinator.onSessionUpdate = { @MainActor [weak state] session in
            state?.updateMediaSession(session)
        }

        let outputDeviceService = CoreAudioOutputDeviceService()
        outputDeviceService.onDeviceUpdate = { @MainActor [weak mediaCoordinator] outputDevice in
            mediaCoordinator?.updateOutputDevice(outputDevice)
        }

        let captureActivityService = AVCaptureActivityService()
        let systemStatsService = SystemStatsService()
        systemStatsService.onUpdate = { @MainActor [weak state] snapshot in
            state?.updateSystemStats(snapshot)
        }

        // Keep Awake starts inactive on every launch; only its configuration
        // persists. Recovery first undoes a closed-lid override that a crash
        // may have left in the kernel.
        let keepAwakeController = KeepAwakeController(
            assertions: IOKitPowerAssertionBackend(),
            closedLid: IOKitClosedLidBackend(),
            powerSource: IOKitPowerSourceMonitor(),
            systemEvents: WorkspaceKeepAwakeSystemEvents(),
            scheduler: DispatchKeepAwakeScheduler()
        )
        keepAwakeController.recoverAfterUnexpectedExit()
        keepAwakeController.onStatusChange = { @MainActor [weak self, weak state] status in
            state?.updateKeepAwakeStatus(status)
            self?.menuBarController?.setKeepAwakeActive(status.isActive)
        }
        let lowPowerModeService = LowPowerModeService(backend: MacEnergyModeBackend())
        self.lowPowerModeService = lowPowerModeService
        lowPowerModeService.onStatusChange = { [weak state] message in
            state?.preferences.keepAwakeEnergyModeStatus = message
        }
        let refreshEnergyHelper: @MainActor () -> Void = { [weak state, weak lowPowerModeService] in
            guard let state else { return }
            state.preferences.energyHelperStatus = EnergyHelperSetup.statusMessage
            lowPowerModeService?.setEnabled(
                state.preferences.keepAwakeClosedLidEnabled && state.preferences.keepAwakeLowPowerWithClosedLid
            )
        }
        state.preferences.onRefreshEnergyHelper = refreshEnergyHelper
        state.preferences.onEnableEnergyHelper = { [weak state] in
            do {
                try EnergyHelperSetup.register()
                refreshEnergyHelper()
            } catch {
                let failure = error as NSError
                state?.preferences.energyHelperStatus = "Energy helper registration failed: \(failure.localizedDescription) (\(failure.domain), \(failure.code))."
                NSLog("Energy helper registration failed: %@", failure)
            }
        }
        state.preferences.onDisableEnergyHelper = { [weak state, weak lowPowerModeService] in
            Task { @MainActor in
                guard let state, let lowPowerModeService else { return }
                guard await lowPowerModeService.restoreForQuit() else {
                    state.preferences.energyHelperStatus = "Restore the saved energy modes before removing the helper."
                    return
                }
                state.preferences.keepAwakeLowPowerWithClosedLid = false
                do {
                    try await EnergyHelperSetup.unregister()
                    state.preferences.energyHelperStatus = EnergyHelperSetup.statusMessage
                } catch {
                    state.preferences.energyHelperStatus = "Could not remove the energy helper. Retry from Settings."
                }
            }
        }
        state.preferences.energyHelperStatus = EnergyHelperSetup.statusMessage
        state.preferences.onKeepAwakeOptionsChange = { @MainActor [weak keepAwakeController, weak lowPowerModeService, weak state] options in
            keepAwakeController?.updateOptions(options)
            lowPowerModeService?.setEnabled(
                options.closedLidRequested && (state?.preferences.keepAwakeLowPowerWithClosedLid ?? false)
            )
        }
        lowPowerModeService.setEnabled(
            state.preferences.keepAwakeClosedLidEnabled && state.preferences.keepAwakeLowPowerWithClosedLid
        )
        let startKeepAwake: @MainActor (KeepAwakeDuration) -> Void = { [weak keepAwakeController, weak state] duration in
            guard let state else { return }
            keepAwakeController?.start(duration, options: state.preferences.keepAwakeOptions)
        }
        let stopKeepAwake: @MainActor () -> Void = { [weak keepAwakeController] in
            keepAwakeController?.stop()
        }
        self.keepAwakeController = keepAwakeController
        installTerminationSignalHandler()

        let fileShelfService = FileShelfService()
        fileShelfService.onItemsChanged = { @MainActor [weak state] items in
            state?.updateFileShelfItems(items)
        }
        fileShelfService.onDropStateChanged = { @MainActor [weak state] dropState in
            state?.updateFileShelfDropState(dropState)
        }
        let controller = NotchWindowController(
            state: state,
            onMediaCommand: { @MainActor [weak mediaCoordinator] command in
                mediaCoordinator?.send(command) ?? .failure(.notStarted)
            },
            onSystemStatsVisibilityChanged: { @MainActor [weak systemStatsService] isVisible in
                if isVisible {
                    systemStatsService?.start()
                } else {
                    systemStatsService?.stop()
                }
            },
            fileShelfService: fileShelfService,
            onOpenSettings: { @MainActor [weak self] in
                self?.showSettings()
            },
            onFileShelfCopy: { @MainActor [weak fileShelfService] item in
                fileShelfService?.copyToPasteboard(item) ?? false
            },
            keepAwakeActions: KeepAwakeControlActions(
                start: startKeepAwake,
                chooseEndTime: { @MainActor [weak self] in
                    self?.menuBarController?.presentUntilTimePicker()
                },
                stop: stopKeepAwake
            )
        )
        captureActivityService.onActivityUpdate = { @MainActor [weak state, weak controller] activity in
            state?.updateCaptureActivity(activity)
            controller?.refreshCaptureActivityLayout()
        }
        appState = state
        notchWindowController = controller
        self.mediaCoordinator = mediaCoordinator
        self.outputDeviceService = outputDeviceService
        self.captureActivityService = captureActivityService
        self.systemStatsService = systemStatsService
        self.fileShelfService = fileShelfService

        controller.start()
        outputDeviceService.start()
        captureActivityService.start()
        mediaCoordinator.start()

        // Keep this recovery surface alive independently of panel visibility.
        // In particular, disabling the notch from Settings leaves a native
        // status item that can reopen Settings and re-enable it.
        menuBarController = MenuBarController(
            preferences: state.preferences,
            keepAwakeStatus: { @MainActor [weak keepAwakeController] in
                keepAwakeController?.status ?? .inactive
            },
            onKeepAwakeStart: startKeepAwake,
            onKeepAwakeStop: stopKeepAwake,
            onOpenOrExpandNotch: { @MainActor [weak controller] in
                controller?.openOrExpandFromMenu()
            },
            onOpenSettings: { @MainActor [weak self] in
                self?.showSettings()
            },
            onQuit: { @MainActor in
                NSApp.terminate(nil)
            }
        )
        // Explicit setup invoked by the user's script; ordinary launches never
        // register a privileged service or add a background item.
        if ProcessInfo.processInfo.arguments.contains("--register-energy-helper") {
            state.preferences.onEnableEnergyHelper?()
            showSettings()
            NSLog("Energy helper setup: %@", state.preferences.energyHelperStatus)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Restart restores first, before the replacement owns energy policy.
        if isRestarting { return .terminateNow }
        guard let lowPowerModeService, lowPowerModeService.needsRestoration else { return .terminateNow }
        Task { @MainActor in
            let restored = await lowPowerModeService.restoreForQuit()
            if !restored {
                let alert = NSAlert()
                alert.messageText = "Previous energy modes could not be restored"
                alert.informativeText = "Quit anyway and restore them from Battery settings, or cancel to retry. Dynamic Notch has kept the saved modes for recovery on its next launch."
                alert.addButton(withTitle: "Cancel Quit")
                alert.addButton(withTitle: "Quit Anyway")
                NSApp.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            } else {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        lowPowerModeService?.onStatusChange = nil
        lowPowerModeService = nil
        // Release assertions and restore lid-close sleep before anything else.
        keepAwakeController?.stop()
        keepAwakeController?.onStatusChange = nil
        keepAwakeController = nil
        appState?.preferences.onKeepAwakeOptionsChange = nil
        appState?.preferences.onEnableEnergyHelper = nil
        appState?.preferences.onDisableEnergyHelper = nil
        appState?.preferences.onRefreshEnergyHelper = nil
        terminationSignalSource?.cancel()
        terminationSignalSource = nil
        systemStatsService?.stop()
        systemStatsService = nil
        fileShelfService?.stop()
        fileShelfService = nil
        captureActivityService?.stop()
        captureActivityService = nil
        outputDeviceService?.stop()
        outputDeviceService = nil
        mediaCoordinator?.stop()
        mediaCoordinator = nil
        notchWindowController?.stop()
        notchWindowController = nil
        menuBarController?.stop()
        menuBarController = nil
        appState?.preferences.onStartAtLoginChange = nil
        launchAtLoginService = nil
        settingsWindowController?.close()
        settingsWindowController = nil
        appState = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `kill` sends SIGTERM, which otherwise exits without
    /// `applicationWillTerminate`. Route it through normal termination so a
    /// closed-lid override is restored. A dispatch signal source adds no
    /// wakeups while idle.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // AppKit may enter a nested run loop while awaiting an async
            // termination reply. Leave the dispatch callback first so that
            // MainActor restoration tasks can run in that loop.
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                MainActor.assumeIsolated {
                    NSApp.terminate(nil)
                }
            }
        }
        source.resume()
        terminationSignalSource = source
    }

    private func showSettings() {
        guard let state = appState else { return }
        if settingsWindowController == nil {
            // Keep the hidden accessory path lightweight. SwiftUI's settings
            // hierarchy is constructed only after the user explicitly asks
            // for it from the expanded notch.
            settingsWindowController = SettingsWindowController(
                preferences: state.preferences,
                onRefreshAndRestart: { @MainActor [weak self] in
                    self?.refreshAndRestart()
                }
            )
        }
        settingsWindowController?.showSettings()
    }

    private func refreshAndRestart() {
        guard !isRestarting else { return }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            presentRestartFailure(
                "Refresh & restart is available when Dynamic Notch is launched from its packaged .app bundle."
            )
            return
        }

        isRestarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let lowPowerModeService, !(await lowPowerModeService.restoreForQuit()) {
                isRestarting = false
                presentRestartFailure("Previous energy modes could not be restored. Retry the energy-mode setting before restarting.")
                return
            }
            launchReplacement(at: bundleURL)
        }
    }

    private func launchReplacement(at bundleURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

        let relay = RestartCompletionRelay { @MainActor [weak self] errorMessage in
            guard let self else { return }
            if let errorMessage {
                self.isRestarting = false
                if let preferences = self.appState?.preferences {
                    self.lowPowerModeService?.setEnabled(
                        preferences.keepAwakeClosedLidEnabled && preferences.keepAwakeLowPowerWithClosedLid
                    )
                }
                self.presentRestartFailure(errorMessage)
                return
            }

            self.settingsWindowController?.close()
            self.settingsWindowController = nil
            NSApp.terminate(nil)
        }
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration,
            completionHandler: makeRestartCompletionHandler(relay: relay)
        )
    }

    private func presentRestartFailure(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn’t restart Dynamic Notch"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
