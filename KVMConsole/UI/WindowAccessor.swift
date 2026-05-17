import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Accessor {
        let view = Accessor()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: Accessor, context: Context) {
        nsView.onWindowChange = onWindowChange
    }

    final class Accessor: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
