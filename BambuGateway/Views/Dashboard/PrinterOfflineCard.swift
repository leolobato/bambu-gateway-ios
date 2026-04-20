import SwiftUI

struct PrinterOfflineCard: View {
    let printer: PrinterStatus
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

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

            Text("Offline")
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())

            Text("Printer can't be reached. Check that it's powered on and connected to the network.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            Button(action: onRetry) {
                HStack(spacing: 8) {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRetrying ? "Checking…" : "Try Again")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRetrying)
            .accessibilityLabel(isRetrying ? "Checking printer connection" : "Try to reconnect to printer")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
