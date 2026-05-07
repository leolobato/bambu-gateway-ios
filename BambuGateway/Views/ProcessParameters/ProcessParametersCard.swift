import SwiftUI

struct ProcessParametersCard: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showAllSettings = false
    @State private var editingOptionKey: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !modifiedKeys.isEmpty {
                Divider().opacity(0.3)
                ForEach(modifiedKeys, id: \.self) { key in
                    optionRow(forKey: key)
                    if key != modifiedKeys.last {
                        Divider().opacity(0.3).padding(.leading, 36)
                    }
                }
            } else {
                emptyBody
            }
            showAllButton
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentBlue)
            Text("Process settings")
                .font(.headline)
            Spacer()
            if !modifiedKeys.isEmpty {
                Text("\(modifiedKeys.count) modified")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentBlue.opacity(0.18), in: Capsule())
            }
        }
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
            // Catalogue missing the key — render the raw value read-only.
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
    private var emptyBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No customizations from default profile")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var showAllButton: some View {
        Button {
            showAllSettings = true
        } label: {
            HStack {
                Text("Show all settings")
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TonalButtonStyle(tint: Color.accentBlue))
        .padding(.top, 10)
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
