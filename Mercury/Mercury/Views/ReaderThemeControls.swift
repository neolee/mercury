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
    @Environment(\.localizationBundle) var bundle
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(selection: $selection) {
            Text("Classic", bundle: bundle).tag(ReaderThemePresetID.classic.rawValue)
            Text("Paper", bundle: bundle).tag(ReaderThemePresetID.paper.rawValue)
        } label: {
            Text(label, bundle: bundle)
        }
        .pickerStyle(.segmented)
    }
}

struct ReaderThemeModePicker: View {
    @Environment(\.localizationBundle) var bundle
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(selection: $selection) {
            Text("Auto", bundle: bundle).tag(ReaderThemeMode.auto.rawValue)
            Text("Light", bundle: bundle).tag(ReaderThemeMode.forceLight.rawValue)
            Text("Dark", bundle: bundle).tag(ReaderThemeMode.forceDark.rawValue)
        } label: {
            Text(label, bundle: bundle)
        }
        .pickerStyle(.segmented)
    }
}

struct ReaderThemeQuickStylePicker: View {
    @Environment(\.localizationBundle) var bundle
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(selection: $selection) {
            Text("Use Preset", bundle: bundle).tag(ReaderThemeQuickStylePresetID.none.rawValue)
            Text("Warm Paper", bundle: bundle).tag(ReaderThemeQuickStylePresetID.warm.rawValue)
            Text("Cool Blue", bundle: bundle).tag(ReaderThemeQuickStylePresetID.cool.rawValue)
            Text("Slate Graphite", bundle: bundle).tag(ReaderThemeQuickStylePresetID.slate.rawValue)
        } label: {
            Text(label, bundle: bundle)
        }
        .pickerStyle(.menu)
    }
}

struct ReaderThemeFontFamilyPicker: View {
    @Environment(\.localizationBundle) var bundle
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(selection: $selection) {
            Text("Use Preset", bundle: bundle).tag(ReaderThemeFontFamilyOptionID.usePreset.rawValue)
            Text("System Sans").tag(ReaderThemeFontFamilyOptionID.systemSans.rawValue)
            Text("Reading Serif").tag(ReaderThemeFontFamilyOptionID.readingSerif.rawValue)
            Text("Rounded Sans").tag(ReaderThemeFontFamilyOptionID.roundedSans.rawValue)
            Text("Monospace").tag(ReaderThemeFontFamilyOptionID.mono.rawValue)
        } label: {
            Text(label, bundle: bundle)
        }
        .pickerStyle(.menu)
    }
}
