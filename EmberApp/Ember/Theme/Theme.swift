import SwiftUI

/// Mirrors the web app's `:root` custom properties exactly (see web/index.html)
/// so the native app reads as the same product, not a reskin. Colors are
/// defined via `UIColor(dynamicProvider:)` so each one picks the correct
/// light/dark value automatically, the same split the CSS's
/// `@media (prefers-color-scheme: dark)` block draws.
enum Theme {
    static let bg = Color(
        light: Color(hex: 0xF5_F5F7),
        dark: Color(hex: 0x00_0000)
    )
    static let panel = Color(
        light: Color(hex: 0xFF_FFFF),
        dark: Color(hex: 0x1C_1C1E)
    )
    static let header = Color(
        light: Color(hex: 0x1C_1C1E),
        dark: Color(hex: 0x00_0000)
    )
    static let accent = Color(
        light: Color(hex: 0x58_56D6),
        // Brighter than Apple's raw systemIndigo dark value (#5e5ce6) so
        // it stays legible as small text too, not just as a fill -- see
        // the matching note in web/index.html's dark-mode :root block.
        dark: Color(hex: 0x85_83EA)
    )
    static let accentSoft = Color(
        light: Color(hex: 0xE8_E7FB),
        dark: Color(hex: 0x2A_2A5C)
    )
    static let text = Color(
        light: Color(hex: 0x1C_1C1E),
        dark: Color(hex: 0xF2_F2F7)
    )
    static let muted = Color(
        light: Color(hex: 0x6E_6E73),
        dark: Color(hex: 0x8E_8E93)
    )
    static let border = Color(
        light: Color(hex: 0xE5_E5EA),
        dark: Color(hex: 0x38_383A)
    )
    static let danger = Color(hex: 0xD7_0015)

    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0x58_56D6), Color(hex: 0x7A_78E0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Same 8-hue Apple-system-color set as `avatarColor()` in web/index.html,
    /// hashed by username so a given name always lands on the same color.
    static let avatarPalette: [Color] = [
        Color(hex: 0x00_7AFF), // blue
        Color(hex: 0xAF_52DE), // purple
        Color(hex: 0xFF_2D55), // pink
        Color(hex: 0x0E_8A9E), // teal
        Color(hex: 0x24_8A3D), // green
        Color(hex: 0xC7_6A00), // orange
        Color(hex: 0xFF_3B30), // red
        Color(hex: 0x5E_5CE6), // indigo
    ]

    static func avatarColor(for name: String) -> Color {
        var hash: UInt32 = 0
        for byte in name.utf8 {
            hash = hash &* 31 &+ UInt32(byte)
        }
        return avatarPalette[Int(hash % UInt32(avatarPalette.count))]
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// A color that resolves to `light` or `dark` depending on the active
    /// color scheme, the SwiftUI-native equivalent of this app's CSS
    /// `@media (prefers-color-scheme: dark)` overrides.
    init(light: Color, dark: Color) {
        self.init(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            }
        )
    }
}
