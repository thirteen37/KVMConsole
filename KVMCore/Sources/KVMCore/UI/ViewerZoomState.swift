import CoreGraphics
import Foundation

@MainActor
public final class ViewerZoomState: ObservableObject {
    public static let minScale: CGFloat = 1.0
    public static let maxScale: CGFloat = 8.0
    public static let defaultCursorMargin: CGFloat = 0.15
    public static let defaultCursorPanGain: CGFloat = 0.12

    @Published public private(set) var scale: CGFloat = 1.0
    @Published public private(set) var center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published public var videoSize: CGSize?
    @Published public var cursorNormalized: CGPoint?

    public init() {}

    public var isZoomed: Bool { scale > 1.0 + .ulpOfOne }

    public func reset() {
        scale = 1.0
        center = CGPoint(x: 0.5, y: 0.5)
    }

    public func setScale(_ newScale: CGFloat) {
        let target = Self.clampScale(newScale)
        guard target != scale else { return }
        scale = target
        clampCenter()
    }

    public func applyPinch(factor: CGFloat, anchorNormalized: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let oldScale = scale
        let newScale = Self.clampScale(scale * factor)
        guard newScale != oldScale else { return }
        scale = newScale
        recenter(forAnchor: anchorNormalized, oldScale: oldScale, newScale: newScale)
        clampCenter()
    }

    /// Combined zoom + pan: applies `factor` to the scale and slides `center` so that the
    /// video-normalized point `anchorVideo` is displayed at `centroidInContainer`. Use this when
    /// driving zoom from a gesture whose centroid can also translate (e.g. a two-finger pinch on
    /// iPad), keeping `anchorVideo` constant across the gesture so the "grabbed" video point
    /// follows the fingers.
    public func applyPinchPan(
        factor: CGFloat,
        anchorVideo: CGPoint,
        centroidInContainer: CGPoint,
        containerBounds: CGRect,
        baseRect: CGRect
    ) {
        guard factor.isFinite, factor > 0 else { return }
        guard baseRect.width > 0, baseRect.height > 0 else { return }
        scale = Self.clampScale(scale * factor)
        center = CGPoint(
            x: anchorVideo.x - (centroidInContainer.x - containerBounds.midX) / (baseRect.width * scale),
            y: anchorVideo.y - (centroidInContainer.y - containerBounds.midY) / (baseRect.height * scale)
        )
        clampCenter()
    }

    public func applyPan(deltaNormalized: CGSize) {
        guard isZoomed else { return }
        center = CGPoint(
            x: center.x + deltaNormalized.width,
            y: center.y + deltaNormalized.height
        )
        clampCenter()
    }

    public func ensureCursorVisible(
        cursorNormalized: CGPoint,
        margin: CGFloat = ViewerZoomState.defaultCursorMargin,
        gain: CGFloat = ViewerZoomState.defaultCursorPanGain
    ) {
        guard isZoomed else { return }
        let innerHalf = max(0, (0.5 - margin)) / scale
        let dx = overshoot(cursor: cursorNormalized.x, center: center.x, innerHalf: innerHalf) * gain
        let dy = overshoot(cursor: cursorNormalized.y, center: center.y, innerHalf: innerHalf) * gain
        guard dx != 0 || dy != 0 else { return }
        center = CGPoint(x: center.x + dx, y: center.y + dy)
        clampCenter()
    }

    private func overshoot(cursor: CGFloat, center: CGFloat, innerHalf: CGFloat) -> CGFloat {
        let lower = center - innerHalf
        let upper = center + innerHalf
        if cursor < lower {
            return cursor - lower
        } else if cursor > upper {
            return cursor - upper
        }
        return 0
    }

    public func visibleRect() -> CGRect {
        let span = 1.0 / scale
        return CGRect(
            x: center.x - span / 2,
            y: center.y - span / 2,
            width: span,
            height: span
        )
    }

    public func effectiveVideoRect(in containerBounds: CGRect, baseRect: CGRect) -> CGRect {
        let width = baseRect.width * scale
        let height = baseRect.height * scale
        let tx = -(center.x - 0.5) * baseRect.width * scale
        let ty = -(center.y - 0.5) * baseRect.height * scale
        return CGRect(
            x: containerBounds.midX - width / 2 + tx,
            y: containerBounds.midY - height / 2 + ty,
            width: width,
            height: height
        )
    }

    private func recenter(forAnchor anchor: CGPoint, oldScale: CGFloat, newScale: CGFloat) {
        let ratio = oldScale / newScale
        center = CGPoint(
            x: anchor.x - (anchor.x - center.x) * ratio,
            y: anchor.y - (anchor.y - center.y) * ratio
        )
    }

    private func clampCenter() {
        if !isZoomed {
            center = CGPoint(x: 0.5, y: 0.5)
            return
        }
        let halfSpan = 0.5 / scale
        let minC = halfSpan
        let maxC = 1 - halfSpan
        center = CGPoint(
            x: min(max(center.x, minC), maxC),
            y: min(max(center.y, minC), maxC)
        )
    }

    private static func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minScale), maxScale)
    }
}
