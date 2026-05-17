import NanoKVMCore
import SwiftUI

struct VideoRenderView: UIViewRepresentable {
    let renderCoordinator: SampleBufferRenderCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(renderCoordinator: renderCoordinator)
    }

    func makeUIView(context: Context) -> SampleBufferDisplayUIView {
        let view = SampleBufferDisplayUIView()
        context.coordinator.renderCoordinator.attach(display: view.display)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayUIView, context: Context) {
        context.coordinator.renderCoordinator.attach(display: uiView.display)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(display.layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        display.layer.frame = bounds
    }
}
