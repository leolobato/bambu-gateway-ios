import SwiftUI

struct ChamberLightToggle: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if viewModel.chamberLightSupported, let isOn = viewModel.chamberLightOn {
            Button(action: { Task { await viewModel.setChamberLight(on: !isOn) } }) {
                HStack(spacing: 12) {
                    if viewModel.chamberLightPending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: isOn ? "lightbulb.fill" : "lightbulb")
                            .font(.title2)
                    }
                    Text(isOn ? "Chamber light on" : "Chamber light off")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(isOn ? Color.accentColor : Color(.tertiarySystemBackground))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(viewModel.chamberLightPending || viewModel.selectedPrinter?.online != true)
            .accessibilityLabel("Chamber light")
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }
}
