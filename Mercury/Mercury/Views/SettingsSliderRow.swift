import SwiftUI

struct SettingsSliderRow: View {
    @Environment(\.localizationBundle) var bundle
    let title: String
    let valueText: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var valueMinWidth: Double = 56

    var body: some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(title), bundle: bundle)
            Slider(value: value, in: range)
            Text(valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: valueMinWidth, alignment: .trailing)
        }
    }
}
