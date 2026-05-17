import XCTest
@testable import NanoKVMCore

@MainActor
final class ViewerZoomStateTests: XCTestCase {
    func test_initialStateIsUnzoomedCentered() {
        let zoom = ViewerZoomState()
        XCTAssertEqual(zoom.scale, 1.0)
        XCTAssertEqual(zoom.center, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(zoom.visibleRect(), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertFalse(zoom.isZoomed)
    }

    func test_scaleIsClampedToRange() {
        let zoom = ViewerZoomState()
        zoom.setScale(0.1)
        XCTAssertEqual(zoom.scale, 1.0)
        zoom.setScale(100)
        XCTAssertEqual(zoom.scale, ViewerZoomState.maxScale)
    }

    func test_pinchKeepsAnchorStationary() {
        let zoom = ViewerZoomState()
        // Anchor at the viewport-center video point — center should stay put across scale changes.
        zoom.applyPinch(factor: 2.0, anchorNormalized: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(zoom.scale, 2.0, accuracy: 1e-6)
        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 1e-6)

        // Anchor at video-normalized (0.25, 0.25). Before pinch, that point sits at viewport (0.25, 0.25).
        // After pinching to scale 2 it must stay at viewport (0.25, 0.25); applying the inverse
        // mapping gives center = anchor + (0.5 - viewportPos) / scale = (0.5, 0.5).
        // …but starting from scale 2 / center (0.5, 0.5) and anchoring at video-normalized (0.25, 0.25):
        // the anchor before this second pinch is at viewport (0.25 - 0.5) * 2 + 0.5 = 0.0.
        // After scaling to 4 at that anchor, anchor must stay at viewport 0.0, so
        // center = anchor + (0.5 - 0) / new_scale = 0.25 + 0.125 = 0.375.
        zoom.applyPinch(factor: 2.0, anchorNormalized: CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(zoom.scale, 4.0, accuracy: 1e-6)
        XCTAssertEqual(zoom.center.x, 0.375, accuracy: 1e-6)
        XCTAssertEqual(zoom.center.y, 0.375, accuracy: 1e-6)
    }

    func test_pinchPanKeepsAnchorUnderMovingCentroid() {
        let zoom = ViewerZoomState()
        let container = CGRect(x: 0, y: 0, width: 400, height: 300)
        let base = CGRect(x: 20, y: 15, width: 360, height: 270)
        let initialCentroid = CGPoint(x: 100, y: 100)
        // Anchor is the video point currently under the centroid (pre-pinch state: scale 1, center 0.5).
        let anchor = CGPoint(
            x: zoom.center.x + (initialCentroid.x - container.midX) / (base.width * zoom.scale),
            y: zoom.center.y + (initialCentroid.y - container.midY) / (base.height * zoom.scale)
        )

        // Step 1: spread to factor 1.5, fingers stay at the same centroid → pure zoom around grip.
        zoom.applyPinchPan(factor: 1.5, anchorVideo: anchor, centroidInContainer: initialCentroid,
                           containerBounds: container, baseRect: base)
        XCTAssertEqual(zoom.scale, 1.5, accuracy: 1e-6)
        var mappedX = container.midX + (anchor.x - zoom.center.x) * base.width * zoom.scale
        var mappedY = container.midY + (anchor.y - zoom.center.y) * base.height * zoom.scale
        XCTAssertEqual(mappedX, initialCentroid.x, accuracy: 1e-6)
        XCTAssertEqual(mappedY, initialCentroid.y, accuracy: 1e-6)

        // Step 2: further spread (net scale 2.5) and translate the centroid; the same anchor must
        // still be displayed under the new centroid in container coords.
        let newCentroid = CGPoint(x: 150, y: 130)
        zoom.applyPinchPan(factor: 5.0 / 3.0, anchorVideo: anchor, centroidInContainer: newCentroid,
                           containerBounds: container, baseRect: base)
        XCTAssertEqual(zoom.scale, 2.5, accuracy: 1e-6)
        mappedX = container.midX + (anchor.x - zoom.center.x) * base.width * zoom.scale
        mappedY = container.midY + (anchor.y - zoom.center.y) * base.height * zoom.scale
        XCTAssertEqual(mappedX, newCentroid.x, accuracy: 1e-6)
        XCTAssertEqual(mappedY, newCentroid.y, accuracy: 1e-6)
    }

    func test_pinchPanWithoutScaleChangeIsPurePan() {
        let zoom = ViewerZoomState()
        let container = CGRect(x: 0, y: 0, width: 200, height: 100)
        let base = CGRect(x: 0, y: 0, width: 200, height: 100)
        zoom.setScale(2.0)
        let anchor = CGPoint(x: 0.6, y: 0.5)
        // Apply factor=1 (no zoom), centroid offset from container center → center slides accordingly.
        zoom.applyPinchPan(factor: 1.0, anchorVideo: anchor, centroidInContainer: CGPoint(x: 120, y: 50),
                           containerBounds: container, baseRect: base)
        XCTAssertEqual(zoom.scale, 2.0, accuracy: 1e-6)
        // center.x = 0.6 - (120 - 100) / (200 * 2) = 0.6 - 0.05 = 0.55
        XCTAssertEqual(zoom.center.x, 0.55, accuracy: 1e-6)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 1e-6)
    }

    func test_pinchKeepsAnchorAtSameViewportPosition() {
        let zoom = ViewerZoomState()
        let anchor = CGPoint(x: 0.7, y: 0.3)
        let viewportBefore = viewportPosition(of: anchor, scale: zoom.scale, center: zoom.center)
        zoom.applyPinch(factor: 1.6, anchorNormalized: anchor)
        let viewportAfter = viewportPosition(of: anchor, scale: zoom.scale, center: zoom.center)
        XCTAssertEqual(viewportAfter.x, viewportBefore.x, accuracy: 1e-6)
        XCTAssertEqual(viewportAfter.y, viewportBefore.y, accuracy: 1e-6)
    }

    private func viewportPosition(of point: CGPoint, scale: CGFloat, center: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - center.x) * scale + 0.5, y: (point.y - center.y) * scale + 0.5)
    }

    func test_centerIsClampedSoVisibleRectStaysInsideUnitSquare() {
        let zoom = ViewerZoomState()
        zoom.setScale(2.0)
        // Try to push the center off the top-left corner.
        zoom.applyPan(deltaNormalized: CGSize(width: -1.0, height: -1.0))
        XCTAssertEqual(zoom.center.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(zoom.center.y, 0.25, accuracy: 1e-6)
        let visible = zoom.visibleRect()
        XCTAssertEqual(visible.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(visible.minY, 0, accuracy: 1e-6)
    }

    func test_panIsIgnoredAtUnitScale() {
        let zoom = ViewerZoomState()
        zoom.applyPan(deltaNormalized: CGSize(width: 0.3, height: -0.4))
        XCTAssertEqual(zoom.center, CGPoint(x: 0.5, y: 0.5))
    }

    func test_resetReturnsToCenteredUnit() {
        let zoom = ViewerZoomState()
        zoom.applyPinch(factor: 3.0, anchorNormalized: CGPoint(x: 0.2, y: 0.8))
        zoom.reset()
        XCTAssertEqual(zoom.scale, 1.0)
        XCTAssertEqual(zoom.center, CGPoint(x: 0.5, y: 0.5))
    }

    func test_ensureCursorVisibleDoesNothingInsideInnerBand() {
        let zoom = ViewerZoomState()
        zoom.setScale(2.0)
        // Visible rect is [0.25, 0.75]; with margin 0.1 the inner band is [0.3, 0.7].
        // A cursor at (0.5, 0.5) is inside the inner band: center stays put.
        zoom.ensureCursorVisible(cursorNormalized: CGPoint(x: 0.5, y: 0.5), margin: 0.1)
        XCTAssertEqual(zoom.center, CGPoint(x: 0.5, y: 0.5))
    }

    func test_ensureCursorVisiblePansProportionallyToOvershoot() {
        let zoom = ViewerZoomState()
        zoom.setScale(2.0)
        // Cursor at (0.72, 0.5): the x overshoot past the inner-band upper edge (0.7) is 0.02.
        // With gain 0.5 the center moves by overshoot * gain = 0.01.
        zoom.ensureCursorVisible(cursorNormalized: CGPoint(x: 0.72, y: 0.5), margin: 0.1, gain: 0.5)
        XCTAssertEqual(zoom.center.x, 0.51, accuracy: 1e-6)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 1e-6)
    }

    func test_ensureCursorVisibleConvergesAcrossMultipleCalls() {
        let zoom = ViewerZoomState()
        zoom.setScale(2.0)
        // Hold the cursor at the right viewport edge (0.75) and pump events: center should walk
        // monotonically right and asymptotically settle near cursor - innerHalf.
        var previous = zoom.center.x
        for _ in 0..<200 {
            zoom.ensureCursorVisible(cursorNormalized: CGPoint(x: 0.75, y: 0.5), margin: 0.1, gain: 0.2)
            XCTAssertGreaterThanOrEqual(zoom.center.x, previous - 1e-9)
            previous = zoom.center.x
        }
        // innerHalf = (0.5 - 0.1) / 2 = 0.2 — so steady state is center.x = 0.75 - 0.2 = 0.55.
        XCTAssertEqual(zoom.center.x, 0.55, accuracy: 1e-4)
    }

    func test_ensureCursorVisibleClampsAtEdges() {
        let zoom = ViewerZoomState()
        zoom.setScale(2.0)
        // Repeatedly drive the cursor against the top-left; the clamp keeps center inside [0.25, 0.75].
        for _ in 0..<500 {
            zoom.ensureCursorVisible(cursorNormalized: CGPoint(x: 0.0, y: 0.0), margin: 0.0, gain: 0.5)
        }
        XCTAssertEqual(zoom.center.x, 0.25, accuracy: 1e-4)
        XCTAssertEqual(zoom.center.y, 0.25, accuracy: 1e-4)
    }

    func test_effectiveVideoRectAtUnitScaleMatchesBaseRect() {
        let zoom = ViewerZoomState()
        let container = CGRect(x: 0, y: 0, width: 200, height: 100)
        let base = CGRect(x: 12, y: 0, width: 176, height: 99)
        let effective = zoom.effectiveVideoRect(in: container, baseRect: base)
        XCTAssertEqual(effective.minX, 12, accuracy: 1e-6)
        XCTAssertEqual(effective.maxX, 188, accuracy: 1e-6)
        XCTAssertEqual(effective.width, 176, accuracy: 1e-6)
        XCTAssertEqual(effective.height, 99, accuracy: 1e-6)
    }

    func test_effectiveVideoRectScalesAroundContainerCenter() {
        let zoom = ViewerZoomState()
        let container = CGRect(x: 0, y: 0, width: 200, height: 100)
        let base = CGRect(x: 10, y: 5, width: 180, height: 90)
        zoom.setScale(2.0)
        let effective = zoom.effectiveVideoRect(in: container, baseRect: base)
        XCTAssertEqual(effective.width, 360, accuracy: 1e-6)
        XCTAssertEqual(effective.height, 180, accuracy: 1e-6)
        XCTAssertEqual(effective.midX, container.midX, accuracy: 1e-6)
        XCTAssertEqual(effective.midY, container.midY, accuracy: 1e-6)
    }

    func test_transformPlacesPannedCenterUnderContainerMid() {
        let zoom = ViewerZoomState()
        let container = CGRect(x: 0, y: 0, width: 200, height: 100)
        let base = CGRect(x: 10, y: 5, width: 180, height: 90)
        zoom.setScale(2.0)
        zoom.applyPan(deltaNormalized: CGSize(width: 0.1, height: 0.0))
        let effective = zoom.effectiveVideoRect(in: container, baseRect: base)
        // The normalized point (0.6, 0.5) should sit at the container center after panning.
        let pointX = effective.minX + 0.6 * effective.width
        XCTAssertEqual(pointX, container.midX, accuracy: 1e-6)
    }
}
