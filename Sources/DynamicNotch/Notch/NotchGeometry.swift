import CoreGraphics

/// The AppKit values needed to decide whether a display has a camera housing.
/// Keeping this snapshot free of NSScreen makes the geometry deterministic in tests.
public struct NotchScreenSnapshot: Equatable, Sendable {
    public let identifier: String
    public let frame: CGRect
    public let safeAreaTopInset: CGFloat
    public let auxiliaryTopLeftArea: CGRect?
    public let auxiliaryTopRightArea: CGRect?
    public let backingScaleFactor: CGFloat

    public init(
        identifier: String,
        frame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        backingScaleFactor: CGFloat = 1
    ) {
        self.identifier = identifier
        self.frame = frame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.backingScaleFactor = backingScaleFactor
    }
}

public struct NotchGeometry: Equatable, Sendable {
    public let screenIdentifier: String
    public let screenFrame: CGRect
    public let notchRect: CGRect
    public let topCenterAnchor: CGPoint
    public let backingScaleFactor: CGFloat

    private static let minimumNotchWidth: CGFloat = 2
    private static let minimumNotchHeight: CGFloat = 2

    /// Derives the physical camera-housing region from documented NSScreen geometry.
    ///
    /// The auxiliary areas are global screen-coordinate rectangles. Their horizontal
    /// gap is the only source of notch width; no Mac model dimensions are assumed.
    public static func derive(from snapshot: NotchScreenSnapshot) -> NotchGeometry? {
        let frame = snapshot.frame.standardized
        let topInset = snapshot.safeAreaTopInset
        let scale = snapshot.backingScaleFactor.isFinite && snapshot.backingScaleFactor > 0
            ? snapshot.backingScaleFactor
            : 1

        guard frame.width > 0, frame.height > 0,
              topInset > 0, topInset < frame.height,
              let leftArea = snapshot.auxiliaryTopLeftArea?.standardized,
              let rightArea = snapshot.auxiliaryTopRightArea?.standardized,
              !leftArea.isNull, !rightArea.isNull,
              !leftArea.isEmpty, !rightArea.isEmpty,
              leftArea.intersects(frame), rightArea.intersects(frame) else {
            return nil
        }

        let top = frame.maxY - topInset
        guard top > frame.minY, top < frame.maxY,
              leftArea.maxY >= top, rightArea.maxY >= top else {
            return nil
        }

        let rawWidth = rightArea.minX - leftArea.maxX
        guard rawWidth >= minimumNotchWidth else {
            return nil
        }

        let rawRect = CGRect(
            x: leftArea.maxX,
            y: top,
            width: rawWidth,
            height: topInset
        )
        guard frame.contains(rawRect.origin),
              rawRect.maxX <= frame.maxX,
              rawRect.maxY <= frame.maxY else {
            return nil
        }

        // Align inward to display pixels so the transparent click surface never
        // extends beyond the API-derived physical region at fractional scaling.
        let alignedRect = inwardPixelAlignedRect(rawRect, scale: scale)
        guard alignedRect.width >= minimumNotchWidth,
              alignedRect.height >= minimumNotchHeight else {
            return nil
        }

        return NotchGeometry(
            screenIdentifier: snapshot.identifier,
            screenFrame: frame,
            notchRect: alignedRect,
            topCenterAnchor: CGPoint(x: alignedRect.midX, y: alignedRect.maxY),
            backingScaleFactor: scale
        )
    }

    /// Selects a credible display without relying on NSScreen.main or screen order.
    public static func select(from snapshots: [NotchScreenSnapshot]) -> NotchGeometry? {
        snapshots
            .compactMap(derive(from:))
            .max { lhs, rhs in
                if lhs.notchRect.width == rhs.notchRect.width {
                    return lhs.notchRect.height < rhs.notchRect.height
                }
                return lhs.notchRect.width < rhs.notchRect.width
            }
    }

    private static func inwardPixelAlignedRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = ceil(rect.minX * scale) / scale
        let maxX = floor(rect.maxX * scale) / scale
        let minY = ceil(rect.minY * scale) / scale
        let maxY = floor(rect.maxY * scale) / scale
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
}
