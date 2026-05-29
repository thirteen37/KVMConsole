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
            .overlay(alignment: .bottomTrailing) {
                if let badge = type.iconBadgeSymbol {
                    let badgeSide = side * 0.55
                    // Glyph and disc use .background / .tint so they invert together with
                    // the row's selection highlight — both colors are guaranteed to
                    // contrast in either state (e.g. tinted-disc/white-glyph normally,
                    // white-disc/blue-glyph when selected). A thin .background ring keeps
                    // the disc from merging into the same-tint icon behind it.
                    Image(systemName: badge)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.background)
                        .padding(badgeSide * 0.24)
                        .frame(width: badgeSide, height: badgeSide)
                        .background(Circle().fill(.tint))
                        .overlay(Circle().strokeBorder(.background, lineWidth: max(0.5, badgeSide * 0.08)))
                        .offset(x: badgeSide * 0.28, y: badgeSide * 0.28)
                }
            }
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
