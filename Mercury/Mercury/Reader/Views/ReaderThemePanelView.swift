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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .padding(10)
        .frame(width: 228)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .onTapGesture {}
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
        quickStylePresetIDRaw = reset.quickStylePresetRaw
    }

}
