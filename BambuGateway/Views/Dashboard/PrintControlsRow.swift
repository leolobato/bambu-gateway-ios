import SwiftUI

struct PrintControlsRow: View {
    let state: String
    let onPause: () async -> Void
    let onResume: () async -> Void
    let onCancel: () async -> Void

    @State private var inFlight: ControlAction?

    private enum ControlAction {
        case pause, resume, cancel
    }

    var body: some View {
        HStack(spacing: 8) {
            if state.lowercased() == "printing" {
                controlButton(
                    action: .pause,
                    title: "Pause",
                    systemImage: "pause.fill"
                ) { await onPause() }
            } else {
                controlButton(
                    action: .resume,
                    title: "Resume",
                    systemImage: "play.fill"
                ) { await onResume() }
            }

            controlButton(
                action: .cancel,
                title: "Cancel",
                systemImage: "stop.fill",
                role: .destructive,
                tint: .red
            ) { await onCancel() }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func controlButton(
        action: ControlAction,
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        handler: @escaping () async -> Void
    ) -> some View {
        let isThisInFlight = inFlight == action

        Button(role: role) {
            Task {
                inFlight = action
                await handler()
                inFlight = nil
            }
        } label: {
            HStack(spacing: 6) {
                if isThisInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(inFlight != nil)
    }
}
