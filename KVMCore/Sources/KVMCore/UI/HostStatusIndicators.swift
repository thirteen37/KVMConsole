import SwiftUI

public struct HostStatusIndicators: View {
    private let status: KVMHostStatus?
    private let isActive: Bool

    public init(status: KVMHostStatus?, isActive: Bool) {
        self.status = status
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: 12) {
            indicator(symbol: powerSymbol, text: "Power", style: powerStyle, tooltip: powerTooltip)
            indicator(symbol: hdmiSymbol, text: "HDMI", style: hdmiStyle, tooltip: hdmiTooltip)
        }
        .font(.callout)
    }

    private func indicator(
        symbol: String,
        text: String,
        style: AnyShapeStyle,
        tooltip: String
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(style)
            Text(text)
        }
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var powerSymbol: String {
        switch status?.atxPower {
        case .on: return "power.circle.fill"
        case .off: return "power.circle"
        case nil: return "power"
        }
    }

    private var powerStyle: AnyShapeStyle {
        guard isActive else { return AnyShapeStyle(HierarchicalShapeStyle.tertiary) }
        switch status?.atxPower {
        case .on: return AnyShapeStyle(Color.green)
        case .off: return AnyShapeStyle(HierarchicalShapeStyle.secondary)
        case nil: return AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        }
    }

    private var powerTooltip: String {
        switch status?.atxPower {
        case .on: return "Host power: On"
        case .off: return "Host power: Off"
        case nil: return "Host power: Unknown"
        }
    }

    private var hdmiSymbol: String {
        switch status?.hdmiSignal {
        case .some(true): return "display"
        case .some(false): return "display.trianglebadge.exclamationmark"
        case .none: return "display"
        }
    }

    private var hdmiStyle: AnyShapeStyle {
        guard isActive else { return AnyShapeStyle(HierarchicalShapeStyle.tertiary) }
        switch status?.hdmiSignal {
        case .some(true): return AnyShapeStyle(Color.green)
        case .some(false): return AnyShapeStyle(HierarchicalShapeStyle.secondary)
        case .none: return AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        }
    }

    private var hdmiTooltip: String {
        switch status?.hdmiSignal {
        case .some(true): return "HDMI: Signal detected"
        case .some(false): return "HDMI: No signal"
        case .none: return "HDMI: Unknown"
        }
    }
}
