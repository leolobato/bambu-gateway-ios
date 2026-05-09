import SwiftUI

struct ProcessParametersCard: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var editingOptionKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader

            if modifiedKeys.isEmpty {
                VStack(spacing: 0) {
                    emptyRow
                    Divider().padding(.leading, 14)
                    showAllRow
                }
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groupedKeys, id: \.page) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.page.uppercased())
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            VStack(spacing: 0) {
                                ForEach(Array(group.keys.enumerated()), id: \.element) { index, key in
                                    if index > 0 {
                                        Divider().padding(.leading, 12)
                                    }
                                    optionRow(forKey: key)
                                }
                            }
                            .background(Color.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    showAllRow
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task {
            await viewModel.processOptionsStore.loadCatalogueIfNeeded()
            await viewModel.processOptionsStore.loadLayoutIfNeeded()
        }
        .sheet(item: editingOptionBinding) { key in
            editorSheet(forKey: key.id)
        }
    }

    // 3MF-authored modifications first (preserving the project's own
    // ordering), then any session overrides the user has added on top —
    // sorted to keep the list stable across edits. The status badge on
    // each row distinguishes the two sources visually.
    private var modifiedKeys: [String] {
        let fromFile = viewModel.parsedInfo?.processModifications?.modifiedKeys ?? []
        let fileSet = Set(fromFile)
        let userOnly = viewModel.processOverrides.keys
            .filter { !fileSet.contains($0) }
            .sorted()
        return fromFile + userOnly
    }

    /// Bucket `modifiedKeys` by their parent page (Quality / Strength / …)
    /// in layout order so the card mirrors the All-sheet drill-down. Keys
    /// the layout doesn't know about land in a trailing "Other" group so
    /// nothing is dropped.
    private var groupedKeys: [(page: String, keys: [String])] {
        guard let layout = viewModel.processOptionsStore.layout else {
            return modifiedKeys.isEmpty ? [] : [(page: "Other", keys: modifiedKeys)]
        }
        var pageByKey: [String: String] = [:]
        for page in layout.pages {
            for group in page.optgroups {
                for key in group.options { pageByKey[key] = page.label }
            }
        }
        var buckets: [String: [String]] = [:]
        for key in modifiedKeys {
            let page = pageByKey[key] ?? "Other"
            buckets[page, default: []].append(key)
        }
        var ordered: [(page: String, keys: [String])] = []
        for page in layout.pages {
            if let keys = buckets[page.label], !keys.isEmpty {
                ordered.append((page: page.label, keys: keys))
            }
        }
        if let others = buckets["Other"], !others.isEmpty {
            ordered.append((page: "Other", keys: others))
        }
        return ordered
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
                value: displayProcessValue(
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
        NavigationLink {
            ProcessAllSettingsView(viewModel: viewModel)
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
