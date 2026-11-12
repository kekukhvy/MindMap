import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "#RRGGBB" helpers (pure parts are unit-tested).
enum HexColor {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double
    }

    static func parse(_ hex: String) -> RGB? {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        return RGB(red: Double((value >> 16) & 0xFF) / 255,
                   green: Double((value >> 8) & 0xFF) / 255,
                   blue: Double(value & 0xFF) / 255)
    }

    static func string(_ rgb: RGB) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.red), byte(rgb.green), byte(rgb.blue))
    }

    /// WCAG relative luminance (0 = black, 1 = white).
    static func luminance(_ rgb: RGB) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// True if dark text reads better than white on this background
    /// (pastel and mid-tone fills get dark text, like XMind).
    static func prefersDarkText(on hex: String) -> Bool {
        guard let rgb = parse(hex) else { return false }
        return luminance(rgb) > 0.3
    }

    /// `amount` of the color over white (0 = white, 1 = the color).
    static func tint(_ hex: String, amount: Double) -> String {
        guard let rgb = parse(hex) else { return hex }
        func mix(_ c: Double) -> Double { 1 - (1 - c) * amount }
        return string(RGB(red: mix(rgb.red), green: mix(rgb.green), blue: mix(rgb.blue)))
    }

    /// Dark shade of the same hue (text on pale tints / plain subtopics),
    /// e.g. orange #F2A16D -> dark brown.
    static func darkShade(_ hex: String, lightness: Double = 0.21) -> String {
        guard let rgb = parse(hex) else { return hex }
        let maxC = max(rgb.red, rgb.green, rgb.blue), minC = min(rgb.red, rgb.green, rgb.blue)
        let l = (maxC + minC) / 2, delta = maxC - minC
        guard delta > 0.0001 else { return string(RGB(red: lightness, green: lightness, blue: lightness)) }
        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        if maxC == rgb.red {
            h = ((rgb.green - rgb.blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == rgb.green {
            h = (rgb.blue - rgb.red) / delta + 2
        } else {
            h = (rgb.red - rgb.green) / delta + 4
        }
        h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        return string(hsl(h, min(s, 1) * 0.75, lightness))
    }

    private static func hsl(_ h: Double, _ s: Double, _ l: Double) -> RGB {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGB(red: r + m, green: g + m, blue: b + m)
    }

    /// sRGB hex of a SwiftUI color (nil if not convertible).
    static func string(from color: Color) -> String? {
        #if os(macOS)
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return string(RGB(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent))
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return string(RGB(red: red, green: green, blue: blue))
        #endif
    }
}

extension Color {
    init(hex: String, fallback: Color = .gray) {
        if let rgb = HexColor.parse(hex) {
            self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
        } else {
            self = fallback
        }
    }

    /// XMind-like pure white paper in light and dark mode (the canvas is
    /// forced to the light color scheme; topic colors assume white).
    static var canvasBackground: Color { .white }
}

/// Named colors offered in menus.
enum ColorPresets {
    static let all: [(name: String, hex: String)] = [
        ("Red", "#E8524A"), ("Orange", "#F59B2B"), ("Yellow", "#F2C94C"), ("Green", "#4CB97A"),
        ("Blue", "#3D8FE0"), ("Purple", "#8E62D9"), ("Pink", "#E0629B"), ("Gray", "#8E8E93"),
        ("Graphite", ColorTheme.rootColorHex),
    ]
}
