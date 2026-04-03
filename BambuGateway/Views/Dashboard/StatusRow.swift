import SwiftUI

struct StatusRow: View {
    let temperatures: TemperatureInfo
    let speedLevel: SpeedLevel
    @Binding var isShowingSpeedPicker: Bool

    var body: some View {
        HStack(spacing: 8) {
            temperatureCard(
                label: "Nozzle",
                actual: temperatures.nozzleTemp,
                target: temperatures.nozzleTarget
            )

            temperatureCard(
                label: "Bed",
                actual: temperatures.bedTemp,
                target: temperatures.bedTarget
            )

            speedCard
        }
    }

    private func temperatureCard(label: String, actual: Double, target: Double) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(actual))")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(target > 0 ? Color.tempOrange : .secondary)
                Text("/\(Int(target))\u{00B0}")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) temperature: \(Int(actual)) of \(Int(target)) degrees")
    }

    private var speedCard: some View {
        Button {
            isShowingSpeedPicker = true
        } label: {
            VStack(spacing: 4) {
                Text("SPEED")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                Text(speedLevel.label)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.accentBlue)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(6)
            }
        }
        .accessibilityLabel("Print speed: \(speedLevel.label)")
        .accessibilityHint("Double tap to change")
    }
}
