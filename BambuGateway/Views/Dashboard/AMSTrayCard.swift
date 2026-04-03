import SwiftUI

struct AMSTrayCard<Destination: View>: View {
    let tray: AMSTray
    let label: String
    var selectedProfileName: String? = nil
    let destination: () -> Destination

    private var isEmpty: Bool {
        tray.trayType.isEmpty && tray.filamentId.isEmpty
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 10) {
                if isEmpty {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                } else {
                    ColorSwatch(hex: tray.trayColor, size: 28)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(isEmpty ? .secondary : .primary)

                    if isEmpty {
                        Text("Empty")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        secondaryLabel

                        if let profileName = selectedProfileName {
                            Text(profileName)
                                .font(.caption)
                                .foregroundStyle(Color.accentBlue)
                        } else {
                            Text("Keep default")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                if !isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isEmpty)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var secondaryLabel: some View {
        let type = tray.trayType.isEmpty ? "-" : tray.trayType
        if !tray.filamentId.isEmpty {
            Text("\(type) \u{00B7} \(tray.filamentId)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(type)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityText: String {
        if isEmpty { return "\(label), empty" }
        let type = tray.trayType.isEmpty ? "unknown type" : tray.trayType
        if !tray.filamentId.isEmpty {
            return "\(label), \(type), \(tray.filamentId)"
        }
        return "\(label), \(type)"
    }
}
