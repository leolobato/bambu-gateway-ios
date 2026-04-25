import SwiftUI

struct PrintEstimationCard: View {
    let estimate: PrintEstimate?
    /// When `true`, renders the card in a redacted placeholder state regardless of `estimate`.
    let isLoading: Bool

    init(estimate: PrintEstimate?, isLoading: Bool = false) {
        self.estimate = estimate
        self.isLoading = isLoading
    }

    var body: some View {
        if isLoading {
            cardBody(estimate: PrintEstimate.placeholder)
                .redacted(reason: .placeholder)
        } else if let estimate, !estimate.isEmpty {
            cardBody(estimate: estimate)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func cardBody(estimate: PrintEstimate) -> some View {
        let showFilament = estimate.totalFilamentMillimeters != nil
            || estimate.totalFilamentGrams != nil
            || estimate.modelFilamentMillimeters != nil
            || estimate.modelFilamentGrams != nil
        let showTime = estimate.prepareSeconds != nil
            || estimate.modelPrintSeconds != nil
            || estimate.totalSeconds != nil

        VStack(alignment: .leading, spacing: 12) {
            if showFilament {
                VStack(spacing: 8) {
                    FilamentRow(
                        icon: "scribble.variable",
                        label: "Total Filament",
                        millimeters: estimate.totalFilamentMillimeters,
                        grams: estimate.totalFilamentGrams
                    )
                    FilamentRow(
                        icon: "cube",
                        label: "Model Filament",
                        millimeters: estimate.modelFilamentMillimeters,
                        grams: estimate.modelFilamentGrams
                    )
                }
            }
            if showFilament && showTime {
                Divider()
            }
            if showTime {
                VStack(spacing: 8) {
                    TimeRow(
                        icon: "wrench.and.screwdriver",
                        label: "Prepare",
                        seconds: estimate.prepareSeconds,
                        emphasized: false
                    )
                    TimeRow(
                        icon: "printer.fill",
                        label: "Printing",
                        seconds: estimate.modelPrintSeconds,
                        emphasized: false
                    )
                    TimeRow(
                        icon: "clock",
                        label: "Total",
                        seconds: estimate.totalSeconds,
                        emphasized: true
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FilamentRow: View {
    let icon: String
    let label: String
    let millimeters: Double?
    let grams: Double?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .accessibilityElement(children: .combine)
    }

    private var horizontalLayout: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            lengthText
                .frame(minWidth: 80, alignment: .trailing)
            massText
                .frame(minWidth: 80, alignment: .trailing)
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                lengthText
                massText
            }
            .padding(.leading, 24)
        }
    }

    @ViewBuilder
    private var lengthText: some View {
        if let formatted = PrintEstimateFormatters.formatLength(millimeters: millimeters) {
            Text(formatted)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
        } else {
            Text("—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var massText: some View {
        if let formatted = PrintEstimateFormatters.formatMass(grams: grams) {
            Text(formatted)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
        } else {
            Text("—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

private struct TimeRow: View {
    let icon: String
    let label: String
    let seconds: Int?
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Spacer(minLength: 8)
            if let formatted = PrintEstimateFormatters.formatDuration(seconds: seconds) {
                Text(formatted)
                    .font(emphasized
                          ? .subheadline.weight(.semibold).monospacedDigit()
                          : .subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
            } else {
                Text("—")
                    .font(emphasized
                          ? .subheadline.weight(.semibold).monospacedDigit()
                          : .subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension PrintEstimate {
    static let placeholder = PrintEstimate(
        totalFilamentMillimeters: 9280,
        totalFilamentGrams: 29.46,
        modelFilamentMillimeters: 9120,
        modelFilamentGrams: 28.96,
        prepareSeconds: 356,
        modelPrintSeconds: 9000,
        totalSeconds: 9356
    )
}

#Preview("Full data") {
    PrintEstimationCard(estimate: .init(
        totalFilamentMillimeters: 9280,
        totalFilamentGrams: 29.46,
        modelFilamentMillimeters: 9120,
        modelFilamentGrams: 28.96,
        prepareSeconds: 356,
        modelPrintSeconds: 9000,
        totalSeconds: 9356
    ))
    .padding()
}

#Preview("Partial data") {
    PrintEstimationCard(estimate: .init(
        totalFilamentMillimeters: 9280,
        totalFilamentGrams: nil,
        modelFilamentMillimeters: nil,
        modelFilamentGrams: nil,
        prepareSeconds: nil,
        modelPrintSeconds: nil,
        totalSeconds: 9356
    ))
    .padding()
}

#Preview("Loading") {
    PrintEstimationCard(estimate: nil, isLoading: true)
        .padding()
}

#Preview("Empty (renders nothing)") {
    PrintEstimationCard(estimate: nil)
        .padding()
        .background(Color.red.opacity(0.1))
}

#Preview("AX large text") {
    PrintEstimationCard(estimate: .init(
        totalFilamentMillimeters: 9280,
        totalFilamentGrams: 29.46,
        modelFilamentMillimeters: 9120,
        modelFilamentGrams: 28.96,
        prepareSeconds: 356,
        modelPrintSeconds: 9000,
        totalSeconds: 9356
    ))
    .padding()
    .environment(\.dynamicTypeSize, .accessibility3)
}
