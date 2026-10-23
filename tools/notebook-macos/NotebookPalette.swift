import AppKit
import Observation
import SwiftUI

enum NotebookColorPreset: String, CaseIterable, Identifiable {
    case sputnik, espresso, seaGlass, syrah, charlock, lunar, oliveLeaf
    case persianPlum, tangerine, autumn, moss, blackberry, lavender, riverJade

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sputnik: return "Sputnik · Default"
        case .espresso: return "Espresso & Coral"
        case .seaGlass: return "Sea Glass"
        case .syrah: return "Syrah & Blue Glow"
        case .charlock: return "Charlock"
        case .lunar: return "Lunar Silver"
        case .oliveLeaf: return "Olive Leaf"
        case .persianPlum: return "Persian Plum"
        case .tangerine: return "Tangerine & Teal"
        case .autumn: return "Autumn Ember"
        case .moss: return "Moss & Ivory"
        case .blackberry: return "Blackberry & Honey"
        case .lavender: return "Lavender Haze"
        case .riverJade: return "River Jade"
        }
    }

    /// Reference swatches: dark ink, accent, light paper, optional accents.
    /// Previews retain the exact HEX values from the supplied palettes.
    var swatches: [UInt32] {
        switch self {
        case .sputnik: return [0x2a2a35, 0xb98391, 0xe2e2da]
        case .espresso: return [0x413333, 0xf2765e, 0xf5ebdd]
        case .seaGlass: return [0x303841, 0x76abae, 0xf5f5f5]
        case .syrah: return [0x6a282c, 0xb2d4dd, 0xe2eaeb]
        case .charlock: return [0x2e272a, 0xe5e790, 0xf3eee7]
        case .lunar: return [0x5b5875, 0xc7c9d8, 0xf2ebd3]
        case .oliveLeaf: return [0x31031f, 0x66693e, 0xfff8ed]
        case .persianPlum: return [0x130e0a, 0x701e1a, 0xe6dbc8, 0xaf312a, 0xd68c1a]
        case .tangerine: return [0x3fa7a3, 0xf28c28, 0xf5d7a1]
        case .autumn: return [0x2d4263, 0xc84b31, 0xecdbba]
        case .moss: return [0x41431b, 0xaeb784, 0xf3ebc8]
        case .blackberry: return [0x240a34, 0x891652, 0xffedd8, 0xeabe6c]
        case .lavender: return [0x17313e, 0xc5b0cd, 0xf3e2d4]
        case .riverJade: return [0x0b0909, 0x408175, 0xb5b9f0]
        }
    }
}

@Observable
private final class NotebookPaletteSelection {
    var preset: NotebookColorPreset = .sputnik
}

/// AppKit colors resolve the current preset at drawing time, including colors
/// already in text storage. SwiftUI observes selection and receives colors with
/// preset-specific identities. Neither path recreates editors or their Undo.
enum NotebookPalette {
    private static let selection = NotebookPaletteSelection()
    static var currentPreset: NotebookColorPreset { selection.preset }

    static func select(_ preset: NotebookColorPreset) {
        guard selection.preset != preset else { return }
        selection.preset = preset
        // A preset can change without a light/dark appearance change.
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            if let text = view as? NSTextView, let storage = text.textStorage {
                text.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
            }
            view.subviews.forEach(redraw)
        }
        for window in NSApp?.windows ?? [] {
            if let root = window.contentView { redraw(root) }
        }
    }

    static func native(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                green: Double((hex >> 8) & 255) / 255,
                blue: Double(hex & 255) / 255, alpha: 1)
    }

    // Preserve every existing Sputnik light/dark color exactly.
    private static let original: [String: (UInt32, UInt32)] = [
        "canvas": (0xe2e2da, 0x2a2a35), "sidebar": (0xdad1d2, 0x35313c),
        "surface": (0xedede6, 0x22222c), "editor": (0xf7f7f2, 0x22222c),
        "rule": (0xbdbbc0, 0x4b4855), "ink": (0x2a2a35, 0xe2e2da),
        "slate": (0x4d4b55, 0xd1cdd5), "muted": (0x64616a, 0xb9b6c2),
        "accent": (0x86505f, 0xd3a2b0), "selection": (0xb98391, 0xb98391),
        "error": (0x9a4556, 0xe6a0af), "success": (0x54594d, 0xcacbb5),
        "category.layout": (0x7e4054, 0xd6a0b2), "category.controls": (0x87512c, 0xe4b587),
        "category.annotations": (0x596044, 0xc3c9a0), "category.services": (0x75516d, 0xc9a8c0),
        "syntax.type": (0x4a5268, 0xbfc1d4), "syntax.number": (0x86523e, 0xd7b1a1),
        "syntax.string": (0x54594d, 0xcacbb5), "syntax.comment": (0x686570, 0xa6a1b0),
        "syntax.variable": (0x7d536b, 0xc4a4b3), "syntax.operator": (0x555460, 0xb9b6c2)
    ]

    private static let palettes: [NotebookColorPreset: [[String: UInt32]]] =
        Dictionary(uniqueKeysWithValues: NotebookColorPreset.allCases.map { preset in
            (preset, [makeColors(preset, dark: false), makeColors(preset, dark: true)])
        })

    private static func adaptive(_ name: String, preset: NotebookColorPreset? = nil) -> NSColor {
        NSColor(name: NSColor.Name("Sputnik.\(preset?.rawValue ?? "current").\(name)")) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return native(palettes[preset ?? selection.preset]![dark ? 1 : 0][name]!)
        }
    }

    private static func color(_ name: String) -> Color {
        Color(nsColor: adaptive(name, preset: selection.preset))
    }

    private static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { value, shift in
            let a = Double((a >> shift) & 255), b = Double((b >> shift) & 255)
            return value | (UInt32((a + (b - a) * amount).rounded()) << shift)
        }
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func linear(_ shift: Int) -> Double {
            let value = Double((hex >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }

    private static func readable(_ candidate: UInt32, on backgrounds: [UInt32], toward ink: UInt32) -> UInt32 {
        for step in 0...100 {
            let result = mix(candidate, ink, Double(step) / 100)
            let value = luminance(result)
            if backgrounds.allSatisfy({ background in
                let other = luminance(background)
                return (max(value, other) + 0.05) / (min(value, other) + 0.05) >= 4.5
            }) { return result }
        }
        return ink
    }

    private static func makeColors(_ preset: NotebookColorPreset, dark: Bool) -> [String: UInt32] {
        if preset == .sputnik { return original.mapValues { dark ? $0.1 : $0.0 } }
        let swatches = preset.swatches
        let night = preset == .tangerine ? mix(swatches[0], 0, 0.70) : swatches[0]
        let accent = swatches[1], paper = swatches[2]
        // Large surfaces use a restrained tint over neutral paper/graphite.
        // Reference colors guide the mood; accents carry their stronger hues.
        let ink = dark ? mix(0xe5e5e2, paper, 0.12) : mix(0x2c2d32, night, 0.12)
        let canvas = mix(dark ? 0x26272b : 0xebebe8, dark ? night : paper, 0.14)
        // Navigation needs a distinct lightness, even with a restrained tint.
        let sidebar = mix(mix(canvas, accent, 0.025), ink, 0.12)
        let surface = mix(canvas, 0xffffff, dark ? 0.025 : 0.28)
        let editor = dark ? mix(canvas, 0, 0.12) : mix(canvas, 0xffffff, 0.65)
        let backgrounds = [canvas, sidebar, surface, editor]
        func text(_ value: UInt32) -> UInt32 { readable(value, on: backgrounds, toward: ink) }
        let secondary = swatches.count > 3 ? swatches[3] : mix(accent, ink, 0.25)
        let tertiary = swatches.count > 4 ? swatches[4] : mix(paper, accent, 0.5)
        var colors: [String: UInt32] = [
            "canvas": canvas, "sidebar": sidebar, "surface": surface, "editor": editor,
            "rule": mix(canvas, ink, 0.28), "ink": text(ink),
            "slate": text(mix(ink, canvas, 0.12)), "muted": text(mix(ink, canvas, 0.28)),
            "accent": text(accent), "selection": accent,
            "syntax.type": text(secondary), "syntax.number": text(tertiary),
            "syntax.string": text(mix(accent, paper, 0.25)),
            "syntax.comment": text(mix(ink, canvas, 0.35)),
            "syntax.variable": text(mix(accent, secondary, 0.5)),
            "syntax.operator": text(mix(ink, canvas, 0.20))
        ]
        // Keep semantic category/error colors, adjusted for each new surface.
        for name in ["error", "success", "category.layout", "category.controls", "category.annotations", "category.services"] {
            let pair = original[name]!
            colors[name] = text(dark ? pair.1 : pair.0)
        }
        return colors
    }

    static let nightSky = Color(nsColor: native(0x2a2a35))
    static let foxglove = Color(nsColor: native(0xb98391))
    static let lilyWhite = Color(nsColor: native(0xe2e2da))
    static let nativeCanvas = adaptive("canvas")
    static let nativeSidebar = adaptive("sidebar")
    static let nativeSurface = adaptive("surface")
    static let nativeEditor = adaptive("editor")
    static let nativeRule = adaptive("rule")
    static let nativeInk = adaptive("ink")
    static let nativeSlate = adaptive("slate")
    static let nativeMuted = adaptive("muted")
    static let nativeAccent = adaptive("accent")
    static let nativeFoxglove = adaptive("selection")
    static var canvas: Color { color("canvas") }
    static var sidebar: Color { color("sidebar") }
    static var sidebarSelectionOutline: Color { currentPreset == .sputnik ? rule : sputnik }
    static var topBar: Color { color("surface") }
    static var card: Color { topBar }
    static var cardSelected: Color { topBar }
    static var editor: Color { color("editor") }
    static var rule: Color { color("rule") }
    static var ink: Color { color("ink") }
    static var slate: Color { color("slate") }
    static var muted: Color { color("muted") }
    static var sputnik: Color { color("accent") }
    static var error: Color { color("error") }
    static var success: Color { color("success") }
    static var categoryLayout: Color { color("category.layout") }
    static var categoryControls: Color { color("category.controls") }
    static var categoryDisplay: Color { sputnik }
    static var categoryAnnotations: Color { color("category.annotations") }
    static var categoryServices: Color { color("category.services") }

    static func category(_ category: String) -> Color {
        switch category {
        case "Layout": return categoryLayout
        case "Controls": return categoryControls
        case "Annotations": return categoryAnnotations
        case "Services": return categoryServices
        default: return categoryDisplay
        }
    }

    static let syntaxKeyword = nativeAccent
    static let syntaxType = adaptive("syntax.type")
    static let syntaxNumber = adaptive("syntax.number")
    static let syntaxString = adaptive("syntax.string")
    static let syntaxComment = adaptive("syntax.comment")
    static let syntaxVariable = adaptive("syntax.variable")
    static let syntaxOperator = adaptive("syntax.operator")
}
