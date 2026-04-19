import AppKit
import CoreText
import SwiftUI

struct ReaderFontFamilyChooserView: View {
    @Environment(\.localizationBundle) private var bundle

    let selectedFamilyName: String?
    let onChoose: (String) -> Void
    var onClose: (() -> Void)?

    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installed Fonts", bundle: bundle)
                .font(.headline)

            TextField(String(localized: "Search Fonts", bundle: bundle), text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredFamilyNames.isEmpty {
                ContentUnavailableView(
                    String(localized: "No fonts match your search.", bundle: bundle),
                    systemImage: "textformat"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredFamilyNames, id: \.self) { familyName in
                    Button {
                        onChoose(familyName)
                        onClose?()
                    } label: {
                        HStack(spacing: 10) {
                            ReaderFontFamilyPreviewText(familyName: familyName)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            if normalizedSelectedFamilyName == familyName {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()

                Button(action: { onClose?() }) {
                    Text("Cancel", bundle: bundle)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 320, idealWidth: 360, minHeight: 360, idealHeight: 420)
    }

    private var normalizedSelectedFamilyName: String? {
        selectedFamilyName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private var filteredFamilyNames: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            return Self.availableFamilyNames
        }

        return Self.availableFamilyNames.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private static let availableFamilyNames: [String] = {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()
}

struct ReaderFontFamilyPreviewText: View {
    let familyName: String
    var bodySize: CGFloat = 14

    var body: some View {
        Text(familyName)
            .font(previewFont)
    }

    private var previewFont: Font {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: familyName])
        guard let font = NSFont(descriptor: descriptor, size: bodySize) else {
            return .body
        }
        return Font(font)
    }
}

struct ReaderSettingsCustomFontRow: View {
    @Environment(\.localizationBundle) private var bundle

    let familyName: String?
    let action: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                settingsValueView

                Button(action: action) {
                    Image(systemName: "chevron.up.circle")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help(String(localized: "Choose Font…", bundle: bundle))
                .accessibilityLabel(Text("Choose Font…", bundle: bundle))
            }
            .frame(minWidth: 200, maxWidth: 240, alignment: .trailing)
        } label: {
            Text("Custom Font", bundle: bundle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var settingsValueView: some View {
        if let familyName {
            ReaderFontFamilyPreviewText(familyName: familyName, bodySize: 13)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("No font selected", bundle: bundle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct ReaderThemePanelCustomFontRow: View {
    @Environment(\.localizationBundle) private var bundle

    let familyName: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            panelValueView
                .padding(.leading, 12)

            Spacer(minLength: 6)

            Button(action: action) {
                Image(systemName: "chevron.up.circle")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help(String(localized: "Choose Font…", bundle: bundle))
            .accessibilityLabel(Text("Choose Font…", bundle: bundle))
        }
    }

    @ViewBuilder
    private var panelValueView: some View {
        if let familyName {
            ReaderFontFamilyPreviewText(familyName: familyName, bodySize: 12.5)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("No font selected", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
