import SwiftUI

public struct KVMTypeIcon: View {
    private let type: Device.KVMType
    private let explicitSize: CGFloat?

    // Tracks the body text size so the icon stays at text height across Dynamic Type / platforms.
    @ScaledMetric(relativeTo: .body) private var textHeightSize: CGFloat = 16

    public init(_ type: Device.KVMType, size: CGFloat? = nil) {
        self.type = type
        self.explicitSize = size
    }

    public var body: some View {
        let side = explicitSize ?? textHeightSize
        image
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .foregroundStyle(.tint)
    }

    private var image: Image {
        switch type.iconSource {
        case .systemSymbol(let name):
            return Image(systemName: name)
        case .bundledAsset(let name):
            return Image(name, bundle: .module).renderingMode(.template)
        }
    }
}
