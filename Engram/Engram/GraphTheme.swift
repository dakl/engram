import SwiftUI
import AppKit

/// The graph view's palette. The **chrome** roles (canvas, surface, border,
/// edges) are system colors so the graph reads as native and matches the rest of
/// the app (ADR 0016 — custom palettes are deferred); only the **community data
/// palette** below stays a curated set, since those hues *encode data* (which
/// cluster a node belongs to) and want to stay distinct.
enum GraphTheme {
    /// Canvas backdrop — the system document surface (white by day, near-black by night).
    static let background = Color(nsColor: .textBackgroundColor)
    /// Slightly raised surface for tooltips, pills, and control chrome.
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// Hairline borders on cards and pills.
    static let border = Color(nsColor: .separatorColor)
    /// Cross-community edges (used at low opacity): a neutral hairline.
    static let edgeFaint = Color(nsColor: .tertiaryLabelColor)

    /// Curated warm community palette — harmonious earthy/sunset hues, each with a
    /// lighter dark-mode variant so it glows against the night background. Twelve
    /// entries keep colours distinct for stores with many sources/communities;
    /// beyond that they cycle (spatial separation + halo labels disambiguate).
    static let communityPalette: [Color] = [
        adaptive(light: 0xC75D43, dark: 0xE8896B), // terracotta
        adaptive(light: 0xD69A2D, dark: 0xF0C04A), // honey
        adaptive(light: 0x6E8B5B, dark: 0x9BBE82), // sage
        adaptive(light: 0x3E8E8A, dark: 0x6FC2BD), // teal
        adaptive(light: 0xC16B86, dark: 0xE093AB), // dusty rose
        adaptive(light: 0x7C5C9E, dark: 0xAE92CE), // plum
        adaptive(light: 0xB07A4A, dark: 0xD6A471), // clay
        adaptive(light: 0x5B7DA8, dark: 0x93B3DA), // slate blue
        adaptive(light: 0xA84C32, dark: 0xCF6E50), // rust
        adaptive(light: 0x8E7B2E, dark: 0xC0AB55), // olive gold
        adaptive(light: 0x995577, dark: 0xC07DA0), // mauve
        adaptive(light: 0x4E7E6E, dark: 0x7FB3A1), // pine
    ]

    /// Colour for nodes no community claims.
    static let fallback = adaptive(light: 0x8A8079, dark: 0xB0A79C)

    /// Community colour by palette index; `nil` yields the fallback.
    static func community(_ index: Int?) -> Color {
        guard let index, !communityPalette.isEmpty else { return fallback }
        return communityPalette[index % communityPalette.count]
    }

    /// Builds a colour that resolves to `light`/`dark` (sRGB hex) per the current
    /// appearance, so the same `Color` works in both modes without branching.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbHex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    /// Opaque sRGB colour from a `0xRRGGBB` literal.
    convenience init(srgbHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
