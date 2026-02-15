import SwiftUI

enum ReaderThemeControlText {
    static let themeSection: LocalizedStringKey = "Theme"
    static let themePreset: LocalizedStringKey = "Theme Preset"
    static let appearance: LocalizedStringKey = "Appearance"
    static let quickStyle: LocalizedStringKey = "Quick Style"
    static let style: LocalizedStringKey = "Style"
    static let fontFamily: LocalizedStringKey = "Font Family"
}

struct ReaderThemePresetPicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Classic").tag(ReaderThemePresetID.classic.rawValue)
            Text("Paper").tag(ReaderThemePresetID.paper.rawValue)
        }
        .pickerStyle(.segmented)
    }
}

struct ReaderThemeModePicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Auto").tag(ReaderThemeMode.auto.rawValue)
            Text("Light").tag(ReaderThemeMode.forceLight.rawValue)
            Text("Dark").tag(ReaderThemeMode.forceDark.rawValue)
        }
        .pickerStyle(.segmented)
    }
}

struct ReaderThemeQuickStylePicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Use Preset").tag(ReaderThemeQuickStylePresetID.none.rawValue)
            Text("Warm Paper").tag(ReaderThemeQuickStylePresetID.warm.rawValue)
            Text("Cool Blue").tag(ReaderThemeQuickStylePresetID.cool.rawValue)
            Text("Slate Graphite").tag(ReaderThemeQuickStylePresetID.slate.rawValue)
        }
        .pickerStyle(.menu)
    }
}

struct ReaderThemeFontFamilyPicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Use Preset").tag(ReaderThemeFontFamilyOptionID.usePreset.rawValue)
            Text("System Sans").tag(ReaderThemeFontFamilyOptionID.systemSans.rawValue)
            Text("Reading Serif").tag(ReaderThemeFontFamilyOptionID.readingSerif.rawValue)
            Text("Rounded Sans").tag(ReaderThemeFontFamilyOptionID.roundedSans.rawValue)
            Text("Monospace").tag(ReaderThemeFontFamilyOptionID.mono.rawValue)
        }
        .pickerStyle(.menu)
    }
}
