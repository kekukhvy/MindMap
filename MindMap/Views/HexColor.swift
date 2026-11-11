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

    /// True if dark text reads better than white on this background.
    static func prefersDarkText(on hex: String) -> Bool {
        guard let rgb = parse(hex) else { return false }
        return luminance(rgb) > 0.5
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

    static var canvasBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// Named colors offered in menus.
enum ColorPresets {
    static let all: [(name: String, hex: String)] = [
        ("Red", "#E8524A"), ("Orange", "#F59B2B"), ("Yellow", "#F2C94C"), ("Green", "#4CB97A"),
        ("Blue", "#3D8FE0"), ("Purple", "#8E62D9"), ("Pink", "#E0629B"), ("Gray", "#8E8E93"),
        ("Graphite", ColorTheme.rootColorHex),
    ]
}
