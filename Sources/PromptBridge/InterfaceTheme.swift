import AppKit
import SwiftUI

enum InterfaceTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 184 / 255, green: 165 / 255, blue: 245 / 255, alpha: 1)
            : NSColor(srgbRed: 98 / 255, green: 80 / 255, blue: 168 / 255, alpha: 1)
    })
    static let onAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 35 / 255, green: 28 / 255, blue: 52 / 255, alpha: 1) : .white
    })
    static let panelPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let groupSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 8
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).frame(minHeight: 34)
            .foregroundStyle(isEnabled ? InterfaceTheme.onAccent : Color.secondary)
            .background(isEnabled ? InterfaceTheme.accent.opacity(configuration.isPressed ? 0.8 : 1)
                        : Color(nsColor: .quaternaryLabelColor),
                        in: RoundedRectangle(cornerRadius: InterfaceTheme.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: InterfaceTheme.cornerRadius))
    }
}
