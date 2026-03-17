import SwiftUI
import UniformTypeIdentifiers

struct PrintTab: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var isShowingFileImporter = false

    var body: some View {
        NavigationStack {
            Form {
                fileSection
                if viewModel.isParsing {
                    Section("Project") {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading project...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if viewModel.hasParsedFile {
                    parsedSection
                    filamentsSection
                    submitSection
                }
            }
            .navigationTitle("Print")
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.threeMF],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let first = urls.first else { return }
                Task {
                    await viewModel.import3MF(from: first)
                }
            case .failure(let error):
                viewModel.message = error.localizedDescription
                viewModel.messageLevel = .error
            }
        }
        .fullScreenCover(isPresented: $viewModel.isShowingPreview) {
            GCodePreviewModal(viewModel: viewModel)
        }
    }

    private var fileSection: some View {
        Section("3MF File") {
            Button("Import from Files") {
                isShowingFileImporter = true
            }

            Button("Import from MakerWorld") {
                viewModel.openMakerWorldBrowser()
            }

            if let selectedFile = viewModel.selectedFile {
                HStack {
                    Text(selectedFile.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Clear") {
                        viewModel.clearFile()
                    }
                    .foregroundStyle(.red)
                }
            } else {
                Text("Use Files picker, Share Sheet, or MakerWorld")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var parsedSection: some View {
        Section("Project") {
            if let parsedInfo = viewModel.parsedInfo {
                Text(parsedInfo.hasGcode ? "Already sliced" : "Needs slicing")
                    .foregroundStyle(parsedInfo.hasGcode ? .green : .orange)

                if let currentPlate = parsedInfo.plates.first(where: { $0.id == viewModel.selectedPlateId }) {
                    PlateThumbnailView(dataURL: currentPlate.thumbnail)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }

                if viewModel.hasMultiplePlates {
                    Picker("Plate", selection: Binding(
                        get: { viewModel.selectedPlateId },
                        set: { viewModel.selectedPlateId = $0 }
                    )) {
                        ForEach(parsedInfo.plates) { plate in
                            if plate.name.isEmpty {
                                Text("Plate \(plate.id)").tag(plate.id)
                            } else {
                                Text("Plate \(plate.id) - \(plate.name)").tag(plate.id)
                            }
                        }
                    }
                }

                if viewModel.needsSlicing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project machine")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(viewModel.projectDefaultMachineName)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project process")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(viewModel.projectDefaultProcessName)
                    }

                    Picker("Machine profile", selection: Binding(
                        get: { viewModel.selectedMachineProfileId },
                        set: { viewModel.setMachineProfile($0) }
                    )) {
                        ForEach(viewModel.machineOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("Process profile", selection: Binding(
                        get: { viewModel.selectedProcessProfileId },
                        set: { viewModel.setProcessProfile($0) }
                    )) {
                        ForEach(viewModel.processOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("Plate type", selection: Binding(
                        get: { viewModel.selectedPlateType },
                        set: { viewModel.setPlateType($0) }
                    )) {
                        ForEach(viewModel.plateTypeOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

            } else {
                Text("Import a 3MF file to inspect plates, profiles, and filaments.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filamentsSection: some View {
        Section("Filaments") {
            if let parsedInfo = viewModel.parsedInfo {
                if parsedInfo.filaments.isEmpty {
                    Text("No project filaments")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(parsedInfo.filaments, id: \.index) { filament in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ColorSwatch(hex: filament.color)
                                if filament.settingId.isEmpty {
                                    Text("Filament \(filament.index)")
                                        .font(.headline)
                                } else {
                                    Text("\(filament.index): \(filament.settingId)")
                                        .font(.headline)
                                }
                                Spacer()
                                Text(filament.type.isEmpty ? "-" : filament.type)
                                    .foregroundStyle(.secondary)
                            }

                            trayLink(for: filament)
                        }
                    }
                }
            }
        }
    }

    private var submitSection: some View {
        Section("Submit") {
            if !viewModel.message.isEmpty {
                Text(viewModel.message)
                    .foregroundStyle(messageColor)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if let progress = viewModel.uploadProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress, total: 100)
                    Text("Uploading to printer… \(Int(progress))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.hasStartedPrintForCurrentSelection {
                Text("Print already started for this selection. Clear the file or change the print settings to submit again.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                HStack(spacing: 16) {
                    Button {
                        Task {
                            await viewModel.submitPreview()
                        }
                    } label: {
                        HStack {
                            if viewModel.isLoadingPreview {
                                ProgressView()
                            }
                            Text("Preview")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canSubmit)

                    Button {
                        Task {
                            await viewModel.submitPrint()
                        }
                    } label: {
                        HStack {
                            if viewModel.isSubmitting {
                                ProgressView()
                            }
                            Text("Print")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }

    private var canSubmit: Bool {
        viewModel.hasParsedFile && !viewModel.isSubmitting && !viewModel.isLoadingPreview
    }

    private func trayLink(for filament: ProjectFilament) -> some View {
        NavigationLink {
            TrayPickerView(
                trays: viewModel.allAvailableTrays,
                trayLabel: { trayPickerLabel(for: $0) },
                selection: Binding(
                    get: { viewModel.filamentTraySelection(for: filament.index) },
                    set: { viewModel.setFilamentTraySelection(index: filament.index, slot: $0) }
                )
            )
        } label: {
            let selectedSlot = viewModel.filamentTraySelection(for: filament.index)
            if let slot = selectedSlot,
               let tray = viewModel.allAvailableTrays.first(where: { $0.slot == slot }) {
                HStack(spacing: 6) {
                    ColorSwatch(hex: tray.trayColor)
                    Text(trayPickerLabel(for: tray))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Keep default")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func trayPickerLabel(for tray: AMSTray) -> String {
        let trayName = tray.trayType.isEmpty ? "Unknown" : tray.trayType
        let label: String
        if tray.slot == 254 {
            label = "External (\(trayName))"
        } else if viewModel.amsUnits.count > 1 {
            label = "AMS \(tray.amsId + 1) Tray \(tray.trayId + 1) (\(trayName))"
        } else {
            label = "Tray \(tray.trayId + 1) (\(trayName))"
        }
        let profileId = viewModel.trayProfileSelection(for: tray.slot)
        if !profileId.isEmpty,
           let profile = viewModel.slicerFilaments.first(where: { $0.settingId == profileId }) {
            return "\(label) — \(profile.name)"
        }
        return label
    }

    private var messageColor: Color {
        switch viewModel.messageLevel {
        case .info:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

}

private struct TrayPickerView: View {
    let trays: [AMSTray]
    let trayLabel: (AMSTray) -> String
    @Binding var selection: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                selection = nil
                dismiss()
            } label: {
                HStack {
                    Text("Keep default")
                    Spacer()
                    if selection == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .foregroundStyle(.primary)

            ForEach(trays) { tray in
                Button {
                    selection = tray.slot
                    dismiss()
                } label: {
                    HStack {
                        ColorSwatch(hex: tray.trayColor)
                        Text(trayLabel(tray))
                        Spacer()
                        if selection == tray.slot {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("AMS Tray")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ColorSwatch: View {
    let hex: String

    var body: some View {
        Circle()
            .fill(Color(uiColor: UIColor(hex: hex) ?? .systemGray4))
            .frame(width: 12, height: 12)
    }
}

private struct PlateThumbnailView: View {
    let dataURL: String

    var body: some View {
        if let image = decodeImage(from: dataURL) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func decodeImage(from raw: String) -> UIImage? {
        guard !raw.isEmpty else {
            return nil
        }

        let payload: String
        if let commaIndex = raw.firstIndex(of: ",") {
            payload = String(raw[raw.index(after: commaIndex)...])
        } else {
            payload = raw
        }

        guard let data = Data(base64Encoded: payload) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private extension UTType {
    static let threeMF = UTType(importedAs: "org.3mfproject.3mf")
}

extension UIColor {
    convenience init?(hex: String) {
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let trimmed = clean.count >= 6 ? String(clean.prefix(6)) : ""
        guard trimmed.count == 6,
              let value = UInt64(trimmed, radix: 16) else {
            return nil
        }

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
