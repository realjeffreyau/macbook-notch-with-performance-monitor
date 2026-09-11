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
            }
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
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

        let relay = RestartCompletionRelay { @MainActor [weak self] errorMessage in
            guard let self else { return }
            if let errorMessage {
                self.isRestarting = false
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
