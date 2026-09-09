import AppKit
import DynamicNotchMedia
import SwiftUI

@MainActor
final class NotchWindowController {
    private let state: AppState
    private let preferences: NotchPreferences
    private let panel: NotchPanel
    private let lifecycleTokens = NotchLifecycleTokens()
    private let onMediaCommand: @MainActor (MediaCommand) -> Result<Void, MediaProviderError>
    private let onSystemStatsVisibilityChanged: @MainActor (Bool) -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onFileShelfCopy: @MainActor (FileShelfItem) -> Bool
    private let fileShelfService: FileShelfService
    private var hostingView: NSHostingView<NotchView>?
    private var presentationBeforeDrop: NotchPresentationState?
    private var fileDropDidComplete = false

    private var isStarted = false

    init(
        state: AppState,
        onMediaCommand: @escaping @MainActor (MediaCommand) -> Result<Void, MediaProviderError> = { _ in
            .failure(.notStarted)
        },
        onSystemStatsVisibilityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        fileShelfService: FileShelfService,
        onOpenSettings: @escaping @MainActor () -> Void = {},
        onFileShelfCopy: @escaping @MainActor (FileShelfItem) -> Bool = { _ in false }
    ) {
        self.state = state
        preferences = state.preferences
        panel = NotchPanel()
        self.onMediaCommand = onMediaCommand
        self.onSystemStatsVisibilityChanged = onSystemStatsVisibilityChanged
        self.onOpenSettings = onOpenSettings
        self.onFileShelfCopy = onFileShelfCopy
        self.fileShelfService = fileShelfService
    }

    deinit {
        lifecycleTokens.removeAll()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let rootView = NotchView(
            state: state,
            preferences: preferences,
            onToggle: { [weak self] in
                self?.togglePresentation()
            },
            onOpenSettings: onOpenSettings,
            onExpandedPageChange: { [weak self] page in
                self?.setExpandedPage(page)
            },
            onMediaCommand: onMediaCommand,
            onFileShelfReveal: { [weak self] item in
                self?.fileShelfService.revealInFinder(item)
            },
            onFileShelfQuickLook: { [weak self] item in
                self?.fileShelfService.quickLook(item)
            },
            onFileShelfCopy: { [weak self] item in
                self?.onFileShelfCopy(item) ?? false
            },
            onFileShelfRemove: { [weak self] id in
                _ = self?.fileShelfService.remove(id: id)
            },
            onFileShelfClear: { [weak self] in
                self?.fileShelfService.clear()
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.interactionView.install(hostedView: hostingView)
        panel.interactionView.onDraggingEntered = { [weak self] info in
            self?.fileShelfDraggingEntered(info) ?? []
        }
        panel.interactionView.onDraggingUpdated = { [weak self] info in
            self?.fileShelfDraggingUpdated(info) ?? []
        }
        panel.interactionView.onDraggingExited = { [weak self] info in
            self?.fileShelfDraggingExited(info)
        }
        panel.interactionView.onPerformDragOperation = { [weak self] info in
            self?.fileShelfPerformDragOperation(info) ?? false
        }
        panel.interactionView.onConcludeDragOperation = { [weak self] info in
            self?.fileShelfConcludeDragOperation(info)
        }
        panel.interactionView.onDraggingEnded = { [weak self] info in
            self?.fileShelfDraggingEnded(info)
        }
        preferences.onChange = { @MainActor [weak self] in
            self?.preferencesDidChange()
        }
        fileShelfService.setMaximumItemCount(preferences.fileShelfMaximumItems)
        if preferences.fileShelfEnabled {
            fileShelfService.start()
            panel.interactionView.installFileShelfDropDestination()
        }
        self.hostingView = hostingView

        refreshReduceMotionPreference()

        lifecycleTokens.screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshGeometry(animated: true)
            }
        }

        refreshGeometry(animated: false)
    }

    func stop() {
        guard isStarted else { return }
        preferences.onChange = nil
        finishFileShelfDrop(restoring: .collapsed)
        panel.interactionView.removeFileShelfDropDestination()
        removeEventMonitors()

        lifecycleTokens.removeScreenObserver()

        panel.orderOut(nil)
        state.collapse()
        state.updateGeometry(nil)
        onSystemStatsVisibilityChanged(false)
        isStarted = false
    }

    func setExpandedPage(_ page: NotchExpandedPage) {
        guard isStarted,
              preferences.isNotchEnabled,
              state.presentationState == .expanded
        else { return }
        state.setExpandedPage(page)
        refreshSystemStatsVisibility()
    }

    /// Opens the expanded surface from the menu-bar recovery path when the
    /// notch is enabled. A disabled or not-yet-available panel is intentionally
    /// a no-op; the menu still exposes Settings and Enable Dynamic Notch.
    func openOrExpandFromMenu() {
        guard isStarted,
              preferences.isNotchEnabled,
              state.geometry != nil,
              state.presentationState == .collapsed
        else { return }
        setPresentation(.expanded)
    }

    /// Privacy dots are allowed to extend the collapsed panel by a small,
    /// explicit gutter. The panel stays exact to the physical notch when no
    /// capture activity is present, and never creates a wide idle hit target.
    func refreshCaptureActivityLayout() {
        guard isStarted, state.presentationState == .collapsed else { return }
        refreshGeometry(animated: false)
    }

    private func refreshGeometry(animated: Bool) {
        // A screen-change notification may already have queued a main-actor
        // refresh when shutdown begins. Do not re-order or resurrect the
        // panel after stop() has removed its observers and ordered it out.
        guard isStarted else { return }

        guard preferences.isNotchEnabled else {
            panel.orderOut(nil)
            return
        }

        refreshReduceMotionPreference()
        let snapshots = NSScreen.screens.enumerated().map { index, screen in
            screen.notchSnapshot(fallbackIdentifier: "screen-\(index)")
        }
        guard let geometry = NotchGeometry.select(from: snapshots) else {
            finishFileShelfDrop(restoring: .collapsed)
            removeEventMonitors()
            state.updateGeometry(nil)
            panel.orderOut(nil)
            onSystemStatsVisibilityChanged(false)
            return
        }

        state.updateGeometry(geometry)
        panel.interactionView.setInteractionState(interactionState(for: state.presentationState))

        let targetFrame = frame(for: state.presentationState, geometry: geometry)
        let canAnimate = animated && !panel.frame.isEmpty && !state.reduceMotion
        setPanelFrame(targetFrame, animated: canAnimate)
        panel.orderFrontRegardless()
    }

    private func togglePresentation() {
        guard state.geometry != nil else { return }

        let targetState: NotchPresentationState = state.presentationState == .collapsed
            ? .expanded
            : .collapsed
        setPresentation(targetState)
    }

    private func setPresentation(_ targetState: NotchPresentationState) {
        refreshReduceMotionPreference()
        guard preferences.isNotchEnabled, let geometry = state.geometry else { return }

        if targetState == .expanded {
            installEventMonitors()
        } else {
            // Click-away and Escape monitors are scoped to the expanded state
            // and are removed before the collapse animation starts.
            removeEventMonitors()
        }

        // Keep one finite transition path for both motion preferences. Reduce
        // Motion uses a short ease-out with almost no scale change instead of
        // snapping the SwiftUI hierarchy while the panel is resizing.
        let animation: Animation = state.reduceMotion
            ? .easeOut(duration: NotchDesignTokens.reducedMotionAnimationDuration)
            : .spring(
                response: NotchDesignTokens.animationDuration,
                dampingFraction: 0.86,
                blendDuration: 0.06
            )
        withAnimation(animation) {
            state.setPresentation(targetState)
        }

        panel.interactionView.setInteractionState(interactionState(for: targetState))
        setPanelFrame(
            frame(for: targetState, geometry: geometry),
            animated: true
        )
        refreshSystemStatsVisibility()
    }

    private func refreshSystemStatsVisibility() {
        onSystemStatsVisibilityChanged(
            isStarted
                && preferences.isNotchEnabled
                && preferences.systemStatsEnabled
                && state.presentationState == .expanded
                && state.expandedPage == .system
        )
    }

    private func frame(
        for presentationState: NotchPresentationState,
        geometry: NotchGeometry
    ) -> NSRect {
        switch presentationState {
        case .collapsed:
            let width = state.captureActivity.isActive && preferences.showPrivacyIndicators
                ? geometry.notchRect.width + 2 * NotchDesignTokens.privacyIndicatorGutter
                : geometry.notchRect.width
            return NSRect(
                x: geometry.notchRect.midX - width / 2,
                y: geometry.notchRect.minY,
                width: width,
                height: geometry.notchRect.height
            )
        case .expanded, .dropTarget:
            let width = max(NotchDesignTokens.expandedWidth, geometry.notchRect.width + 160)
            let height = NotchDesignTokens.expandedHeight
            return NSRect(
                x: geometry.topCenterAnchor.x - width / 2,
                y: geometry.topCenterAnchor.y - height,
                width: width,
                height: height
            )
        }
    }

    private func interactionState(
        for presentationState: NotchPresentationState
    ) -> NotchPanelContentView.InteractionState {
        switch presentationState {
        case .collapsed: return .collapsed
        case .expanded: return .expanded
        case .dropTarget: return .dropTarget
        }
    }

    // MARK: - File Shelf drag destination

    private func fileShelfDraggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard isStarted,
              preferences.isNotchEnabled,
              preferences.fileShelfEnabled,
              !FileShelfDragReader.localFileURLs(in: info).isEmpty
        else {
            return []
        }

        if presentationBeforeDrop == nil {
            presentationBeforeDrop = state.presentationState == .dropTarget
                ? .collapsed
                : state.presentationState
        }
        fileDropDidComplete = false
        fileShelfService.setDropState(.hovering)

        if state.presentationState != .dropTarget {
            state.setPresentation(.dropTarget)
            panel.interactionView.setInteractionState(.dropTarget)
            if let geometry = state.geometry {
                setPanelFrame(frame(for: .dropTarget, geometry: geometry), animated: !state.reduceMotion)
            }
        }
        return .copy
    }

    private func fileShelfDraggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard state.presentationState == .dropTarget,
              !FileShelfDragReader.localFileURLs(in: info).isEmpty
        else { return [] }
        return .copy
    }

    private func fileShelfDraggingExited(_ info: NSDraggingInfo?) {
        guard !fileDropDidComplete else { return }
        finishFileShelfDrop(restoring: presentationBeforeDrop ?? .collapsed)
    }

    private func fileShelfPerformDragOperation(_ info: NSDraggingInfo) -> Bool {
        let imported = fileShelfService.importLocalFileURLs(
            FileShelfDragReader.localFileURLs(in: info)
        )
        guard !imported.isEmpty else {
            finishFileShelfDrop(restoring: presentationBeforeDrop ?? .collapsed)
            return false
        }

        fileDropDidComplete = true
        presentationBeforeDrop = nil
        fileShelfService.setDropState(.inactive)
        state.setExpandedPage(.files)

        // A successful drop leaves the user on Files, while a cancelled or
        // unsupported drag restores the presentation that existed before the
        // temporary target appeared.
        if state.presentationState == .dropTarget {
            setPresentation(.expanded)
        }
        return true
    }

    private func fileShelfConcludeDragOperation(_ info: NSDraggingInfo?) {
        guard !fileDropDidComplete else { return }
        finishFileShelfDrop(restoring: presentationBeforeDrop ?? .collapsed)
    }

    private func fileShelfDraggingEnded(_ info: NSDraggingInfo?) {
        guard !fileDropDidComplete else {
            fileDropDidComplete = false
            return
        }
        finishFileShelfDrop(restoring: presentationBeforeDrop ?? .collapsed)
    }

    private func finishFileShelfDrop(restoring presentation: NotchPresentationState) {
        let hadDropSession = presentationBeforeDrop != nil
            || state.presentationState == .dropTarget
        presentationBeforeDrop = nil
        fileDropDidComplete = false
        fileShelfService.setDropState(.inactive)
        guard hadDropSession, isStarted, state.presentationState == .dropTarget else {
            return
        }
        setPresentation(presentation == .dropTarget ? .collapsed : presentation)
    }

    private func setPanelFrame(_ frame: NSRect, animated: Bool) {
        // NSWindow's explicit frame animation honors animationResizeTime(_:) on
        // the specialized panel, keeping the top-center anchor fixed while the
        // window grows or collapses. Reduce Motion keeps the same finite path
        // with a shorter duration, rather than leaving an implicit snap.
        panel.resizeAnimationDuration = state.reduceMotion
            ? NotchDesignTokens.reducedMotionAnimationDuration
            : NotchDesignTokens.animationDuration
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func refreshReduceMotionPreference() {
        state.setReduceMotion(
            preferences.shouldReduceMotion(
                systemValue: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        )
    }

    private func preferencesDidChange() {
        guard isStarted else { return }

        fileShelfService.setMaximumItemCount(preferences.fileShelfMaximumItems)
        state.normalizeExpandedPage()

        if preferences.fileShelfEnabled {
            fileShelfService.start()
            panel.interactionView.installFileShelfDropDestination()
        } else {
            finishFileShelfDrop(restoring: .collapsed)
            panel.interactionView.removeFileShelfDropDestination()
            fileShelfService.stop()
        }

        if preferences.isNotchEnabled {
            refreshGeometry(animated: false)
        } else {
            finishFileShelfDrop(restoring: .collapsed)
            removeEventMonitors()
            state.collapse()
            state.updateGeometry(nil)
            panel.orderOut(nil)
        }
        refreshSystemStatsVisibility()
    }

    private func installEventMonitors() {
        removeEventMonitors()

        let mouseDownMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        lifecycleTokens.globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownMask) {
            [weak self] event in
            guard let self, !self.isInsideVisibleSurface(event) else { return }
            self.setPresentation(.collapsed)
        }

        lifecycleTokens.localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) {
            [weak self] event in
            guard let self else { return event }
            if !self.isInsideVisibleSurface(event) {
                self.setPresentation(.collapsed)
            }
            return event
        }

        // A local monitor handles Escape for events delivered to this app. A
        // universal keyboard hook would require broader permissions and is not
        // appropriate for this minimal accessory utility.
        lifecycleTokens.localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            self.setPresentation(.collapsed)
            return nil
        }
    }

    private func removeEventMonitors() {
        lifecycleTokens.removeEventMonitors()
    }

    private func isInsideVisibleSurface(_ event: NSEvent) -> Bool {
        let screenPoint: NSPoint
        if let eventWindow = event.window {
            screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else {
            // Global monitor events use screen coordinates when no event window
            // is attached, which is the coordinate space used by panel.frame.
            screenPoint = event.locationInWindow
        }

        let panelPoint = NSPoint(
            x: screenPoint.x - panel.frame.minX,
            y: screenPoint.y - panel.frame.minY
        )
        return panel.interactionView.isInsideVisibleSurface(panelPoint)
    }
}

/// Event and notification tokens are kept together so teardown remains possible
/// even if a controller is released before the application delegate callback.
private final class NotchLifecycleTokens: @unchecked Sendable {
    var screenParametersObserver: NSObjectProtocol?
    var globalMouseMonitor: Any?
    var localMouseMonitor: Any?
    var localKeyMonitor: Any?

    func removeScreenObserver() {
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParametersObserver = nil
        }
    }

    func removeEventMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    func removeAll() {
        removeScreenObserver()
        removeEventMonitors()
    }

    deinit {
        removeAll()
    }
}

private extension NSScreen {
    func notchSnapshot(fallbackIdentifier: String) -> NotchScreenSnapshot {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let identifier = (deviceDescription[screenNumberKey] as? NSNumber)?.stringValue
            ?? fallbackIdentifier

        return NotchScreenSnapshot(
            identifier: identifier,
            frame: frame,
            safeAreaTopInset: safeAreaInsets.top,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            backingScaleFactor: backingScaleFactor
        )
    }
}
