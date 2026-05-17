import SwiftUI

public struct KVMTypeIcon: View {
    private let type: Device.KVMType
    private let size: CGFloat

    public init(_ type: Device.KVMType, size: CGFloat) {
        self.type = type
        self.size = size
    }

    public var body: some View {
        switch type.iconSource {
        case .systemSymbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.tint)
        case .bundledAsset(let name):
            Image(name, bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
