import SwiftUI

struct SpeedPickerSheet: View {
    let currentLevel: SpeedLevel
    let onSelect: (SpeedLevel) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(SpeedLevel.allCases) { level in
                    Button {
                        Task {
                            await onSelect(level)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level.label)
                                    .font(.body)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(level == currentLevel ? Color.accentBlue : .primary)

                                Text(level.description)
                                    .font(.caption)
                                    .foregroundStyle(level == currentLevel ? Color.accentBlue.opacity(0.7) : .secondary)
                            }

                            Spacer()

                            if level == currentLevel {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentBlue)
                                    .fontWeight(.semibold)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(
                        level == currentLevel
                            ? Color.accentBlue.opacity(0.1)
                            : Color.clear
                    )
                }
            }
            .navigationTitle("Print Speed")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
