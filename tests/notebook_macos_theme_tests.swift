import AppKit
import Foundation
import SwiftUI

@main
private enum NotebookMacOSThemeTests {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let domain = "org.sputniklang.notebook.theme-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = NotebookPreferences(defaults: defaults)
        require(preferences.theme == .light, "The initial theme should stay light")
        require(preferences.colorPreset == .sputnik, "Existing users must keep the original Sputnik palette")
        require(NotebookColorPreset.allCases.count == 15, "Include System, the default and all thirteen reference palettes")
        require(preferences.substituteGreekLetters, "Greek letter replacement should be enabled by default")
        preferences.substituteGreekLetters = false
        require(!NotebookPreferences(defaults: defaults).substituteGreekLetters,
                "Disabling Greek letter replacement must persist across launches")
        preferences.substituteGreekLetters = true
        require(NotebookPreferences(defaults: defaults).substituteGreekLetters,
                "Re-enabling Greek letter replacement must persist across launches")
        let transient = NotebookPreferences(defaults: nil)
        transient.substituteGreekLetters = false
        require(NotebookPreferences(defaults: nil).substituteGreekLetters,
                "Smoke tests must not persist Greek letter preferences")
        preferences.theme = .dark
        require(NotebookPreferences(defaults: defaults).theme == .dark,
                "The saved choice must be restored by a new preferences instance")
        require(application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                "Changing the preference must update AppKit appearance")

        let source = "class Answer:\n  def value(): \"hello\" + 42 # note\n"
        let storage = NSTextStorage(string: source)
        SputnikSyntax.apply(to: storage)
        let selectionColor = NotebookPalette.nativeFoxglove.withAlphaComponent(0.35)
        for preset in NotebookColorPreset.allCases {
            preferences.colorPreset = preset
            require(NotebookPreferences(defaults: defaults).colorPreset == preset,
                    "Every preset must persist across launches: \(preset.title)")
            for theme in [NotebookTheme.dark, .light] {
                preferences.theme = theme
                require(preferences.colorPreset == preset, "Light/dark must preserve the selected palette")
                require(storage.string == source, "Appearance must preserve the source")
                let surface = resolved(NotebookPalette.nativeEditor, in: theme.appearance)
                for token in SputnikSyntax.tokens(in: source) {
                    let color = storage.attribute(.foregroundColor, at: token.range.location,
                                                  effectiveRange: nil) as! NSColor
                    require(contrast(resolved(color, in: theme.appearance), surface) >= 4.5,
                            "Existing \(token.category.rawValue) text should be readable in \(preset.title), \(theme.title)")
                }
                // System uses AppKit's exact semantic colors; generated
                // palettes additionally guarantee contrast on every surface.
                let generated = preset != .sputnik && preset != .system
                let backgrounds = generated ? [NotebookPalette.nativeCanvas,
                    NotebookPalette.nativeSidebar, NotebookPalette.nativeSurface, NotebookPalette.nativeEditor]
                    : []
                if generated {
                    let sidebar = resolved(NotebookPalette.nativeSidebar, in: theme.appearance)
                    require(contrast(sidebar, resolved(NotebookPalette.nativeCanvas, in: theme.appearance)) >= 1.2,
                            "Sidebar must remain distinct from the workspace in \(preset.title), \(theme.title)")
                    require(contrast(sidebar, resolved(NotebookPalette.nativeSurface, in: theme.appearance)) >= 1.25,
                            "Selected navigation rows must stand out in \(preset.title), \(theme.title)")
                }
                for background in backgrounds {
                    let color = resolved(background, in: theme.appearance)
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    require(channels.max()! - channels.min()! <= 0.08,
                            "Window surfaces should use subdued tints in \(preset.title), \(theme.title)")
                    for foreground in [NotebookPalette.nativeInk, NotebookPalette.nativeSlate,
                                       NotebookPalette.nativeMuted, NotebookPalette.nativeAccent] {
                        require(contrast(resolved(foreground, in: theme.appearance),
                                         resolved(background, in: theme.appearance)) >= 4.5,
                                "UI text should be readable in \(preset.title), \(theme.title)")
                    }
                }
                let expected = preset == .system
                    ? resolved(.selectedTextBackgroundColor, in: theme.appearance).withAlphaComponent(1)
                    : NotebookPalette.native(preset.swatches[1])
                require(resolved(selectionColor, in: theme.appearance).withAlphaComponent(1) == expected,
                        "An existing selection color must follow the preset without replacing text storage")
            }
        }
        verifySystemColors(preferences, storage: storage, source: source)
        preferences.colorPreset = .sputnik
        require(resolved(NotebookPalette.nativeCanvas, in: NotebookTheme.light.appearance)
                    == NotebookPalette.native(0xe2e2da), "Default light canvas must remain unchanged")
        require(resolved(NotebookPalette.nativeCanvas, in: NotebookTheme.dark.appearance)
                    == NotebookPalette.native(0x2a2a35), "Default dark canvas must remain unchanged")
        for (color, light, dark) in [
            (NotebookPalette.nativeSidebar, UInt32(0xdad1d2), UInt32(0x35313c)),
            (NotebookPalette.nativeSurface, UInt32(0xedede6), UInt32(0x22222c)),
            (NotebookPalette.nativeEditor, UInt32(0xf7f7f2), UInt32(0x22222c))
        ] {
            require(resolved(color, in: NotebookTheme.light.appearance) == NotebookPalette.native(light),
                    "Default light surfaces must remain unchanged")
            require(resolved(color, in: NotebookTheme.dark.appearance) == NotebookPalette.native(dark),
                    "Default dark surfaces must remain unchanged")
        }
        transient.colorPreset = .espresso
        require(NotebookPreferences(defaults: nil).colorPreset == .sputnik,
                "Smoke tests must not persist color presets")
        preferences.applyAppearance()
        require(NotebookPreferences(defaults: defaults).theme == .light,
                "A second choice must replace the saved dark theme")
        defaults.set("unsupported", forKey: NotebookPreferences.themeKey)
        defaults.set("unsupported", forKey: NotebookPreferences.colorPresetKey)
        require(NotebookPreferences(defaults: defaults).theme == .light,
                "An invalid saved preference must fall back to light")
        require(NotebookPreferences(defaults: defaults).colorPreset == .sputnik,
                "An invalid saved preset must fall back to the original palette")
        renderSettings(preferences)
        print("notebook macOS theme tests passed")
    }

    private static func verifySystemColors(_ preferences: NotebookPreferences, storage: NSTextStorage, source: String) {
        preferences.colorPreset = .system
        let colors: [(NSColor, NSColor)] = [
            (NotebookPalette.nativeCanvas, .windowBackgroundColor),
            (NotebookPalette.nativeSidebar, .windowBackgroundColor),
            (NotebookPalette.nativeSurface, .controlBackgroundColor),
            (NotebookPalette.nativeEditor, .textBackgroundColor),
            (NotebookPalette.nativeRule, .separatorColor),
            (NotebookPalette.nativeInk, .labelColor),
            (NotebookPalette.nativeSlate, .secondaryLabelColor),
            (NotebookPalette.nativeMuted, .secondaryLabelColor),
            (NotebookPalette.nativeAccent, .controlAccentColor),
            (NotebookPalette.nativeCaret, .textColor),
            (NotebookPalette.nativeTextSelectionBackground, .selectedTextBackgroundColor),
            (NotebookPalette.nativeTextSelectionForeground, .selectedTextColor),
            (NSColor(NotebookPalette.topBar), .windowBackgroundColor),
            (NSColor(NotebookPalette.card), .controlBackgroundColor),
            (NSColor(NotebookPalette.sidebarSelection), .unemphasizedSelectedContentBackgroundColor),
            (NSColor(NotebookPalette.error), .systemRed),
            (NSColor(NotebookPalette.success), .systemGreen)
        ]
        for name: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = NSAppearance(named: name)!
            for (actual, expected) in colors {
                require(resolved(actual, in: appearance) == resolved(expected, in: appearance),
                        "System must use AppKit's exact \(expected) in \(name)")
            }
            let editor = resolved(NotebookPalette.nativeEditor, in: appearance)
            for token in SputnikSyntax.tokens(in: source) {
                let color = storage.attribute(.foregroundColor, at: token.range.location, effectiveRange: nil) as! NSColor
                require(contrast(resolved(color, in: appearance), editor) >= 4.5,
                        "System syntax must remain readable in \(name)")
            }
            for (actual, expected) in zip(NotebookColorPreset.system.previewColors,
                                          [NSColor.labelColor, .controlAccentColor, .windowBackgroundColor]) {
                require(resolved(actual, in: appearance) == resolved(expected, in: appearance),
                        "System preview must follow the current system colors")
            }
        }
        // These objects are already installed on native editors. Switching
        // away from System must restore the existing palette's selection.
        let background = NotebookPalette.nativeTextSelectionBackground
        let foreground = NotebookPalette.nativeTextSelectionForeground
        preferences.colorPreset = .sputnik
        for theme in NotebookTheme.allCases {
            require(resolved(background, in: theme.appearance)
                        == resolved(NotebookPalette.nativeFoxglove.withAlphaComponent(0.35), in: theme.appearance),
                    "Existing palettes must retain their text selection background")
            require(resolved(foreground, in: theme.appearance) == resolved(NotebookPalette.nativeInk, in: theme.appearance),
                    "Existing palettes must retain their text selection foreground")
        }
    }

    private static func renderSettings(_ preferences: NotebookPreferences) {
        let view = NSHostingView(rootView: NotebookAppearanceView(
            preferences: preferences, content: NotebookSettingsView(preferences: preferences, remote: NotebookModel().remote)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        let previews = [NotebookTheme.light, .dark].flatMap { theme in
            NotebookColorPreset.allCases.map { ($0, theme, "appearance") }
                + [(.sputnik, theme, "resources"), (.sputnik, theme, "servers")]
        }
        for (preset, theme, tab) in previews {
            preferences.colorPreset = preset
            preferences.theme = theme
            preferences.settingsTab = tab
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            require(view.fittingSize.height <= view.bounds.height + 1, "Settings must fit without clipping")
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                require(false, "Settings must render"); return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let index = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.count > index + 1 {
                let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let suffix = tab == "appearance" ? "" : "-" + tab
                let url = folder.appendingPathComponent("settings-\(preset.rawValue)-\(theme.rawValue)\(suffix).png")
                try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
        }
        preferences.colorPreset = .sputnik
        preferences.theme = .light
        window.orderOut(nil)
    }

    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result: NSColor!
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
        return result
    }

    private static func luminance(_ color: NSColor) -> Double {
        let color = color.usingColorSpace(.sRGB)!
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let a = luminance(a), b = luminance(b)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
