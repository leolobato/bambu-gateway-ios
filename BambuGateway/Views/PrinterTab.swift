import SwiftUI

struct PrinterTab: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var isShowingSettings = false
    @State private var isShowingSpeedPicker = false

    @AppStorage("bambu_gateway_ios.dashboard.amsExpanded")
    private var isAMSExpanded: Bool = true

    @AppStorage("bambu_gateway_ios.dashboard.externalSpoolExpanded")
    private var isExternalSpoolExpanded: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    printerSection
                    heroSection
                    printingControls
                    if !isSelectedPrinterOffline {
                        amsSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color.dashboardBackground)
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
        .sheet(isPresented: $isShowingSpeedPicker) {
            if let printer = viewModel.selectedPrinter {
                let currentLevel = SpeedLevel(rawValue: printer.speedLevel) ?? .standard
                SpeedPickerSheet(currentLevel: currentLevel) { level in
                    await viewModel.setSpeed(level)
                }
            }
        }
    }

    private var isSelectedPrinterOffline: Bool {
        guard let printer = viewModel.selectedPrinter else { return false }
        return !printer.online
    }

    // MARK: - Printer Picker

    @ViewBuilder
    private var printerSection: some View {
        if viewModel.printers.isEmpty {
            Text("No printers available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else if !viewModel.shouldAutoUseSinglePrinter {
            HStack {
                Text("Printer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
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
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private var heroSection: some View {
        if let printer = viewModel.selectedPrinter {
            if !printer.online {
                PrinterOfflineCard(
                    printer: printer,
                    isRetrying: viewModel.isLoading
                ) {
                    Task {
                        await viewModel.refreshAll()
                    }
                }
            } else if let job = printer.job {
                PrintProgressCard(printer: printer, job: job)
            } else {
                PrinterStatusCard(printer: printer)
            }
        }
    }

    // MARK: - Printing Controls (status row + buttons)

    @ViewBuilder
    private var printingControls: some View {
        if let printer = viewModel.selectedPrinter, printer.online {
            let state = printer.state.lowercased()
            if state == "printing" || state == "paused" {
                StatusRow(
                    temperatures: printer.temperatures,
                    speedLevel: SpeedLevel(rawValue: printer.speedLevel) ?? .standard,
                    isSpeedChangeInFlight: viewModel.isSpeedChangeInFlight,
                    isShowingSpeedPicker: $isShowingSpeedPicker
                )

                PrintControlsRow(
                    state: printer.state,
                    onPause: { await viewModel.pausePrint() },
                    onResume: { await viewModel.resumePrint() },
                    onCancel: { await viewModel.cancelPrint() }
                )
            }
        }
    }

    // MARK: - AMS Section

    @ViewBuilder
    private var amsSection: some View {
        let hasAMS = !viewModel.amsTrays.isEmpty
        let hasVT = viewModel.vtTray != nil

        if !hasAMS && !hasVT {
            HStack {
                Text("AMS")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.top, 8)

            Text("No AMS or external spool detected")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if hasAMS {
            ForEach(viewModel.amsUnits) { unit in
                amsSectionHeader(unit: unit)

                if isAMSExpanded {
                    let unitTrays = viewModel.amsTrays.filter { $0.amsId == unit.id }
                    VStack(spacing: 6) {
                        ForEach(unitTrays) { tray in
                            AMSTrayCard(
                                tray: tray,
                                label: "Tray \(tray.trayId + 1)",
                                selectedProfileName: resolvedProfileName(for: tray.slot),
                                isInUse: activeTraySlot == tray.slot
                            ) {
                                FilamentPickerView(
                                    filaments: viewModel.amsAssignableFilaments,
                                    selection: Binding(
                                        get: { viewModel.trayProfileSelection(for: tray.slot) },
                                        set: { viewModel.setTrayProfileSelection(slot: tray.slot, settingId: $0) }
                                    )
                                )
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }

        if let vtTray = viewModel.vtTray {
            externalSpoolSectionHeader

            if isExternalSpoolExpanded {
                AMSTrayCard(
                    tray: vtTray,
                    label: "External",
                    selectedProfileName: resolvedProfileName(for: vtTray.slot),
                    isInUse: activeTraySlot == vtTray.slot
                ) {
                    FilamentPickerView(
                        filaments: viewModel.amsAssignableFilaments,
                        selection: Binding(
                            get: { viewModel.trayProfileSelection(for: vtTray.slot) },
                            set: { viewModel.setTrayProfileSelection(slot: vtTray.slot, settingId: $0) }
                        )
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var activeTraySlot: Int? {
        guard let printer = viewModel.selectedPrinter else { return nil }
        let state = printer.state.lowercased()
        guard state == "printing" || state == "paused" else { return nil }
        return printer.activeTray
    }

    private func resolvedProfileName(for slot: Int) -> String? {
        let selectedId = viewModel.trayProfileSelection(for: slot)
        guard !selectedId.isEmpty else { return nil }
        let profile = viewModel.amsAssignableFilaments.first(where: { $0.settingId == selectedId })
            ?? viewModel.slicerFilaments.first(where: { $0.settingId == selectedId })
        return profile?.name
    }

    private func amsSectionHeader(unit: AMSUnit) -> some View {
        Button {
            toggle(binding: $isAMSExpanded)
        } label: {
            HStack(spacing: 8) {
                Text("AMS \(unit.id + 1)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                if unit.hasHumiditySensor && unit.humidity >= 0 {
                    Label("\(unit.humidity)%", systemImage: "humidity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                disclosureChevron(isExpanded: isAMSExpanded)
            }
            .contentShape(.rect)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("AMS \(unit.id + 1)")
        .accessibilityValue(isAMSExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isAMSExpanded ? "Double-tap to collapse" : "Double-tap to expand")
    }

    private var externalSpoolSectionHeader: some View {
        Button {
            toggle(binding: $isExternalSpoolExpanded)
        } label: {
            HStack(spacing: 8) {
                Text("External Spool")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                disclosureChevron(isExpanded: isExternalSpoolExpanded)
            }
            .contentShape(.rect)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("External Spool")
        .accessibilityValue(isExternalSpoolExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExternalSpoolExpanded ? "Double-tap to collapse" : "Double-tap to expand")
    }

    private func disclosureChevron(isExpanded: Bool) -> some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
    }

    private func toggle(binding: Binding<Bool>) {
        if reduceMotion {
            binding.wrappedValue.toggle()
        } else {
            withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                binding.wrappedValue.toggle()
            }
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
