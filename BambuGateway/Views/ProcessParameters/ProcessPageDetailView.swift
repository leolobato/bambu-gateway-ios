import SwiftUI

struct ProcessPageDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let page: ProcessPage

    @State private var editingOptionKey: String?

    var body: some View {
        List {
            ForEach(page.optgroups, id: \.label) { group in
                Section {
                    ForEach(group.options, id: \.self) { key in
                        if let option = viewModel.processOptionsStore.catalogue?.options[key] {
                            ProcessOptionRow(
                                label: option.label,
                                value: resolvedValue(forKey: key, option: option),
                                sidetext: option.sidetext,
                                status: status(forKey: key),
                                showsTooltip: true,
                                tooltip: option.tooltip,
                                action: { editingOptionKey = key }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    Text(group.label.uppercased())
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(page.label)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: editingOptionBinding) { key in
            editorSheet(forKey: key.id)
        }
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

    private func status(forKey key: String) -> ProcessOptionRow.Status {
        if !viewModel.processOptionsStore.allowlistedKeys.contains(key) { return .readOnly }
        if viewModel.processOverrides[key] != nil { return .userEdited }
        if viewModel.parsedInfo?.processModifications?.values[key] != nil { return .threeMFModified }
        return .unmodified
    }

    private func resolvedValue(forKey key: String, option: ProcessOption) -> String {
        resolveProcessValue(
            key: key,
            option: option,
            modifications: viewModel.parsedInfo?.processModifications,
            baseline: viewModel.processBaseline,
            overrides: viewModel.processOverrides
        )
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
                initialValue: resolvedValue(forKey: key, option: option),
                onSave: { newValue in viewModel.setProcessOverride(key: key, value: newValue) },
                onRevert: { viewModel.revertProcessOverride(key: key) }
            )
        }
    }
}
