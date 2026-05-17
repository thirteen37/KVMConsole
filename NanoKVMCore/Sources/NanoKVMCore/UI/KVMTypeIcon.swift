import SwiftUI

public struct KVMTypeIcon: View {
    private let type: Device.KVMType
    private let size: CGFloat

    public init(_ type: Device.KVMType, size: CGFloat) {
        self.type = type
        self.size = size
    }

    public var body: some View {
        image
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
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
