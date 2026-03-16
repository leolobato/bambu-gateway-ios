import GCodePreview
import SwiftUI

struct GCodePreviewModal: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                if let scene = viewModel.previewScene {
                    GCodePreviewView(scene: scene)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView("Preparing preview...")
                }
            }
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
