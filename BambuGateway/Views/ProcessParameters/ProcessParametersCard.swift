import SwiftUI

struct ProcessParametersCard: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showAllSettings = false
    @State private var editingOptionKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader

            VStack(spacing: 0) {
                if modifiedKeys.isEmpty {
                    emptyRow
                } else {
                    ForEach(modifiedKeys, id: \.self) { key in
                        optionRow(forKey: key)
                        Divider().padding(.leading, 12)
                    }
                }
                if modifiedKeys.isEmpty {
                    Divider().padding(.leading, 14)
                }
                showAllRow
            }
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .task {
            await viewModel.processOptionsStore.loadCatalogueIfNeeded()
            await viewModel.processOptionsStore.loadLayoutIfNeeded()
        }
        .fullScreenCover(isPresented: $showAllSettings) {
            ProcessAllSettingsView(viewModel: viewModel)
        }
        .sheet(item: editingOptionBinding) { key in
            editorSheet(forKey: key.id)
        }
    }

    private var modifiedKeys: [String] {
        viewModel.parsedInfo?.processModifications?.modifiedKeys ?? []
    }

    @ViewBuilder
    private var sectionHeader: some View {
        HStack {
            Text("Process Settings")
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            if !modifiedKeys.isEmpty {
                Text("\(modifiedKeys.count) modified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func optionRow(forKey key: String) -> some View {
        if let option = viewModel.processOptionsStore.catalogue?.options[key] {
            ProcessOptionRow(
                label: option.label,
                value: resolveProcessValue(
                    key: key, option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline,
                    overrides: viewModel.processOverrides
                ),
                sidetext: option.sidetext,
                status: status(forKey: key),
                showsTooltip: false,
                tooltip: nil,
                action: { editingOptionKey = key }
            )
        } else {
            ProcessOptionRow(
                label: key,
                value: viewModel.parsedInfo?.processModifications?.values[key] ?? "",
                sidetext: "",
                status: .readOnly,
                showsTooltip: false,
                tooltip: nil,
                action: { }
            )
        }
    }

    @ViewBuilder
    private var emptyRow: some View {
        HStack {
            Text("No customizations from default profile")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var showAllRow: some View {
        Button {
            showAllSettings = true
        } label: {
            HStack(spacing: 8) {
                Text("Show all settings")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
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

    private func status(forKey key: String) -> ProcessOptionRow.Status {
        if !viewModel.processOptionsStore.allowlistedKeys.contains(key) { return .readOnly }
        if viewModel.processOverrides[key] != nil { return .userEdited }
        return .threeMFModified
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
