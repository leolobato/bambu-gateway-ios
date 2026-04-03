import SwiftUI

struct PrintProgressCard: View {
    let printer: PrinterStatus
    let job: PrintJob

    var body: some View {
        VStack(spacing: 8) {
            stateBadge

            Text("\(job.progress)%")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .accessibilityLabel("Print progress: \(job.progress) percent")

            ProgressView(value: Double(job.progress), total: 100)
                .tint(stateColor)
                .scaleEffect(y: 1.5)
                .padding(.horizontal, 24)

            if !job.fileName.isEmpty {
                Text(job.fileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 4)
            }

            HStack(spacing: 16) {
                if job.totalLayers > 0 {
                    Text("Layer \(job.currentLayer)/\(job.totalLayers)")
                }
                if job.remainingMinutes > 0 {
                    Text("\(Self.formattedRemainingTime(job.remainingMinutes)) remaining")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var stateLabel: String {
        if let stageName = printer.stageName,
           ["preparing", "paused", "error"].contains(printer.state.lowercased()) {
            return stageName
        }
        return printer.state.capitalized
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
        Text(stateLabel)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(stateColor.opacity(0.15))
            .foregroundStyle(stateColor)
            .clipShape(Capsule())
    }

    private static func formattedRemainingTime(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return String(format: "%d:%02d", h, m)
        }
        return "\(minutes)m"
    }
}
