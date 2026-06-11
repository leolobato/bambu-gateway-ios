import SwiftUI

/// Root-attached modal for the send-to-printer flow: live upload progress
/// while the gateway streams the file to the printer, flipping to the
/// success summary when the upload completes (or an error state on failure).
struct PrintProgressModal: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch viewModel.printFlow {
                    case .uploading(let progress):
                        uploadingContent(progress: progress)
                    case .failed(let message):
                        failedContent(message: message)
                    case .success, .none:
                        successContent
                    }

                    Spacer(minLength: 16)
                }
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) { doneButton }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
        .animation(.easeInOut(duration: 0.2), value: viewModel.printFlow)
    }

    // MARK: - Uploading

    @ViewBuilder
    private func uploadingContent(progress: Double?) -> some View {
        Image(systemName: "arrow.up.doc.fill")
            .font(.system(size: 56, weight: .regular))
            .foregroundStyle(Color.accentBlue)
            .padding(.top, 24)

        Text("Sending to \(viewModel.lastPrintPrinterName ?? "printer")…")
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)

        VStack(spacing: 10) {
            if let progress {
                HStack {
                    Text(viewModel.isCancellingUpload ? "Cancelling…" : "Uploading to printer")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentBlue)

                    Spacer()

                    Text("\(Int(progress))%")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: progress, total: 100)
                    .tint(Color.accentBlue)
            } else {
                ProgressView()
                    .tint(Color.accentBlue)
                    .frame(maxWidth: .infinity)
            }

            Button(role: .destructive) {
                Task { await viewModel.cancelUpload() }
            } label: {
                Label("Cancel upload", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(viewModel.isCancellingUpload)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)

        if let estimate = viewModel.lastPrintEstimate, !estimate.isEmpty {
            PrintEstimationCard(estimate: estimate)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Success

    @ViewBuilder
    private var successContent: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 56, weight: .regular))
            .foregroundStyle(.green)
            .padding(.top, 24)

        Text(titleText)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)

        if let estimate = viewModel.lastPrintEstimate, !estimate.isEmpty {
            PrintEstimationCard(estimate: estimate)
                .padding(.horizontal, 16)
        }
    }

    private var titleText: String {
        if let printerName = viewModel.lastPrintPrinterName, !printerName.isEmpty {
            return "Print sent to \(printerName)"
        }
        return "Print sent"
    }

    // MARK: - Failed

    @ViewBuilder
    private func failedContent(message: String) -> some View {
        Image(systemName: "xmark.octagon.fill")
            .font(.system(size: 56, weight: .regular))
            .foregroundStyle(.red)
            .padding(.top, 24)

        Text("Couldn't start print")
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)

        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }

    // MARK: - Done

    private var doneButton: some View {
        Button {
            viewModel.dismissPrintFlow()
        } label: {
            Text("Done")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}
