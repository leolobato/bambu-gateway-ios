import GCodePreview
import SwiftUI

struct GCodePreviewModal: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PrintEstimationCard(
                    estimate: viewModel.previewEstimate,
                    isLoading: viewModel.isLoadingPreview && viewModel.previewEstimate == nil
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ZStack {
                    Color(uiColor: .systemBackground)

                    if let scene = viewModel.previewScene {
                        GCodePreviewView(scene: scene)
                    } else {
                        ProgressView("Preparing preview...")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("G-code Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelPreview()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await viewModel.confirmPreviewPrint()
                        }
                    } label: {
                        if viewModel.isSubmitting {
                            ProgressView()
                        } else {
                            Text("Print")
                        }
                    }
                    .disabled(viewModel.previewScene == nil || viewModel.isSubmitting)
                }
            }
        }
    }
}
