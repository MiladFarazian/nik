import SwiftUI
import UIKit

enum Theme {
    // Dark-only palette. Video is the brightest thing on screen.
    static let background = Color(hex: 0x000000)
    static let surface1 = Color(hex: 0x161616)
    static let surface2 = Color(hex: 0x242424)
    static let accent = Color(hex: 0x9B5CFF)        // single saturated accent, CTAs only
    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0x9B5CFF), Color(hex: 0xFF5C9B)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
    static let proBadge = Color(hex: 0xFFC94D)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: hexString.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(hex: UInt32(value))
    }
}

enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
