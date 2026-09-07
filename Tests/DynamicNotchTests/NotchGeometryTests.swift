import CoreGraphics
import Testing
@testable import DynamicNotch

@Test("derives a notch from the auxiliary gap and safe area")
func derivesNotchFromAuxiliaryGapAndSafeArea() {
    let snapshot = snapshot(
        id: "built-in",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        topInset: 40,
        left: CGRect(x: 0, y: 860, width: 620, height: 40),
        right: CGRect(x: 820, y: 860, width: 620, height: 40)
    )

    let geometry = NotchGeometry.derive(from: snapshot)

    #expect(geometry?.notchRect == CGRect(x: 620, y: 860, width: 200, height: 40))
    #expect(geometry?.topCenterAnchor == CGPoint(x: 720, y: 900))
}

@Test("rejects missing or empty auxiliary regions")
func rejectsMissingAuxiliaryRegions() {
    let missingLeft = snapshot(
        id: "missing-left",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        topInset: 40,
        left: nil,
        right: CGRect(x: 820, y: 860, width: 620, height: 40)
    )
    let emptyRight = snapshot(
        id: "empty-right",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        topInset: 40,
        left: CGRect(x: 0, y: 860, width: 620, height: 40),
        right: .zero
    )

    #expect(NotchGeometry.derive(from: missingLeft) == nil)
    #expect(NotchGeometry.derive(from: emptyRight) == nil)
}

@Test("rejects a zero top inset")
func rejectsZeroTopInset() {
    let snapshot = snapshot(
        id: "external",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        topInset: 0,
        left: CGRect(x: 0, y: 1056, width: 800, height: 24),
        right: CGRect(x: 1120, y: 1056, width: 800, height: 24)
    )

    #expect(NotchGeometry.derive(from: snapshot) == nil)
}

@Test("rejects an invalid or overlapping gap")
func rejectsInvalidOrOverlappingGap() {
    let overlapping = snapshot(
        id: "overlap",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        topInset: 40,
        left: CGRect(x: 0, y: 860, width: 750, height: 40),
        right: CGRect(x: 700, y: 860, width: 740, height: 40)
    )
    let tooSmall = snapshot(
        id: "noise",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        topInset: 40,
        left: CGRect(x: 0, y: 860, width: 719, height: 40),
        right: CGRect(x: 720, y: 860, width: 720, height: 40),
        scale: 2
    )

    #expect(NotchGeometry.derive(from: overlapping) == nil)
    #expect(NotchGeometry.derive(from: tooSmall) == nil)
}

@Test("supports nonzero screen origins")
func supportsNonzeroScreenOrigins() {
    let snapshot = snapshot(
        id: "secondary",
        frame: CGRect(x: -1440, y: 120, width: 1440, height: 900),
        topInset: 36,
        left: CGRect(x: -1440, y: 984, width: 600, height: 36),
        right: CGRect(x: -760, y: 984, width: 760, height: 36)
    )

    let geometry = NotchGeometry.derive(from: snapshot)

    #expect(geometry?.notchRect == CGRect(x: -840, y: 984, width: 80, height: 36))
    #expect(geometry?.topCenterAnchor == CGPoint(x: -800, y: 1020))
}

@Test("selects the notched screen among external screens")
func selectsNotchedScreenAmongExternalScreens() {
    let external = snapshot(
        id: "external",
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        topInset: 0,
        left: CGRect(x: 0, y: 1416, width: 1200, height: 24),
        right: CGRect(x: 1360, y: 1416, width: 1200, height: 24)
    )
    let builtIn = snapshot(
        id: "built-in",
        frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
        topInset: 40,
        left: CGRect(x: -1440, y: 860, width: 620, height: 40),
        right: CGRect(x: -620, y: 860, width: 620, height: 40)
    )

    #expect(NotchGeometry.select(from: [external, builtIn])?.screenIdentifier == "built-in")
    #expect(NotchGeometry.select(from: [builtIn, external])?.screenIdentifier == "built-in")
}

private func snapshot(
    id: String,
    frame: CGRect,
    topInset: CGFloat,
    left: CGRect?,
    right: CGRect?,
    scale: CGFloat = 1
) -> NotchScreenSnapshot {
    NotchScreenSnapshot(
        identifier: id,
        frame: frame,
        safeAreaTopInset: topInset,
        auxiliaryTopLeftArea: left,
        auxiliaryTopRightArea: right,
        backingScaleFactor: scale
    )
}
