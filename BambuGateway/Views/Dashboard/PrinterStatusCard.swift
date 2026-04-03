import SwiftUI

struct PrinterStatusCard: View {
    let printer: PrinterStatus

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(printer.name)
                    .font(.title3)
                    .fontWeight(.bold)

                if !printer.machineModel.isEmpty {
                    Text(printer.machineModel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            stateBadge

            HStack(spacing: 10) {
                temperatureCard(
                    label: "Nozzle",
                    actual: printer.temperatures.nozzleTemp,
                    target: printer.temperatures.nozzleTarget
                )
                temperatureCard(
                    label: "Bed",
                    actual: printer.temperatures.bedTemp,
                    target: printer.temperatures.bedTarget
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var stateColor: Color {
        switch printer.state.lowercased() {
        case "idle", "finished":
            return .green
        case "printing", "preparing", "running":
            return .accentBlue
        case "paused":
            return .orange
        case "cancelled", "error":
            return .red
        default:
            return .gray
        }
    }

    private var stateBadge: some View {
        Text(printer.state.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(stateColor.opacity(0.15))
            .foregroundStyle(stateColor)
            .clipShape(Capsule())
    }

    private func temperatureCard(label: String, actual: Double, target: Double) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(actual))")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(target > 0 ? Color.tempOrange : .secondary)
                Text("/\(Int(target))\u{00B0}")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.cardBackgroundInner)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) temperature: \(Int(actual)) of \(Int(target)) degrees")
    }
}
