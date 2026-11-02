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
    @Published var settingsTab = "appearance"
    private let defaults: UserDefaults?
    static let resourcePolicyKey = "NotebookResourcePolicy"
    var onResourcePolicyChange: ((NotebookResourcePolicy) -> Void)?
    @Published var resourcePolicy: NotebookResourcePolicy {
        didSet {
            if let data = try? JSONEncoder().encode(resourcePolicy) { defaults?.set(data, forKey: Self.resourcePolicyKey) }
            onResourcePolicyChange?(resourcePolicy)
        }
    }
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
        resourcePolicy = defaults?.data(forKey: Self.resourcePolicyKey).flatMap { try? JSONDecoder().decode(NotebookResourcePolicy.self, from: $0) } ?? .appDefaults
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
    @ObservedObject var remote: NotebookRemoteController

    var body: some View {
        TabView(selection: $preferences.settingsTab) {
            NotebookSettingsPane { appearance }
                .tabItem { Text("Appearance") }.tag("appearance")
            NotebookSettingsPane { NotebookAppResourceSettings(preferences: preferences) }
                .tabItem { Text("Resources") }.tag("resources")
            NotebookSettingsPane { NotebookServerEditor(remote: remote, embedded: true) }
                .tabItem { Text("Servers") }.tag("servers")
        }
        .frame(width: 590, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appearance: some View {
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
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Code Editing").font(.headline)
            Toggle("Replace Greek letter names with symbols", isOn: $preferences.substituteGreekLetters)
                .accessibilityIdentifier("notebook-greek-letter-substitution")
            Text("Type alpha → α or Delta → Δ, then Space, Enter, Tab or punctuation. Applies to complete code identifiers; strings and comments are preserved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func presetButton(_ preset: NotebookColorPreset) -> some View {
        let selected = preferences.colorPreset == preset
        return Button {
            preferences.colorPreset = preset
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(Array(preset.previewColors.enumerated()), id: \.offset) { _, color in
                        Color(nsColor: color)
                    }
                }
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 4) {
                    Text(preset.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor).opacity(selected ? 1 : 0)
                }
            }
            .padding(9)
            .background(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("notebook-color-preset-\(preset.rawValue)")
        .help(preset == .system ? "Uses macOS system colors and your system accent in Light and Dark."
              : preset.swatches.map { String(format: "#%06X", $0) }.joined(separator: " · "))
    }
}

private struct NotebookSettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .topLeading).padding(24)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct NotebookAppResourceSettings: View {
    @ObservedObject var preferences: NotebookPreferences
    @State private var draft: NotebookResourcePolicy
    init(preferences: NotebookPreferences) {
        self.preferences = preferences
        _draft = State(initialValue: preferences.resourcePolicy)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
                Text("App Resource Defaults").font(.headline)
                Text("Notebooks inherit these settings unless overridden in Notebook Settings. Each local notebook can use higher or lower values. Remote execution also follows the server's policy.").foregroundStyle(.secondary)
                NotebookResourcePolicyForm(policy: $draft)
                Text("History is trimmed when a run is saved. Pinned runs are protected. Execution time is cumulative per notebook.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Restore Defaults") { draft = .appDefaults }
                    Spacer()
                    Button("Save App Defaults") { preferences.resourcePolicy = draft }
                        .disabled(draft.validationError != nil).accessibilityIdentifier("save-app-resource-policy")
                }
        }
        .onAppear { draft = preferences.resourcePolicy }
    }
}
