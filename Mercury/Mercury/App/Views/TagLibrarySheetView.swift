import SwiftUI

struct TagLibrarySheetView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.localizationBundle) private var bundle

    @StateObject private var viewModel = TagLibraryViewModel()
    @State private var isDeleteTagConfirmPresented = false
    @State private var isDeleteUnusedConfirmPresented = false
    @State private var isMergePickerPresented = false
    @State private var isMergeConfirmPresented = false
    @State private var mergePickerSearchText: String = ""
    @State private var mergeTargetSelection: Int64?
    @State private var pendingMergePreview: TagLibraryMergePreview?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                libraryPane
                    .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)
                inspectorPane
                    .frame(minWidth: 520, idealWidth: 620)
            }
            if let message = viewModel.message {
                Divider()
                messageBar(message)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .task {
            await viewModel.bindIfNeeded(appModel: appModel)
        }
        .onChange(of: viewModel.searchText) { _, _ in
            Task { await viewModel.refresh() }
        }
        .onChange(of: viewModel.filter) { _, _ in
            Task { await viewModel.refresh() }
        }
        .onChange(of: appModel.tagMutationVersion) { _, _ in
            Task { await viewModel.refresh() }
        }
        .sheet(isPresented: $isMergePickerPresented) {
            mergePickerSheet
        }
        .alert(
            deleteTagAlertTitle,
            isPresented: $isDeleteTagConfirmPresented
        ) {
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                Task { await viewModel.deleteSelectedTag() }
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: {
            Text(deleteTagAlertMessage)
        }
        .alert(
            String(localized: "Delete Unused Tags", bundle: bundle),
            isPresented: $isDeleteUnusedConfirmPresented
        ) {
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                Task { await viewModel.deleteUnusedTags() }
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: {
            Text(deleteUnusedAlertMessage)
        }
        .alert(
            String(localized: "Merge Tags", bundle: bundle),
            isPresented: $isMergeConfirmPresented,
            presenting: pendingMergePreview
        ) { preview in
            Button(String(localized: "Merge", bundle: bundle)) {
                Task { await viewModel.mergeSelectedTag(into: preview.targetTagId) }
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { preview in
            Text(mergeAlertMessage(preview))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tag Library", bundle: bundle)
                        .font(.title3.weight(.semibold))
                    Text(summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.canDeleteUnusedTags {
                    Button(role: .destructive) {
                        isDeleteUnusedConfirmPresented = true
                    } label: {
                        Text("Delete Unused...", bundle: bundle)
                    }
                }
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: bundle)
                }
            }

            HStack(spacing: 10) {
                TextField(String(localized: "Search tags", bundle: bundle), text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                Picker(selection: $viewModel.filter) {
                    ForEach(TagLibraryFilter.allCases) { filter in
                        Text(filter.displayTitle(bundle: bundle)).tag(filter)
                    }
                } label: {
                    Text("Filter", bundle: bundle)
                }
                .pickerStyle(.menu)
                .frame(width: 190)
            }
        }
        .padding(18)
    }

    private var libraryPane: some View {
        VStack(spacing: 0) {
            if viewModel.isLibraryEmpty {
                emptyLibraryState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else if viewModel.items.isEmpty {
                emptySearchState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                List(selection: selectionBinding) {
                    ForEach(viewModel.items) { item in
                        tagRow(item)
                            .tag(Optional<Int64>.some(item.tagId))
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let inspector = viewModel.inspector {
                    if viewModel.isMutationAllowed == false {
                        Text("Tag library mutations are unavailable while batch tagging is active.", bundle: bundle)
                            .font(.footnote)
                            .foregroundStyle(ViewSemanticStyle.warningColor)
                    }
                    identitySection(inspector)
                    aliasesSection(inspector)
                    if inspector.potentialDuplicates.isEmpty == false {
                        potentialDuplicatesSection(inspector)
                    }
                    actionsSection(inspector)
                } else if viewModel.isLibraryEmpty {
                    emptyLibraryState
                        .padding(.top, 32)
                } else if viewModel.items.isEmpty {
                    emptySearchState
                        .padding(.top, 32)
                } else {
                    emptyInspectorState
                        .padding(.top, 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private func tagRow(_ item: TagLibraryListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if item.isProvisional {
                        badge(
                            text: String(localized: "Provisional", bundle: bundle),
                            color: .orange
                        )
                    }
                    if item.aliasCount > 0 {
                        badge(
                            text: String(
                                format: String(localized: "%lld aliases", bundle: bundle),
                                Int64(item.aliasCount)
                            ),
                            color: .secondary
                        )
                    }
                    if item.hasPotentialDuplicates {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(ViewSemanticStyle.warningColor)
                            .help(String(localized: "Potential duplicates detected", bundle: bundle))
                    }
                }
            }
            Spacer(minLength: 8)
            Text("\(item.usageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func identitySection(_ inspector: TagLibraryInspectorSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                inspectorRow(
                    label: String(localized: "Canonical Name", bundle: bundle),
                    value: inspector.name
                )
                inspectorRow(
                    label: String(localized: "Normalized Name", bundle: bundle),
                    value: inspector.normalizedName
                )
                inspectorRow(
                    label: String(localized: "State", bundle: bundle),
                    value: inspector.isProvisional
                        ? String(localized: "Provisional", bundle: bundle)
                        : String(localized: "Permanent", bundle: bundle)
                )
                inspectorRow(
                    label: String(localized: "Usage Count", bundle: bundle),
                    value: "\(inspector.usageCount)"
                )
            }
        } label: {
            Text("Identity", bundle: bundle)
        }
    }

    private func aliasesSection(_ inspector: TagLibraryInspectorSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if inspector.aliases.isEmpty {
                    Text("No aliases yet.", bundle: bundle)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(inspector.aliases) { alias in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alias.alias)
                                Text(alias.normalizedAlias)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await viewModel.deleteAlias(id: alias.aliasId) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(viewModel.isMutationAllowed == false)
                            .help(String(localized: "Delete alias", bundle: bundle))
                        }
                    }
                }

                HStack(spacing: 10) {
                    TextField(String(localized: "Add alias", bundle: bundle), text: $viewModel.pendingAliasText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isMutationAllowed == false)
                        .onSubmit {
                            Task { await viewModel.addAlias() }
                        }
                    Button {
                        Task { await viewModel.addAlias() }
                    } label: {
                        Text("Add", bundle: bundle)
                    }
                    .disabled(viewModel.pendingAliasText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isMutationAllowed == false)
                }
            }
        } label: {
            Text("Aliases", bundle: bundle)
        }
    }

    private func potentialDuplicatesSection(_ inspector: TagLibraryInspectorSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("These suggestions are conservative and intended for manual review.", bundle: bundle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(inspector.potentialDuplicates) { candidate in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.name)
                            Text(candidate.reason.displayTitle(bundle: bundle))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(candidate.usageCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await viewModel.selectTag(id: candidate.tagId) }
                        } label: {
                            Text("Inspect", bundle: bundle)
                        }
                        .buttonStyle(.borderless)
                        Button {
                            openMergePicker(prefillTargetID: candidate.tagId)
                        } label: {
                            Text("Merge Into...", bundle: bundle)
                        }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.isMutationAllowed == false)
                    }
                }
            }
        } label: {
            Text("Potential Duplicates", bundle: bundle)
        }
    }

    private func actionsSection(_ inspector: TagLibraryInspectorSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    openMergePicker(prefillTargetID: nil)
                } label: {
                    Text("Merge Into...", bundle: bundle)
                }
                .disabled(viewModel.canMergeSelectedTag == false)

                Button {
                    Task { await viewModel.makeSelectedTagPermanent() }
                } label: {
                    Text("Make Permanent", bundle: bundle)
                }
                .disabled(viewModel.canMakeSelectedTagPermanent == false)

                Button(role: .destructive) {
                    isDeleteTagConfirmPresented = true
                } label: {
                    Text("Delete Tag...", bundle: bundle)
                }
                .disabled(viewModel.canDeleteSelectedTag == false)

                if inspector.isProvisional {
                    Text("Promoting a tag keeps its current assignments unchanged and prevents it from being treated as provisional in maintenance views.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("Actions", bundle: bundle)
        }
    }

    private var emptyLibraryState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No tags yet", bundle: bundle)
                .font(.title3.weight(.semibold))
            Text("Create tags from the reader or batch tagging first. This screen is for maintaining the library once tags exist.", bundle: bundle)
                .foregroundStyle(.secondary)
        }
    }

    private var emptySearchState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No matching tags", bundle: bundle)
                .font(.title3.weight(.semibold))
            Text("Adjust the current search or filter to see more of the tag library.", bundle: bundle)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyInspectorState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select a tag", bundle: bundle)
                .font(.title3.weight(.semibold))
            Text("Inspect aliases, review potential duplicates, and run maintenance actions from here.", bundle: bundle)
                .foregroundStyle(.secondary)
        }
    }

    private var mergePickerSheet: some View {
        TagLibraryMergePickerSheet(
            sourceName: viewModel.selectedTagName ?? "",
            items: viewModel.mergeTargets(matching: mergePickerSearchText),
            searchText: $mergePickerSearchText,
            selection: $mergeTargetSelection,
            onCancel: {
                isMergePickerPresented = false
                mergePickerSearchText = ""
                mergeTargetSelection = nil
            },
            onConfirm: {
                guard let targetID = mergeTargetSelection else { return }
                Task {
                    if let preview = await viewModel.loadMergePreview(targetID: targetID) {
                        pendingMergePreview = preview
                        isMergePickerPresented = false
                        isMergeConfirmPresented = true
                        mergePickerSearchText = ""
                        mergeTargetSelection = nil
                    }
                }
            }
        )
        .environment(\.localizationBundle, bundle)
    }

    private var selectionBinding: Binding<Int64?> {
        Binding(
            get: { viewModel.selectedTagID },
            set: { newValue in
                Task { await viewModel.selectTag(id: newValue) }
            }
        )
    }

    private var summaryText: String {
        String(
            format: String(
                localized: "%lld tags, %lld provisional, %lld unused",
                bundle: bundle
            ),
            Int64(viewModel.totalTagCount),
            Int64(viewModel.provisionalCount),
            Int64(viewModel.unusedCount)
        )
    }

    private var deleteTagAlertTitle: String {
        guard let name = viewModel.selectedTagName else {
            return String(localized: "Delete Tag", bundle: bundle)
        }
        return String(
            format: String(localized: "Delete tag “%@”?", bundle: bundle),
            name
        )
    }

    private var deleteTagAlertMessage: String {
        String(localized: "This removes the tag, its aliases, and all tag assignments that reference it.", bundle: bundle)
    }

    private var deleteUnusedAlertMessage: String {
        String(
            format: String(localized: "Delete %lld unused tags? This removes only tags with zero assignments.", bundle: bundle),
            Int64(viewModel.unusedCount)
        )
    }

    private func mergeAlertMessage(_ preview: TagLibraryMergePreview) -> String {
        let aliasPreservationLine = preview.willPreserveSourceCanonicalAsAlias
            ? String(localized: "The source canonical name will be preserved as an alias.", bundle: bundle)
            : String(localized: "The source canonical name cannot be preserved as an alias because of an existing conflict.", bundle: bundle)
        let aliasTransferLine = String(
            format: String(localized: "Alias migration: %lld moved, %lld skipped because of conflicts.", bundle: bundle),
            Int64(preview.migratedAliasCount),
            Int64(preview.skippedAliasCount)
        )

        return [
            String(
                format: String(
                    localized: "Merge “%@” (%lld) into “%@” (%lld). Existing duplicate assignments will be ignored.",
                    bundle: bundle
                ),
                preview.sourceName,
                Int64(preview.sourceUsageCount),
                preview.targetName,
                Int64(preview.targetUsageCount)
            ),
            aliasPreservationLine,
            aliasTransferLine
        ].joined(separator: "\n\n")
    }

    private func inspectorRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }

    private func messageBar(_ message: TagLibrarySheetMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: message.tone.symbolName)
                .foregroundStyle(message.tone.color)
            Text(message.text)
                .font(.footnote)
            Spacer()
            Button {
                viewModel.clearMessage()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(message.tone.color.opacity(0.08))
    }

    private func openMergePicker(prefillTargetID: Int64?) {
        mergePickerSearchText = ""
        mergeTargetSelection = prefillTargetID
        isMergePickerPresented = true
    }
}

private struct TagLibraryMergePickerSheet: View {
    @Environment(\.localizationBundle) private var bundle

    let sourceName: String
    let items: [TagLibraryListItem]
    @Binding var searchText: String
    @Binding var selection: Int64?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Merge Into", bundle: bundle)
                    .font(.title3.weight(.semibold))
                Text(
                    String(
                        format: String(localized: "Choose a target tag for “%@”.", bundle: bundle),
                        sourceName
                    )
                )
                .foregroundStyle(.secondary)
            }

            TextField(String(localized: "Search target tags", bundle: bundle), text: $searchText)
                .textFieldStyle(.roundedBorder)

            if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No matching target tags", bundle: bundle)
                        .font(.headline)
                    Text("Adjust the search, or close this sheet to return to the tag library.", bundle: bundle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                List(selection: $selection) {
                    ForEach(items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text("\(item.usageCount)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(Optional<Int64>.some(item.tagId))
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: bundle), action: onCancel)
                Button(String(localized: "Continue", bundle: bundle), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 420)
    }
}

private extension TagLibraryFilter {
    func displayTitle(bundle: Bundle) -> String {
        switch self {
        case .all:
            String(localized: "All", bundle: bundle)
        case .provisional:
            String(localized: "Provisional", bundle: bundle)
        case .unused:
            String(localized: "Unused", bundle: bundle)
        case .hasAliases:
            String(localized: "Has Aliases", bundle: bundle)
        case .potentialDuplicates:
            String(localized: "Potential Duplicates", bundle: bundle)
        }
    }
}

private extension TagDuplicateCandidate.Reason {
    func displayTitle(bundle: Bundle) -> String {
        switch self {
        case .pluralizationVariant:
            String(localized: "Pluralization variant", bundle: bundle)
        case .nearSpellingVariant:
            String(localized: "Near spelling variant", bundle: bundle)
        case .likelyNamingVariant:
            String(localized: "Likely naming variant", bundle: bundle)
        }
    }
}

private extension TagLibrarySheetMessage.Tone {
    var color: Color {
        switch self {
        case .success:
            .green
        case .warning:
            ViewSemanticStyle.warningColor
        case .error:
            ViewSemanticStyle.errorColor
        }
    }

    var symbolName: String {
        switch self {
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }
}
