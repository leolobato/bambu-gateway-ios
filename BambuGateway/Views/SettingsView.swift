#if os(iOS)
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

                Section("Notifications") {
                    if viewModel.pushService.capabilitiesEnabled {
                        HStack {
                            Text("Push notifications")
                            Spacer()
                            Text("Enabled")
                                .foregroundStyle(.secondary)
                        }
                        Text("Your device receives alerts when prints pause, fail, complete, or go offline. Live Activities appear on the Lock Screen during prints.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Push notifications")
                            Spacer()
                            Text("Unavailable")
                                .foregroundStyle(.secondary)
                        }
                        Text("Push requires APNs credentials on the gateway. See the README to configure your Apple Developer key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
#endif
