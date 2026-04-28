import SwiftUI
import UniformTypeIdentifiers

struct PrintTab: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var isShowingFileImporter = false
    @State private var isShowingSettings = false
    @State private var selectedSliceJobId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    fileArea

                    if viewModel.isParsing {
                        loadingCard
                    } else if viewModel.hasParsedFile {
                        projectCard

                        if viewModel.needsSlicing {
                            slicingSettingsSection
                        }

                        filamentsSection

                        messageCard
                        uploadCard
                        submitArea
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color.dashboardBackground)
            .navigationTitle("Print")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings") {
                        isShowingSettings = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(viewModel: viewModel)
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
        .sheet(isPresented: $viewModel.showPrintSuccessModal) {
            PrintSuccessModal(
                printerName: viewModel.lastPrintPrinterName,
                estimate: viewModel.lastPrintEstimate,
                onDone: { viewModel.dismissPrintSuccessModal() }
            )
        }
        .sheet(item: $selectedSliceJobId.asIdentifiable) { identifier in
            SliceJobDetailSheet(viewModel: viewModel, jobId: identifier.id)
        }
    }

    // MARK: - File area

    @ViewBuilder
    private var fileArea: some View {
        if viewModel.selectedFile == nil, !viewModel.isGatewayConfigured {
            gatewayEmptyStateCard
        } else if let file = viewModel.selectedFile {
            fileHeaderCard(file: file)
        } else {
            importTilesRow
            SliceJobsSection(
                viewModel: viewModel,
                selectedJobId: $selectedSliceJobId
            )
        }
    }

    private var gatewayEmptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentBlue)
                .padding(.top, 4)

            Text("Gateway not configured")
                .font(.headline)

            Text("Set the gateway server address to import 3MF files and submit prints.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isShowingSettings = true
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var importTilesRow: some View {
        HStack(spacing: 10) {
            importTile(
                title: "Files",
                caption: "Import from device",
                systemImage: "folder.fill"
            ) {
                isShowingFileImporter = true
            }
            importTile(
                title: "MakerWorld",
                caption: "Browse & download",
                systemImage: "globe"
            ) {
                viewModel.openMakerWorldBrowser()
            }
        }
    }

    private func importTile(
        title: String,
        caption: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentBlue)
                    .frame(height: 32)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func fileHeaderCard(file: Imported3MFFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentBlue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.clearFile()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove file")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Parsing project…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Project card

    @ViewBuilder
    private var projectCard: some View {
        if let parsedInfo = viewModel.parsedInfo {
            VStack(spacing: 12) {
                sliceStatusBadge

                if let currentPlate = parsedInfo.plates.first(where: { $0.id == viewModel.selectedPlateId }) {
                    PlateThumbnailView(dataURL: currentPlate.thumbnail)
                        .frame(maxWidth: .infinity)
                }

                if viewModel.hasMultiplePlates {
                    HStack {
                        Text("Plate")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Picker("Plate", selection: Binding(
                            get: { viewModel.selectedPlateId },
                            set: { viewModel.selectedPlateId = $0 }
                        )) {
                            ForEach(parsedInfo.plates) { plate in
                                if plate.name.isEmpty {
                                    Text("Plate \(plate.id)").tag(plate.id)
                                } else {
                                    Text("Plate \(plate.id) — \(plate.name)").tag(plate.id)
                                }
                            }
                        }
                        .labelsHidden()
                    }
                    .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var sliceStatusBadge: some View {
        let sliced = viewModel.parsedInfo?.hasGcode ?? false
        let color: Color = sliced ? .green : .orange
        let label = sliced ? "Already sliced" : "Needs slicing"
        let icon = sliced ? "checkmark.circle.fill" : "scissors"

        return HStack {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())

            Spacer()
        }
    }

    // MARK: - Slicing settings

    private var slicingSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Slicing Settings")

            VStack(spacing: 0) {
                profileRow(
                    label: "Machine",
                    selection: Binding(
                        get: { viewModel.selectedMachineProfileId },
                        set: { viewModel.setMachineProfile($0) }
                    ),
                    options: viewModel.machineOptions
                )
                Divider().padding(.leading, 14)
                profileRow(
                    label: "Process",
                    selection: Binding(
                        get: { viewModel.selectedProcessProfileId },
                        set: { viewModel.setProcessProfile($0) }
                    ),
                    options: viewModel.processOptions
                )
                Divider().padding(.leading, 14)
                profileRow(
                    label: "Plate type",
                    selection: Binding(
                        get: { viewModel.selectedPlateType },
                        set: { viewModel.setPlateType($0) }
                    ),
                    options: viewModel.plateTypeOptions
                )
            }
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func profileRow(
        label: String,
        selection: Binding<String>,
        options: [ProfileOption]
    ) -> some View {
        NavigationLink {
            ProfilePickerView(title: label, selection: selection, options: options)
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(currentLabel(for: selection.wrappedValue, in: options))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func currentLabel(for id: String, in options: [ProfileOption]) -> String {
        options.first(where: { $0.id == id })?.label ?? "—"
    }

    // MARK: - Filaments

    @ViewBuilder
    private var filamentsSection: some View {
        if let parsedInfo = viewModel.parsedInfo, !parsedInfo.filaments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Filaments")

                VStack(spacing: 6) {
                    ForEach(parsedInfo.filaments, id: \.index) { filament in
                        filamentRow(for: filament)
                    }
                }
            }
        }
    }

    private func filamentRow(for filament: ProjectFilament) -> some View {
        let selectedSlot = viewModel.filamentTraySelection(for: filament.index)
        let tray = selectedSlot.flatMap { slot in
            viewModel.allAvailableTrays.first(where: { $0.slot == slot })
        }

        return NavigationLink {
            TrayPickerView(
                trays: viewModel.allAvailableTrays,
                trayLabel: { trayPickerLabel(for: $0) },
                selection: Binding(
                    get: { viewModel.filamentTraySelection(for: filament.index) },
                    set: { viewModel.setFilamentTraySelection(index: filament.index, slot: $0) }
                )
            )
        } label: {
            HStack(spacing: 12) {
                ColorSwatch(hex: filament.color, size: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(filamentTitle(for: filament))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !filament.type.isEmpty {
                        Text(filament.type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    trayAssignmentLabel(tray: tray)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func filamentTitle(for filament: ProjectFilament) -> String {
        if filament.settingId.isEmpty {
            return "Filament \(filament.index)"
        }
        return "\(filament.index): \(filament.settingId)"
    }

    @ViewBuilder
    private func trayAssignmentLabel(tray: AMSTray?) -> some View {
        if let tray {
            HStack(spacing: 5) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ColorSwatch(hex: tray.trayColor, size: 10)
                Text(trayShortLabel(for: tray))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentBlue)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text("Keep default")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func trayShortLabel(for tray: AMSTray) -> String {
        if tray.slot == 254 {
            return "External spool"
        }
        if viewModel.amsUnits.count > 1 {
            return "AMS \(tray.amsId + 1) · Tray \(tray.trayId + 1)"
        }
        return "Tray \(tray.trayId + 1)"
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

    // MARK: - Message

    @ViewBuilder
    private var messageCard: some View {
        if !viewModel.message.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: messageIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(messageColor)
                    .padding(.top, 2)

                Text(viewModel.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(messageColor.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(messageColor.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var messageIcon: String {
        switch viewModel.messageLevel {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var messageColor: Color {
        switch viewModel.messageLevel {
        case .info: return Color.accentBlue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - Upload progress

    @ViewBuilder
    private var uploadCard: some View {
        if let progress = viewModel.uploadProgress {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        viewModel.isCancellingUpload ? "Cancelling…" : "Uploading to printer",
                        systemImage: "arrow.up.circle.fill"
                    )
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
        }
    }

    // MARK: - Submit area

    @ViewBuilder
    private var submitArea: some View {
        if viewModel.hasStartedPrintForCurrentSelection {
            Text("Print already started for this selection. Clear the file or change the print settings to submit again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(spacing: 8) {
                Button {
                    Task { await viewModel.submitPreview() }
                } label: {
                    submitButtonLabel(
                        title: "Preview",
                        systemImage: "eye.fill",
                        isBusy: viewModel.isLoadingPreview,
                        slicingProgress: viewModel.isLoadingPreview ? viewModel.slicingProgress : nil
                    )
                }
                .buttonStyle(TonalButtonStyle(tint: Color.accentBlue))
                .disabled(!canSubmit)

                Button {
                    Task { await viewModel.submitPrint() }
                } label: {
                    submitButtonLabel(
                        title: "Print",
                        systemImage: "printer.fill",
                        isBusy: viewModel.isSubmitting,
                        slicingProgress: viewModel.isSubmitting ? viewModel.slicingProgress : nil,
                        spinnerOnLight: true
                    )
                }
                .buttonStyle(FilledButtonStyle(tint: Color.accentBlue))
                .disabled(!canSubmit)

                if let phase = currentSlicingPhase {
                    Text(phase)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                }
            }
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.2), value: currentSlicingPhase)
        }
    }

    /// Slicing phase string when a slice job is currently in flight for the
    /// active Preview or Print submission. Hidden once the job settles.
    private var currentSlicingPhase: String? {
        guard viewModel.isLoadingPreview || viewModel.isSubmitting else { return nil }
        guard let phase = viewModel.slicingPhase, !phase.isEmpty else { return nil }
        return phase
    }

    private func submitButtonLabel(
        title: String,
        systemImage: String,
        isBusy: Bool,
        slicingProgress: Int? = nil,
        spinnerOnLight: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .tint(spinnerOnLight ? .white : Color.accentBlue)
            } else {
                Image(systemName: systemImage)
            }
            if let percent = slicingProgress {
                Text("Slicing \(percent)%")
                    .fontWeight(.semibold)
            } else {
                Text(title)
                    .fontWeight(.semibold)
            }
        }
    }

    private var canSubmit: Bool {
        viewModel.hasParsedFile && !viewModel.isSubmitting && !viewModel.isLoadingPreview
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Button styles

private struct FilledButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct TonalButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.15))
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

// MARK: - Profile picker

private struct ProfilePickerView: View {
    let title: String
    @Binding var selection: String
    let options: [ProfileOption]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(options) { option in
                Button {
                    selection = option.id
                    dismiss()
                } label: {
                    HStack {
                        Text(option.label)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection == option.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Tray picker

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

// MARK: - Shared helpers

struct ColorSwatch: View {
    let hex: String
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color(uiColor: UIColor(hex: hex) ?? .systemGray4))
            .frame(width: size, height: size)
    }
}

private struct PlateThumbnailView: View {
    let dataURL: String

    var body: some View {
        if let image = decodeImage(from: dataURL) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
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

private struct SliceJobIdentifier: Identifiable, Hashable {
    let id: String
}

private extension Binding where Value == String? {
    /// Bridges `String?` state to `.sheet(item:)`, which needs the wrapped
    /// value to be `Identifiable`. Extracted to a helper so the surrounding
    /// `body` keeps a small, fast-to-type-check expression.
    var asIdentifiable: Binding<SliceJobIdentifier?> {
        Binding<SliceJobIdentifier?>(
            get: { wrappedValue.map { SliceJobIdentifier(id: $0) } },
            set: { wrappedValue = $0?.id }
        )
    }
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
