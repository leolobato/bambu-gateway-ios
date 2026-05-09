import SwiftUI

struct ProcessAllSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var search: String = ""
    @State private var showResetConfirm = false
    @State private var editingOptionKey: String?

    var body: some View {
        Group {
            if let layout = viewModel.processOptionsStore.layout {
                if search.isEmpty {
                    pageList(layout)
                } else {
                    searchResults(layout)
                }
            } else if viewModel.processOptionsStore.loadError != nil {
                errorView
            } else {
                ProgressView().progressViewStyle(.circular)
            }
        }
        .background(Color.dashboardBackground)
        .navigationTitle("Process settings")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showResetConfirm = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(viewModel.processOverrides.isEmpty)
                .accessibilityLabel("Reset all")
            }
        }
        .confirmationDialog(
            "Reset all process settings?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { viewModel.resetAllProcessOverrides() }
            Button("Cancel", role: .cancel) { }
        }
        .task {
            await viewModel.processOptionsStore.loadCatalogueIfNeeded()
            await viewModel.processOptionsStore.loadLayoutIfNeeded()
        }
        .sheet(item: editingOptionBinding) { key in
            editorSheet(forKey: key.id)
        }
    }

    @ViewBuilder
    private func pageList(_ layout: ProcessLayout) -> some View {
        List {
            ForEach(layout.pages, id: \.label) { page in
                NavigationLink {
                    ProcessPageDetailView(viewModel: viewModel, page: page)
                } label: {
                    pageRow(page)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func pageRow(_ page: ProcessPage) -> some View {
        let total = page.optgroups.flatMap(\.options).count
        let edited = page.optgroups.flatMap(\.options).filter { viewModel.processOverrides[$0] != nil }.count
        HStack {
            Text(page.label)
                .font(.body)
            Spacer()
            HStack(spacing: 6) {
                Text("\(total) options")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if edited > 0 {
                    Text("· \(edited) edited")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func searchResults(_ layout: ProcessLayout) -> some View {
        // Group matches per page in layout order so the results surface
        // mirrors the page-detail view: section header per parent page,
        // matches grouped underneath. Pages with zero matches are skipped.
        let needle = search.lowercased()
        let groups: [(label: String, keys: [String])] = layout.pages.compactMap { page in
            let keys = page.optgroups.flatMap(\.options).filter { key in
                guard let option = viewModel.processOptionsStore.catalogue?.options[key] else { return false }
                return option.label.lowercased().contains(needle) || key.lowercased().contains(needle)
            }
            return keys.isEmpty ? nil : (label: page.label, keys: keys)
        }

        if groups.isEmpty {
            VStack(spacing: 8) {
                Text("No matches for \"\(search)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.dashboardBackground)
        } else {
            List {
                ForEach(groups, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.keys, id: \.self) { key in
                            if let option = viewModel.processOptionsStore.catalogue?.options[key] {
                                ProcessOptionRow(
                                    label: option.label,
                                    value: displayProcessValue(
                                        key: key, option: option,
                                        modifications: viewModel.parsedInfo?.processModifications,
                                        baseline: viewModel.processBaseline,
                                        overrides: viewModel.processOverrides
                                    ),
                                    sidetext: option.sidetext,
                                    status: rowStatus(forKey: key),
                                    showsTooltip: false,
                                    tooltip: nil,
                                    action: { editingOptionKey = key }
                                )
                                .listRowInsets(EdgeInsets())
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private var errorView: some View {
        VStack(spacing: 12) {
            Text("Couldn't load process settings")
                .font(.headline)
            if let error = viewModel.processOptionsStore.loadError {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Retry") {
                Task {
                    await viewModel.processOptionsStore.loadCatalogueIfNeeded()
                    await viewModel.processOptionsStore.refreshLayout()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowStatus(forKey key: String) -> ProcessOptionRow.Status {
        if !viewModel.processOptionsStore.allowlistedKeys.contains(key) { return .readOnly }
        if viewModel.processOverrides[key] != nil { return .userEdited }
        if viewModel.parsedInfo?.processModifications?.values[key] != nil { return .threeMFModified }
        return .unmodified
    }

    private var editingOptionBinding: Binding<IdentifiedKey?> {
        Binding(
            get: { editingOptionKey.map(IdentifiedKey.init) },
            set: { editingOptionKey = $0?.id }
        )
    }

    private struct IdentifiedKey: Identifiable, Equatable {
        let id: String
    }

    @ViewBuilder
    private func editorSheet(forKey key: String) -> some View {
        if let option = viewModel.processOptionsStore.catalogue?.options[key] {
            ProcessOptionEditor(
                option: option,
                revertTarget: revertTargetForProcessValue(
                    key: key,
                    option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline
                ),
                initialValue: resolveProcessValue(
                    key: key, option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline,
                    overrides: viewModel.processOverrides
                ),
                onSave: { newValue in viewModel.setProcessOverride(key: key, value: newValue) },
                onRevert: { viewModel.revertProcessOverride(key: key) }
            )
        }
    }
}
