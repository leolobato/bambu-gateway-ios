import SwiftUI

struct PrintControlsRow: View {
    let state: String
    let onPause: () async -> Void
    let onResume: () async -> Void
    let onCancel: () async -> Void

    @State private var inFlight: ControlAction?
    @State private var isConfirmingCancel: Bool = false

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
                ) {
                    Task {
                        inFlight = .pause
                        await onPause()
                        inFlight = nil
                    }
                }
            } else {
                controlButton(
                    action: .resume,
                    title: "Resume",
                    systemImage: "play.fill"
                ) {
                    Task {
                        inFlight = .resume
                        await onResume()
                        inFlight = nil
                    }
                }
            }

            controlButton(
                action: .cancel,
                title: "Cancel",
                systemImage: "stop.fill",
                role: .destructive,
                tint: .red
            ) {
                isConfirmingCancel = true
            }
        }
        .font(.subheadline)
        .confirmationDialog(
            "Cancel this print?",
            isPresented: $isConfirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel print", role: .destructive) {
                Task {
                    inFlight = .cancel
                    await onCancel()
                    inFlight = nil
                }
            }
            Button("Keep printing", role: .cancel) {}
        } message: {
            Text("This will stop the print on the printer.")
        }
    }

    @ViewBuilder
    private func controlButton(
        action: ControlAction,
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        onTap: @escaping () -> Void
    ) -> some View {
        let isThisInFlight = inFlight == action

        Button(role: role, action: onTap) {
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
