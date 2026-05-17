import NanoKVMCore
import SwiftUI

struct VideoRenderView: UIViewRepresentable {
    let renderCoordinator: SampleBufferRenderCoordinator
    let scale: CGFloat
    let center: CGPoint
    let videoSize: CGSize?

    func makeCoordinator() -> Coordinator {
        Coordinator(renderCoordinator: renderCoordinator)
    }

    func makeUIView(context: Context) -> SampleBufferDisplayUIView {
        let view = SampleBufferDisplayUIView()
        context.coordinator.renderCoordinator.attach(display: view.display)
        view.applyZoom(scale: scale, center: center, videoSize: videoSize)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayUIView, context: Context) {
        context.coordinator.renderCoordinator.attach(display: uiView.display)
        uiView.applyZoom(scale: scale, center: center, videoSize: videoSize)
    }

    static func dismantleUIView(_ uiView: SampleBufferDisplayUIView, coordinator: Coordinator) {
        coordinator.renderCoordinator.detach(display: uiView.display)
    }

    final class Coordinator {
        let renderCoordinator: SampleBufferRenderCoordinator

        init(renderCoordinator: SampleBufferRenderCoordinator) {
            self.renderCoordinator = renderCoordinator
        }
    }
}

final class SampleBufferDisplayUIView: UIView {
    let display = SampleBufferDisplay()
    private var currentScale: CGFloat = 1.0
    private var currentCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var currentVideoSize: CGSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(display.layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyZoom(scale: CGFloat, center: CGPoint, videoSize: CGSize?) {
        currentScale = scale
        currentCenter = center
        currentVideoSize = videoSize
        refreshTransform()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        display.layer.frame = bounds
        refreshTransform()
    }

    private func refreshTransform() {
        let baseRect = MouseCoordinateMapper.aspectFitRect(for: currentVideoSize, in: bounds)
        let tx = -(currentCenter.x - 0.5) * baseRect.width * currentScale
        let ty = -(currentCenter.y - 0.5) * baseRect.height * currentScale
        let transform = CGAffineTransform(scaleX: currentScale, y: currentScale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        display.setVideoTransform(transform)
    }
}
