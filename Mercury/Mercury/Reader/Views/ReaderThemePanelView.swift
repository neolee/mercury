//
//  ReaderThemePanelView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

/// Self-contained floating panel for reader theme customization.
///
/// Owns no persistent state; all values are passed in as bindings from the parent view whose
/// `@AppStorage` properties survive navigation and app lifecycle.
struct ReaderThemePanelView: View {

    // MARK: - Environment

    @Environment(\.localizationBundle) private var bundle

    // MARK: - Bindings

    @Binding var presetIDRaw: String
    @Binding var modeRaw: String
    @Binding var quickStylePresetIDRaw: String
    @Binding var fontSizeOverride: Double
    @Binding var lineHeightOverride: Double
    @Binding var contentWidthOverride: Double
    @Binding var fontFamilyRaw: String
    @Binding var customFontFamilyName: String
    var showsFloatingChrome: Bool = true
    @State private var isPresentingCustomFontChooser = false

    // MARK: - Body

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Theme", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemePresetPicker(label: ReaderThemeControlText.themeSection, selection: $presetIDRaw)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Appearance", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeModePicker(label: ReaderThemeControlText.appearance, selection: $modeRaw)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Quick Style", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeQuickStylePicker(label: ReaderThemeControlText.quickStyle, selection: $quickStylePresetIDRaw)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Font Family", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeFontFamilyPicker(label: ReaderThemeControlText.fontFamily, selection: $fontFamilyRaw)
                    .labelsHidden()

                if isUsingCustomFontFamily {
                    ReaderThemePanelCustomFontRow(
                        familyName: normalizedCustomFontFamilyName,
                        action: { isPresentingCustomFontChooser = true }
                    )
                    .padding(.top, 3)
                    .popover(isPresented: $isPresentingCustomFontChooser, arrowEdge: .trailing) {
                        ReaderFontFamilyChooserView(
                            selectedFamilyName: normalizedCustomFontFamilyName,
                            onChoose: { familyName in
                                customFontFamilyName = familyName
                                fontFamilyRaw = ReaderThemeFontFamilyOptionID.custom.rawValue
                            },
                            onClose: { isPresentingCustomFontChooser = false }
                        )
                        .environment(\.localizationBundle, bundle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Font Size", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    fontStepButton(systemName: "minus") { decreaseFontSize() }
                    Text("\(Int(currentFontSize))")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 30)
                    fontStepButton(systemName: "plus") { increaseFontSize() }
                }
            }

            Button(action: { resetPreviewOverrides() }) {
                Text("Reset", bundle: bundle)
            }
            .padding(.top, 8)
            .disabled(
                ReaderThemeRules.hasAnyOverrides(
                    fontSizeOverride: fontSizeOverride,
                    lineHeightOverride: lineHeightOverride,
                    contentWidthOverride: contentWidthOverride,
                    fontFamilyOptionRaw: fontFamilyRaw,
                    quickStylePresetRaw: quickStylePresetIDRaw
                ) == false
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 20)
        .frame(width: 188)

        content
            .readerToolbarPanelSurface(showsFloatingChrome: showsFloatingChrome)
            .onChange(of: fontFamilyRaw) { _, newValue in
                guard newValue == ReaderThemeFontFamilyOptionID.custom.rawValue,
                      normalizedCustomFontFamilyName == nil else {
                    return
                }
                isPresentingCustomFontChooser = true
            }
    }

    // MARK: - Font Size Controls

    private func fontStepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var currentFontSize: Double {
        fontSizeOverride > 0 ? fontSizeOverride : ReaderThemeRules.defaultFontSizeFallback
    }

    private func decreaseFontSize() {
        fontSizeOverride = ReaderThemeRules.clampFontSize(currentFontSize - 1)
    }

    private func increaseFontSize() {
        fontSizeOverride = ReaderThemeRules.clampFontSize(currentFontSize + 1)
    }

    private func resetPreviewOverrides() {
        let reset = ReaderThemeRules.resetOverrideStorage
        fontSizeOverride = reset.fontSizeOverride
        lineHeightOverride = reset.lineHeightOverride
        contentWidthOverride = reset.contentWidthOverride
        fontFamilyRaw = reset.fontFamilyOptionRaw
        customFontFamilyName = reset.customFontFamilyName
        quickStylePresetIDRaw = reset.quickStylePresetRaw
    }

    private var normalizedCustomFontFamilyName: String? {
        let trimmed = customFontFamilyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var isUsingCustomFontFamily: Bool {
        fontFamilyRaw == ReaderThemeFontFamilyOptionID.custom.rawValue
    }

}
