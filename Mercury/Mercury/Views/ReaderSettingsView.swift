import SwiftUI

struct ReaderSettingsView: View {
    @Environment(\.colorScheme) var colorScheme

    @AppStorage("readerThemePresetID") var readerThemePresetIDRaw: String = ReaderThemePresetID.classic.rawValue
    @AppStorage("readerThemeMode") var readerThemeModeRaw: String = ReaderThemeMode.auto.rawValue
    @AppStorage("readerThemeOverrideFontSize") var readerThemeOverrideFontSize: Double = 0
    @AppStorage("readerThemeOverrideLineHeight") var readerThemeOverrideLineHeight: Double = 0
    @AppStorage("readerThemeOverrideContentWidth") var readerThemeOverrideContentWidth: Double = 0
    @AppStorage("readerThemeOverrideFontFamily") var readerThemeOverrideFontFamilyRaw: String = ReaderThemeFontFamilyOptionID.usePreset.rawValue
    @AppStorage("readerThemeQuickStylePresetID") var readerThemeQuickStylePresetIDRaw: String = ReaderThemeQuickStylePresetID.none.rawValue

    var body: some View {
        HStack(spacing: 18) {
            settingsForm
                .frame(width: 380)

            Divider()

            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                Section("Theme") {
                    Picker("Theme Preset", selection: $readerThemePresetIDRaw) {
                        Text("Classic").tag(ReaderThemePresetID.classic.rawValue)
                        Text("Paper").tag(ReaderThemePresetID.paper.rawValue)
                    }
                    .pickerStyle(.segmented)

                    Picker("Appearance", selection: $readerThemeModeRaw) {
                        Text("Auto").tag(ReaderThemeMode.auto.rawValue)
                        Text("Light").tag(ReaderThemeMode.forceLight.rawValue)
                        Text("Dark").tag(ReaderThemeMode.forceDark.rawValue)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Typography") {
                    Picker("Font Family", selection: $readerThemeOverrideFontFamilyRaw) {
                        Text("Use Preset").tag(ReaderThemeFontFamilyOptionID.usePreset.rawValue)
                        Text("System Sans").tag(ReaderThemeFontFamilyOptionID.systemSans.rawValue)
                        Text("Reading Serif").tag(ReaderThemeFontFamilyOptionID.readingSerif.rawValue)
                        Text("Rounded Sans").tag(ReaderThemeFontFamilyOptionID.roundedSans.rawValue)
                        Text("Monospace").tag(ReaderThemeFontFamilyOptionID.mono.rawValue)
                    }
                    .pickerStyle(.menu)

                    Stepper(value: fontSizeBinding, in: 13...28, step: 1) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(currentFontSize))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    sliderRow(
                        title: "Line Height",
                        valueText: String(format: "%.1f", currentLineHeight),
                        value: lineHeightDiscreteSliderBinding,
                        range: 14...20
                    )
                }

                Section("Reading Layout") {
                    sliderRow(
                        title: "Content Width",
                        valueText: "\(Int(currentContentWidth))",
                        value: contentWidthDiscreteSliderBinding,
                        range: 600...1000
                    )
                }

                Section("Quick Style") {
                    Picker("Style", selection: $readerThemeQuickStylePresetIDRaw) {
                        Text("Use Preset").tag(ReaderThemeQuickStylePresetID.none.rawValue)
                        Text("Warm Paper").tag(ReaderThemeQuickStylePresetID.warm.rawValue)
                        Text("Cool Blue").tag(ReaderThemeQuickStylePresetID.cool.rawValue)
                        Text("Slate Graphite").tag(ReaderThemeQuickStylePresetID.slate.rawValue)
                    }
                    .pickerStyle(.menu)
                }
            }
            .formStyle(.grouped)

            Button("Reset") {
                resetAllReaderSettings()
            }
            .disabled(hasAnyReaderSettingsChanges == false)
            .padding(.leading, 20)
        }
    }

    private func sliderRow(title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Slider(value: value, in: range)
            Text(valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Preview")
                .font(.headline)

            WebView(html: previewHTML, baseURL: nil)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                )

            Text("Changes apply immediately to Reader and cache identity.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var previewHTML: String {
        do {
            return try ReaderHTMLRenderer.render(markdown: previewMarkdown, theme: effectiveReaderTheme)
        } catch {
            return "<html><body><p>Preview render failed: \(error.localizedDescription)</p></body></html>"
        }
    }

    private var previewMarkdown: String {
        """
        # Mercury Reader Preview

        The quick brown fox jumps over the lazy dog.

        > This blockquote is used to verify contrast and spacing.

        Here is a [sample link](https://example.com) and inline `code`.

        ```swift
        let message = "Hello, Mercury"
        print(message)
        ```
        """
    }

    private var effectiveReaderTheme: EffectiveReaderTheme {
        let presetID = ReaderThemePresetID(rawValue: readerThemePresetIDRaw) ?? .classic
        let mode = ReaderThemeMode(rawValue: readerThemeModeRaw) ?? .auto
        return ReaderThemeResolver.resolve(
            presetID: presetID,
            mode: mode,
            isSystemDark: colorScheme == .dark,
            override: readerThemeOverride
        )
    }

    private var resolvedReaderThemeVariant: ReaderThemeVariant {
        let mode = ReaderThemeMode(rawValue: readerThemeModeRaw) ?? .auto
        return ReaderThemeResolver.resolveVariant(mode: mode, isSystemDark: colorScheme == .dark)
    }

    private var readerThemeOverride: ReaderThemeOverride? {
        let quickStylePresetID = ReaderThemeQuickStylePresetID(rawValue: readerThemeQuickStylePresetIDRaw) ?? .none
        var override = ReaderThemeQuickStylePreset.override(for: quickStylePresetID, variant: resolvedReaderThemeVariant) ?? .empty

        if readerThemeOverrideFontSize > 0 {
            override.fontSizeBody = min(max(readerThemeOverrideFontSize, 13), 28)
        }

        if readerThemeOverrideLineHeight > 0 {
            override.lineHeightBody = min(max(readerThemeOverrideLineHeight, 1.4), 2.0)
        }

        if readerThemeOverrideContentWidth > 0 {
            override.contentMaxWidth = min(max(readerThemeOverrideContentWidth, 600), 1000)
        }

        let fontFamilyOption = ReaderThemeFontFamilyOptionID(rawValue: readerThemeOverrideFontFamilyRaw) ?? .usePreset
        if let cssValue = fontFamilyOption.cssValue {
            override.fontFamilyBody = cssValue
        }

        return override.isEmpty ? nil : override
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { currentFontSize },
            set: { readerThemeOverrideFontSize = min(max($0, 13), 28) }
        )
    }

    private var lineHeightDiscreteSliderBinding: Binding<Double> {
        Binding(
            get: { currentLineHeight * 10 },
            set: { readerThemeOverrideLineHeight = min(max(round($0) / 10, 1.4), 2.0) }
        )
    }

    private var contentWidthDiscreteSliderBinding: Binding<Double> {
        Binding(
            get: { currentContentWidth },
            set: { readerThemeOverrideContentWidth = min(max(round($0 / 10) * 10, 600), 1000) }
        )
    }

    private var currentFontSize: Double {
        if readerThemeOverrideFontSize > 0 {
            return readerThemeOverrideFontSize
        }
        return ReaderThemePreset.tokens(
            for: ReaderThemePresetID(rawValue: readerThemePresetIDRaw) ?? .classic,
            variant: resolvedReaderThemeVariant
        ).fontSizeBody
    }

    private var currentLineHeight: Double {
        if readerThemeOverrideLineHeight > 0 {
            return readerThemeOverrideLineHeight
        }
        return ReaderThemePreset.tokens(
            for: ReaderThemePresetID(rawValue: readerThemePresetIDRaw) ?? .classic,
            variant: resolvedReaderThemeVariant
        ).lineHeightBody
    }

    private var currentContentWidth: Double {
        if readerThemeOverrideContentWidth > 0 {
            return readerThemeOverrideContentWidth
        }
        return ReaderThemePreset.tokens(
            for: ReaderThemePresetID(rawValue: readerThemePresetIDRaw) ?? .classic,
            variant: resolvedReaderThemeVariant
        ).contentMaxWidth
    }

    private var hasAnyReaderSettingsChanges: Bool {
        readerThemePresetIDRaw != ReaderThemePresetID.classic.rawValue
            || readerThemeModeRaw != ReaderThemeMode.auto.rawValue
            || readerThemeOverrideFontSize > 0
            || readerThemeOverrideLineHeight > 0
            || readerThemeOverrideContentWidth > 0
            || readerThemeOverrideFontFamilyRaw != ReaderThemeFontFamilyOptionID.usePreset.rawValue
            || readerThemeQuickStylePresetIDRaw != ReaderThemeQuickStylePresetID.none.rawValue
    }

    private func resetReaderThemeOverrides() {
        readerThemeOverrideFontSize = 0
        readerThemeOverrideLineHeight = 0
        readerThemeOverrideContentWidth = 0
        readerThemeOverrideFontFamilyRaw = ReaderThemeFontFamilyOptionID.usePreset.rawValue
        readerThemeQuickStylePresetIDRaw = ReaderThemeQuickStylePresetID.none.rawValue
    }

    private func resetAllReaderSettings() {
        readerThemePresetIDRaw = ReaderThemePresetID.classic.rawValue
        readerThemeModeRaw = ReaderThemeMode.auto.rawValue
        resetReaderThemeOverrides()
    }
}

#Preview {
    ReaderSettingsView()
}
