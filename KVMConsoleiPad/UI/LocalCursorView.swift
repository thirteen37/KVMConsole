import KVMCore
import SwiftUI

struct LocalCursorView: View {
    let isVisible: Bool
    let videoSize: CGSize?
    @ObservedObject var zoom: ViewerZoomState

    private let cursorSize = CGSize(width: 18, height: 24)

    var body: some View {
        GeometryReader { proxy in
            if isVisible, let cursor = zoom.cursorNormalized {
                let point = cursorPoint(cursor, in: proxy.size)
                ZStack(alignment: .topLeading) {
                    CursorArrowShape()
                        .stroke(Color.black.opacity(0.85), lineWidth: 3)
                    CursorArrowShape()
                        .fill(Color.white)
                    CursorArrowShape()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                }
                .frame(width: cursorSize.width, height: cursorSize.height)
                .offset(x: point.x, y: point.y)
                .shadow(color: Color.black.opacity(0.45), radius: 1, x: 0, y: 1)
            }
        }
    }

    private func cursorPoint(_ cursor: CGPoint, in size: CGSize) -> CGPoint {
        let bounds = CGRect(origin: .zero, size: size)
        let baseRect = MouseCoordinateMapper.aspectFitRect(for: videoSize, in: bounds)
        let effectiveRect = zoom.effectiveVideoRect(in: bounds, baseRect: baseRect)
        return CGPoint(
            x: effectiveRect.minX + cursor.x * effectiveRect.width,
            y: effectiveRect.minY + cursor.y * effectiveRect.height
        )
    }
}

private struct CursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.78))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.31, y: rect.maxY * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.48, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.68, y: rect.maxY * 0.91))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.51, y: rect.maxY * 0.52))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.52))
        path.closeSubpath()
        return path
    }
}
