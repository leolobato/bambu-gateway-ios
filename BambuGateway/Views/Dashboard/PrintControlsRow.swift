import SwiftUI

struct PrintControlsRow: View {
    let state: String
    let onPause: () async -> Void
    let onResume: () async -> Void
    let onCancel: () async -> Void

    var body: some View {
        HStack(spacing: 8) {
            if state.lowercased() == "printing" {
                Button {
                    Task { await onPause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await onResume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                Task { await onCancel() }
            } label: {
                Label("Cancel", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .font(.subheadline)
    }
}
