import SwiftUI

struct ProcessOptionRow: View {
    enum Status {
        case unmodified
        case threeMFModified
        case userEdited
        case readOnly
    }

    let label: String
    let value: String
    let sidetext: String
    let status: Status
    let showsTooltip: Bool
    let tooltip: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                statusIndicator
                    .frame(width: 12, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showsTooltip, let tooltip, !tooltip.isEmpty {
                        Text(tooltip)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text(value)
                        .font(.body)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(status == .readOnly ? .secondary : .primary)
                    if !sidetext.isEmpty {
                        Text(sidetext)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if status != .readOnly {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .readOnly)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)\(sidetext.isEmpty ? "" : " " + sidetext)")
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(status == .readOnly ? "Read only" : "Tap to edit")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .unmodified:
            Color.clear.frame(width: 8, height: 8)
        case .threeMFModified:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.accentBlue)
        case .userEdited:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
        case .readOnly:
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private var accessibilityValueText: String {
        switch status {
        case .unmodified: return ""
        case .threeMFModified: return "modified by file"
        case .userEdited: return "edited by you"
        case .readOnly: return "read only"
        }
    }
}
