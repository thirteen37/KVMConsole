import NanoKVMCore
import SwiftUI

struct ModifierKeyState: Equatable {
    private(set) var momentaryBits: UInt8 = 0
    private(set) var lockedBits: UInt8 = 0

    var activeModifierByte: UInt8 {
        momentaryBits | lockedBits
    }

    mutating func toggleMomentary(_ bit: UInt8) {
        if momentaryBits & bit == bit {
            momentaryBits &= ~bit
        } else {
            momentaryBits |= bit
        }
    }

    mutating func toggleLocked(_ bit: UInt8) {
        if lockedBits & bit == bit {
            lockedBits &= ~bit
        } else {
            lockedBits |= bit
            momentaryBits &= ~bit
        }
    }

    mutating func consumeMomentary() {
        momentaryBits = 0
    }
}

struct ModifierKeyBar: View {
    @Binding var state: ModifierKeyState
    let onAction: (UInt8, UInt8) -> Void

    private let keys: [(title: String, bit: UInt8)] = [
        ("Ctrl", HIDModifierBit.leftControl.rawValue),
        ("Alt", HIDModifierBit.leftAlt.rawValue),
        ("Cmd", HIDModifierBit.leftGUI.rawValue),
        ("Shift", HIDModifierBit.leftShift.rawValue),
        ("Win", HIDModifierBit.rightGUI.rawValue)
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(keys, id: \.title) { key in
                ModifierButton(title: key.title, bit: key.bit, state: $state)
            }
            actionButton("Esc", usage: 0x29)
            actionButton("Tab", usage: 0x2B)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionButton(_ title: String, usage: UInt8) -> some View {
        Button(title) {
            onAction(usage, state.activeModifierByte)
            state.consumeMomentary()
        }
        .buttonStyle(.bordered)
    }
}

private struct ModifierButton: View {
    let title: String
    let bit: UInt8
    @Binding var state: ModifierKeyState
    // Long-press fires while the finger is still down; the Button's tap fires on release.
    // Suppress that trailing tap so a long-press only toggles the lock, not the momentary bit.
    @State private var suppressNextTap = false

    var body: some View {
        let isActive = state.activeModifierByte & bit == bit
        let isLocked = state.lockedBits & bit == bit
        Button {
            if suppressNextTap {
                suppressNextTap = false
            } else {
                state.toggleMomentary(bit)
            }
        } label: {
            Text(isLocked ? "\(title) lock" : title)
                .font(.callout.weight(.semibold))
                .frame(minWidth: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? .accentColor : .secondary)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            state.toggleLocked(bit)
            suppressNextTap = true
        })
    }
}
