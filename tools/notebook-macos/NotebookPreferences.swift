import AppKit
import SwiftUI

enum NotebookTheme: String, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }
    var title: String { self == .light ? "Light" : "Dark" }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
}

final class NotebookPreferences: ObservableObject {
    private let defaults: UserDefaults?
    static let themeKey = "NotebookTheme"
    static let colorPresetKey = "NotebookColorPreset"
    static let greekLetterSubstitutionKey = "NotebookGreekLetterSubstitution"

    @Published var colorPreset: NotebookColorPreset {
        didSet {
            defaults?.set(colorPreset.rawValue, forKey: Self.colorPresetKey)
            applyAppearance()
        }
    }

    @Published var substituteGreekLetters: Bool {
        didSet { defaults?.set(substituteGreekLetters, forKey: Self.greekLetterSubstitutionKey) }
    }

    @Published var theme: NotebookTheme {
        didSet {
            defaults?.set(theme.rawValue, forKey: Self.themeKey)
            applyAppearance()
        }
    }

    // A nil store is used by GUI smoke tests to leave user preferences alone.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        theme = defaults?.string(forKey: Self.themeKey).flatMap(NotebookTheme.init(rawValue:)) ?? .light
        colorPreset = defaults?.string(forKey: Self.colorPresetKey)
            .flatMap(NotebookColorPreset.init(rawValue:)) ?? .sputnik
        substituteGreekLetters = defaults?.object(forKey: Self.greekLetterSubstitutionKey) as? Bool ?? true
    }

    func applyAppearance() {
        NotebookPalette.select(colorPreset)
        NSApp?.appearance = theme.appearance
    }
}

private struct GreekLetterSubstitutionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var greekLetterSubstitutionEnabled: Bool {
        get { self[GreekLetterSubstitutionKey.self] }
        set { self[GreekLetterSubstitutionKey.self] = newValue }
    }
}

struct NotebookAppearanceView<Content: View>: View {
    @ObservedObject var preferences: NotebookPreferences
    let content: Content

    var body: some View {
        content.environment(\.colorScheme, preferences.theme.colorScheme)
            .environment(\.greekLetterSubstitutionEnabled, preferences.substituteGreekLetters)
    }
}

struct NotebookSettingsView: View {
    @ObservedObject var preferences: NotebookPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance").font(.headline)
            Picker("Theme", selection: $preferences.theme) {
                ForEach(NotebookTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("notebook-theme-picker")
            Text("Color Scheme").font(.subheadline.weight(.medium))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(NotebookColorPreset.allCases) { preset in
                        presetButton(preset)
                    }
                }
                .padding(2)
            }
            .frame(height: 340)
            .accessibilityIdentifier("notebook-color-preset-picker")
            Text("Applies immediately to all notebooks. Your choice is saved automatically.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            Divider()
            Text("Code Editing").font(.headline)
            Toggle("Replace Greek letter names with symbols", isOn: $preferences.substituteGreekLetters)
                .accessibilityIdentifier("notebook-greek-letter-substitution")
            Text("Type alpha → α or Delta → Δ, then Space, Enter, Tab or punctuation. Applies to complete code identifiers; strings and comments are preserved.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
        }
        .padding(24).frame(width: 548)
        .foregroundStyle(NotebookPalette.ink)
        .background(NotebookPalette.canvas)
        .tint(NotebookPalette.sputnik)
        .accentColor(NotebookPalette.sputnik)
    }

    private func presetButton(_ preset: NotebookColorPreset) -> some View {
        let selected = preferences.colorPreset == preset
        return Button {
            preferences.colorPreset = preset
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(Array(preset.swatches.enumerated()), id: \.offset) { _, hex in
                        Color(nsColor: NotebookPalette.native(hex))
                    }
                }
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 4) {
                    Text(preset.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NotebookPalette.sputnik).opacity(selected ? 1 : 0)
                }
            }
            .padding(9)
            .background(selected ? NotebookPalette.sputnik.opacity(0.10) : NotebookPalette.topBar,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? NotebookPalette.sputnik : NotebookPalette.rule.opacity(0.5),
                              lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("notebook-color-preset-\(preset.rawValue)")
        .help(preset.swatches.map { String(format: "#%06X", $0) }.joined(separator: " · "))
    }
}
