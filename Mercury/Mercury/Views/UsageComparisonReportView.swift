import SwiftUI

private enum ProviderComparisonWindowPreset: String, CaseIterable {
    case last1Week
    case last2Weeks
    case last1Month

    var label: LocalizedStringKey {
        switch self {
        case .last1Week:
            "Last 1 Week"
        case .last2Weeks:
            "Last 2 Weeks"
        case .last1Month:
            "Last 1 Month"
        }
    }
}

struct UsageComparisonReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.localizationBundle) private var bundle

    @State private var windowPreset: ProviderComparisonWindowPreset = .last1Week

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Provider Comparison", bundle: bundle)
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: { dismiss() }) {
                    Text("Done", bundle: bundle)
                }
            }

            HStack(spacing: 10) {
                Text("Window", bundle: bundle)
                    .foregroundStyle(.secondary)

                Picker("", selection: $windowPreset) {
                    ForEach(ProviderComparisonWindowPreset.allCases, id: \.self) { preset in
                        Text(preset.label, bundle: bundle).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                Spacer()
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    VStack(spacing: 10) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text("Comparison report is coming next.", bundle: bundle)
                            .foregroundStyle(.secondary)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.6)
                )

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 520, alignment: .topLeading)
    }
}
