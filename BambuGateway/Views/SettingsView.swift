import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _baseURL = State(initialValue: viewModel.gatewayBaseURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    TextField("http://192.168.1.10:4844", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task {
                            viewModel.gatewayBaseURL = baseURL
                            await viewModel.onGatewayAddressSaved()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
