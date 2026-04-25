import SwiftUI

struct PrintSuccessModal: View {
    let printerName: String?
    let estimate: PrintEstimate?
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.green)
                        .padding(.top, 24)

                    Text(titleText)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    if let estimate, !estimate.isEmpty {
                        PrintEstimationCard(estimate: estimate)
                            .padding(.horizontal, 16)
                    }

                    Spacer(minLength: 16)
                }
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onDone) {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var titleText: String {
        if let printerName, !printerName.isEmpty {
            return "Print sent to \(printerName)"
        }
        return "Print sent"
    }
}

#Preview("With estimate") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PrintSuccessModal(
            printerName: "P1S",
            estimate: .init(
                totalFilamentMillimeters: 9280,
                totalFilamentGrams: 29.46,
                modelFilamentMillimeters: 9120,
                modelFilamentGrams: 28.96,
                prepareSeconds: 356,
                modelPrintSeconds: 9000,
                totalSeconds: 9356
            ),
            onDone: {}
        )
    }
}

#Preview("Without estimate") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PrintSuccessModal(printerName: "P1S", estimate: nil, onDone: {})
    }
}
