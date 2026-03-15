import SwiftUI

struct PrinterTab: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            Form {
                printerSection
                amsSection
            }
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings") {
                        isShowingSettings = true
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await viewModel.refreshAll()
                        }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.isSubmitting)
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(viewModel: viewModel)
        }
    }

    private var printerSection: some View {
        Section {
            if viewModel.printers.isEmpty {
                Text("No printers available")
                    .foregroundStyle(.secondary)
            } else {
                if !viewModel.shouldAutoUseSinglePrinter {
                    Picker("Printer", selection: Binding(
                        get: { viewModel.selectedPrinterId },
                        set: { newValue in
                            Task {
                                await viewModel.onPrinterChanged(newValue)
                            }
                        }
                    )) {
                        Text("Default").tag("")
                        ForEach(viewModel.printers) { printer in
                            Text(printer.online ? printer.name : "\(printer.name) (offline)")
                                .tag(printer.id)
                        }
                    }
                }

                if let printer = viewModel.selectedPrinter {
                    PrinterCardView(printer: printer)
                }
            }
        }
    }

    @ViewBuilder
    private var amsSection: some View {
        let hasAMS = !viewModel.amsTrays.isEmpty
        let hasVT = viewModel.vtTray != nil

        if !hasAMS && !hasVT {
            Section("AMS") {
                Text("No AMS or external spool detected")
                    .foregroundStyle(.secondary)
            }
        }

        if hasAMS {
            ForEach(viewModel.amsUnits) { unit in
                Section {
                    let unitTrays = viewModel.amsTrays.filter { $0.amsId == unit.id }
                    ForEach(unitTrays) { tray in
                        trayRow(tray, label: "Tray \(tray.trayId + 1)")
                    }
                } header: {
                    HStack {
                        Text("AMS \(unit.id + 1)")
                        Spacer()
                        if unit.humidity >= 0 {
                            Label("\(unit.humidity)%", systemImage: "humidity")
                                .font(.caption)
                        }
                    }
                }
            }
        }

        if let vtTray = viewModel.vtTray {
            Section("External Spool") {
                trayRow(vtTray, label: "External")
            }
        }
    }

    private func trayRow(_ tray: AMSTray, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.headline)
                ColorSwatch(hex: tray.trayColor)
                if tray.remain >= 0 {
                    Text("\(tray.remain)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(tray.trayType.isEmpty ? "-" : tray.trayType)
                        .foregroundStyle(.secondary)
                    if !tray.filamentId.isEmpty {
                        Text(tray.filamentId)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            NavigationLink {
                FilamentPickerView(
                    filaments: viewModel.amsAssignableFilaments,
                    selection: Binding(
                        get: { viewModel.trayProfileSelection(for: tray.slot) },
                        set: { viewModel.setTrayProfileSelection(slot: tray.slot, settingId: $0) }
                    )
                )
            } label: {
                let selectedId = viewModel.trayProfileSelection(for: tray.slot)
                let selectedProfile =
                    viewModel.amsAssignableFilaments.first(where: { $0.settingId == selectedId })
                    ?? viewModel.slicerFilaments.first(where: { $0.settingId == selectedId })
                if !selectedId.isEmpty, let profile = selectedProfile {
                    Text(profile.name)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Keep default")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PrinterCardView: View {
    let printer: PrinterStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(printer.name)
                        .font(.headline)
                    if !printer.machineModel.isEmpty {
                        Text(printer.machineModel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                stateBadge
            }

            HStack(spacing: 16) {
                temperatureLabel(
                    icon: "flame",
                    label: "Nozzle",
                    actual: printer.temperatures.nozzleTemp,
                    target: printer.temperatures.nozzleTarget
                )
                temperatureLabel(
                    icon: "square.grid.2x2",
                    label: "Bed",
                    actual: printer.temperatures.bedTemp,
                    target: printer.temperatures.bedTarget
                )
            }
            .font(.caption)

            if let job = printer.job {
                VStack(alignment: .leading, spacing: 4) {
                    if !job.fileName.isEmpty {
                        Text(job.fileName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    ProgressView(value: Double(job.progress), total: 100)
                    HStack {
                        Text("\(job.progress)%")
                        Spacer()
                        if job.totalLayers > 0 {
                            Text("Layer \(job.currentLayer)/\(job.totalLayers)")
                        }
                        if job.remainingMinutes > 0 {
                            Text("\(job.remainingMinutes)m remaining")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var stateBadge: some View {
        Text(printer.state.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.15))
            .foregroundStyle(stateColor)
            .clipShape(Capsule())
    }

    private var stateColor: Color {
        switch printer.state.lowercased() {
        case "idle", "finished":
            return .green
        case "printing", "running":
            return .blue
        case "paused":
            return .orange
        case "error":
            return .red
        default:
            return .gray
        }
    }

    private func temperatureLabel(icon: String, label: String, actual: Double, target: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text("\(label): \(Int(actual))/\(Int(target))°C")
        }
    }
}

struct FilamentPickerView: View {
    let filaments: [SlicerProfile]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    private var filteredFilaments: [SlicerProfile] {
        if searchText.isEmpty {
            return filaments
        }
        return filaments.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if filaments.isEmpty {
                Text("No AMS-assignable filament profiles available")
                    .foregroundStyle(.secondary)
            }

            Button {
                selection = ""
                dismiss()
            } label: {
                HStack {
                    Text("Keep default")
                    Spacer()
                    if selection.isEmpty {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .foregroundStyle(.primary)

            ForEach(filteredFilaments) { filament in
                Button {
                    selection = filament.settingId
                    dismiss()
                } label: {
                    HStack {
                        Text(filament.name)
                        Spacer()
                        if selection == filament.settingId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Filament Profile")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
    }
}
