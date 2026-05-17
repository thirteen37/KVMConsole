@preconcurrency import AVFoundation
import NanoKVMCore
import SwiftUI

struct VideoRenderView: NSViewRepresentable {
    let renderCoordinator: SampleBufferRenderCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(renderCoordinator: renderCoordinator)
    }

    func makeNSView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        context.coordinator.renderCoordinator.attach(display: view.display)
        return view
    }

    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        context.coordinator.renderCoordinator.attach(display: nsView.display)
    }

    static func dismantleNSView(_ nsView: SampleBufferDisplayView, coordinator: Coordinator) {
        coordinator.renderCoordinator.detach(display: nsView.display)
    }

    final class Coordinator {
        let renderCoordinator: SampleBufferRenderCoordinator

        init(renderCoordinator: SampleBufferRenderCoordinator) {
            self.renderCoordinator = renderCoordinator
        }
    }
}

final class SampleBufferDisplayView: NSView {
    let display = SampleBufferDisplay()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = display.layer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}
