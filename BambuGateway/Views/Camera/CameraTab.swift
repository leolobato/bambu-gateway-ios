import SwiftUI

struct CameraTab: View {
    @ObservedObject var viewModel: AppViewModel

    @AppStorage("bambu_gateway_ios.camera.printerExpanded")
    private var printerFeedExpanded: Bool = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    printerPicker
                    ChamberLightToggle(viewModel: viewModel)
                    printerFeed
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .navigationTitle("Camera")
            .background(Color(.systemGroupedBackground))
        }
    }

    @ViewBuilder
    private var printerPicker: some View {
        if viewModel.printers.count > 1 {
            Picker("Printer", selection: $viewModel.selectedPrinterId) {
                ForEach(viewModel.printers) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var printerFeed: some View {
        if let printer = viewModel.selectedPrinter {
            if printer.online, let camera = printer.camera {
                CameraFeedView(title: "Printer", isExpanded: $printerFeedExpanded) {
                    BambuPrinterCameraFeed(camera: camera)
                }
                .id("printer-\(printer.id)-\(camera.ip)")
            } else {
                placeholder(text: printer.online ? "Camera not available for this printer." : "Printer offline.")
            }
        } else {
            placeholder(text: "No printer selected.")
        }
    }

    private func placeholder(text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
