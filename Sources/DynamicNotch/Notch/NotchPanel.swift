import AppKit

final class NotchPanelContentView: NSView {
    enum InteractionState {
        case collapsed
        case expanded
        case dropTarget
    }

    var interactionState: InteractionState = .collapsed
    var onDraggingEntered: ((NSDraggingInfo) -> NSDragOperation)?
    var onDraggingUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onDraggingExited: ((NSDraggingInfo?) -> Void)?
    var onPerformDragOperation: ((NSDraggingInfo) -> Bool)?
    var onConcludeDragOperation: ((NSDraggingInfo?) -> Void)?
    var onDraggingEnded: ((NSDraggingInfo?) -> Void)?
    private weak var hostedView: NSView?

    func install(hostedView: NSView) {
        self.hostedView = hostedView
        hostedView.translatesAutoresizingMaskIntoConstraints = true
        hostedView.autoresizingMask = [.width, .height]
        addSubview(hostedView)
        hostedView.frame = bounds
    }

    func setInteractionState(_ state: InteractionState) {
        interactionState = state
        window?.invalidateCursorRects(for: self)
    }

    func installFileShelfDropDestination() {
        registerForDraggedTypes([.fileURL])
    }

    func removeFileShelfDropDestination() {
        unregisterDraggedTypes()
        onDraggingEntered = nil
        onDraggingUpdated = nil
        onDraggingExited = nil
        onPerformDragOperation = nil
        onConcludeDragOperation = nil
        onDraggingEnded = nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingEntered?(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingUpdated?(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDraggingExited?(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformDragOperation?(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onConcludeDragOperation?(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo?) {
        onDraggingEnded?(sender)
    }

    override func layout() {
        super.layout()
        hostedView?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInsideVisibleSurface(point) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        switch interactionState {
        case .collapsed:
            // This rect is useful when the target is rendered; the hardware
            // cutout itself has no pixels in which a cursor can be drawn.
            addCursorRect(bounds, cursor: .arrow)
        case .expanded, .dropTarget:
            // Keep the hand cursor inside the solid software card and away from
            // its transparent rounded corners.
            let horizontalInset = min(NotchDesignTokens.expandedCornerRadius, bounds.width / 2)
            addCursorRect(
                bounds.insetBy(dx: horizontalInset, dy: 0),
                cursor: .pointingHand
            )
        }
    }

    func isInsideVisibleSurface(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else {
            return false
        }

        switch interactionState {
        case .collapsed:
            return true
        case .expanded, .dropTarget:
            let path = CGPath(
                roundedRect: bounds,
                cornerWidth: NotchDesignTokens.expandedCornerRadius,
                cornerHeight: NotchDesignTokens.expandedCornerRadius,
                transform: nil
            )
            return path.contains(point)
        }
    }
}

/// A transparent, status-level panel dedicated to the physical notch region.
final class NotchPanel: NSPanel {
    let interactionView: NotchPanelContentView

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        NotchDesignTokens.animationDuration
    }

    init() {
        interactionView = NotchPanelContentView(frame: .zero)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        contentView = interactionView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = .statusBar

        // Join each Space and remain eligible above fullscreen content, while
        // staying transient and out of Mission Control/window cycling.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
    }
}
