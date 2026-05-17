import SwiftUI

public struct MinimapView: View {
    public static let maxSize: CGFloat = 200
    public static let minSize: CGFloat = 80

    @ObservedObject private var zoom: ViewerZoomState

    public init(zoom: ViewerZoomState) {
        self.zoom = zoom
    }

    public var body: some View {
        if zoom.isZoomed, let size = outerSize {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)

                viewportRect(in: size)
                cursorDot(in: size)
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }
    }

    private var outerSize: CGSize? {
        guard let videoSize = zoom.videoSize, videoSize.width > 0, videoSize.height > 0 else {
            return nil
        }
        let aspect = videoSize.width / videoSize.height
        let width: CGFloat
        let height: CGFloat
        if aspect >= 1 {
            width = Self.maxSize
            height = max(Self.minSize * 0.6, Self.maxSize / aspect)
        } else {
            height = Self.maxSize
            width = max(Self.minSize * 0.6, Self.maxSize * aspect)
        }
        return CGSize(width: width, height: height)
    }

    private func viewportRect(in size: CGSize) -> some View {
        let visible = zoom.visibleRect()
        let rect = CGRect(
            x: visible.minX * size.width,
            y: visible.minY * size.height,
            width: visible.width * size.width,
            height: visible.height * size.height
        )
        return Rectangle()
            .strokeBorder(Color.white, lineWidth: 1.5)
            .background(Color.white.opacity(0.12))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    @ViewBuilder
    private func cursorDot(in size: CGSize) -> some View {
        if let cursor = zoom.cursorNormalized {
            let diameter: CGFloat = 6
            Circle()
                .fill(Color.yellow)
                .frame(width: diameter, height: diameter)
                .offset(
                    x: cursor.x * size.width - diameter / 2,
                    y: cursor.y * size.height - diameter / 2
                )
        }
    }
}
