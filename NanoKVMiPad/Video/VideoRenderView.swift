@preconcurrency import CoreMedia
import NanoKVMCore
import SwiftUI

struct VideoRenderView: UIViewRepresentable {
    let sampleBuffer: CMSampleBuffer?
    let flushToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SampleBufferDisplayUIView {
        SampleBufferDisplayUIView()
    }

    func updateUIView(_ uiView: SampleBufferDisplayUIView, context: Context) {
        context.coordinator.render.update(
            sampleBuffer: sampleBuffer,
            flushToken: flushToken,
            display: uiView.display
        )
    }

    final class Coordinator {
        let render = SampleBufferRenderCoordinator()
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
