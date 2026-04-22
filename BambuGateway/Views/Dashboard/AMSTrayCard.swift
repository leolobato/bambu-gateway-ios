import SwiftUI

struct AMSTrayCard<Destination: View>: View {
    let tray: AMSTray
    let label: String
    var selectedProfileName: String? = nil
    var isInUse: Bool = false
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
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(isEmpty ? .secondary : .primary)

                        if isInUse {
                            inUseChip
                        }
                    }

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
            .background {
                ZStack {
                    Color.cardBackground
                    if isInUse {
                        Color.accentBlue.opacity(0.08)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isInUse ? Color.accentBlue : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .disabled(isEmpty)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isInUse ? .isSelected : [])
    }

    private var inUseChip: some View {
        Text("In Use")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentBlue, in: Capsule())
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
        let prefix = isInUse ? "In Use, " : ""
        if isEmpty { return "\(prefix)\(label), empty" }
        let type = tray.trayType.isEmpty ? "unknown type" : tray.trayType
        if !tray.filamentId.isEmpty {
            return "\(prefix)\(label), \(type), \(tray.filamentId)"
        }
        return "\(prefix)\(label), \(type)"
    }
}
