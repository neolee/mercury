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
                    ReaderThemePresetPicker(label: ReaderThemeControlText.themePreset, selection: $readerThemePresetIDRaw)

                    ReaderThemeModePicker(label: ReaderThemeControlText.appearance, selection: $readerThemeModeRaw)
                }

                Section("Quick Style") {
                    ReaderThemeQuickStylePicker(label: ReaderThemeControlText.style, selection: $readerThemeQuickStylePresetIDRaw)
                }

                Section("Typography") {
                    ReaderThemeFontFamilyPicker(label: ReaderThemeControlText.fontFamily, selection: $readerThemeOverrideFontFamilyRaw)

                    Stepper(value: fontSizeBinding, in: 13...28, step: 1) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(currentFontSize))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsSliderRow(
                        title: "Line Height",
                        valueText: String(format: "%.1f", currentLineHeight),
                        value: lineHeightDiscreteSliderBinding,
                        range: 14...20
                    )
                }

                Section("Reading Layout") {
                    SettingsSliderRow(
                        title: "Content Width",
                        valueText: "\(Int(currentContentWidth))",
                        value: contentWidthDiscreteSliderBinding,
                        range: 600...1000
                    )
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
        ReaderThemeRules.makeOverride(
            variant: resolvedReaderThemeVariant,
            quickStylePresetRaw: readerThemeQuickStylePresetIDRaw,
            fontSizeOverride: readerThemeOverrideFontSize,
            lineHeightOverride: readerThemeOverrideLineHeight,
            contentWidthOverride: readerThemeOverrideContentWidth,
            fontFamilyOptionRaw: readerThemeOverrideFontFamilyRaw
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { currentFontSize },
            set: { readerThemeOverrideFontSize = ReaderThemeRules.clampFontSize($0) }
        )
    }

    private var lineHeightDiscreteSliderBinding: Binding<Double> {
        Binding(
            get: { currentLineHeight * 10 },
            set: { readerThemeOverrideLineHeight = ReaderThemeRules.snapLineHeight($0 / 10) }
        )
    }

    private var contentWidthDiscreteSliderBinding: Binding<Double> {
        Binding(
            get: { currentContentWidth },
            set: { readerThemeOverrideContentWidth = ReaderThemeRules.snapContentWidth($0) }
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
            || ReaderThemeRules.hasAnyOverrides(
                fontSizeOverride: readerThemeOverrideFontSize,
                lineHeightOverride: readerThemeOverrideLineHeight,
                contentWidthOverride: readerThemeOverrideContentWidth,
                fontFamilyOptionRaw: readerThemeOverrideFontFamilyRaw,
                quickStylePresetRaw: readerThemeQuickStylePresetIDRaw
            )
    }

    private func resetReaderThemeOverrides() {
        let reset = ReaderThemeRules.resetOverrideStorage
        readerThemeOverrideFontSize = reset.fontSizeOverride
        readerThemeOverrideLineHeight = reset.lineHeightOverride
        readerThemeOverrideContentWidth = reset.contentWidthOverride
        readerThemeOverrideFontFamilyRaw = reset.fontFamilyOptionRaw
        readerThemeQuickStylePresetIDRaw = reset.quickStylePresetRaw
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
