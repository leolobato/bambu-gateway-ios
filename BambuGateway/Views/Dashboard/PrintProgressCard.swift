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

            if let errorMessage = printer.errorMessage, !errorMessage.isEmpty {
                errorRow(errorMessage)
            }

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

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Printer error: \(message)")
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
