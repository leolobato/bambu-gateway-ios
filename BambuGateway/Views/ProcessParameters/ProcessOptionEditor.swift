import SwiftUI

struct ProcessOptionEditor: View {
    let option: ProcessOption
    let revertTarget: ProcessRevertTarget
    /// Current effective value — may equal revertTarget.value (no user edit yet)
    /// or the user's prior override.
    let initialValue: String
    /// Called on Save with the stringified value to write into processOverrides.
    let onSave: (String) -> Void
    /// Called on Revert (removes the key from processOverrides).
    let onRevert: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                if !option.tooltip.isEmpty {
                    Section {
                        Text(option.tooltip)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    editorWidget
                    if let error = validationError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let range = rangeHint {
                        Text(range)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(option.label)
                }

                Section {
                    HStack {
                        Button {
                            onRevert()
                            dismiss()
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .disabled(draft == revertTarget.value)

                        Spacer()

                        Text(footerLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(option.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let parsed = validatedValue() {
                            onSave(parsed)
                            dismiss()
                        }
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear { draft = initialValue }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Per-type widget

    @ViewBuilder
    private var editorWidget: some View {
        switch option.type {
        case .bool:
            Toggle(isOn: Binding(
                get: { draft == "1" },
                set: { draft = $0 ? "1" : "0" }
            )) { EmptyView() }
                .tint(Color.accentBlue)

        case .int, .ints:
            HStack {
                TextField(option.sidetext, text: $draft)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Text(option.sidetext).foregroundStyle(.secondary)
            }

        case .float, .floats:
            HStack {
                TextField(option.sidetext, text: $draft)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Text(option.sidetext).foregroundStyle(.secondary)
            }

        case .percent, .percents:
            HStack {
                TextField("0", text: Binding(
                    get: { draft.replacingOccurrences(of: "%", with: "") },
                    set: { draft = $0.isEmpty ? "" : "\($0)%" }
                ))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                Text("%").foregroundStyle(.secondary)
            }

        case .floatOrPercent, .floatsOrPercents:
            HStack {
                Picker("", selection: floatOrPercentBinding) {
                    Text(option.sidetext).tag(false)
                    Text("%").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                TextField("", text: floatOrPercentNumericBinding)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }

        case .string, .strings:
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

        case .enum:
            Picker(option.label, selection: $draft) {
                ForEach(Array(zip(option.enumValues ?? [], displayLabels).enumerated()), id: \.offset) { _, pair in
                    Text(pair.1).tag(pair.0)
                }
            }
            .pickerStyle(.menu)

        case .point, .points, .point3, .bools, .none:
            VStack(alignment: .leading, spacing: 8) {
                Text(initialValue.isEmpty ? "—" : initialValue)
                    .font(.body.monospaced())
                Text("Editing this option type is not yet supported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayLabels: [String] {
        if let labels = option.enumLabels, !labels.isEmpty { return labels }
        return option.enumValues ?? []
    }

    private var floatOrPercentBinding: Binding<Bool> {
        Binding(
            get: { draft.hasSuffix("%") },
            set: { isPercent in
                let stripped = draft.replacingOccurrences(of: "%", with: "")
                draft = isPercent ? "\(stripped)%" : stripped
            }
        )
    }

    private var floatOrPercentNumericBinding: Binding<String> {
        Binding(
            get: { draft.replacingOccurrences(of: "%", with: "") },
            set: { newValue in
                draft = draft.hasSuffix("%") ? "\(newValue)%" : newValue
            }
        )
    }

    private var rangeHint: String? {
        switch (option.min, option.max) {
        case let (lo?, hi?): return "Range \(lo)–\(hi)\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
        case let (lo?, nil): return "Min \(lo)\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
        case let (nil, hi?): return "Max \(hi)\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
        default: return nil
        }
    }

    private var footerLabel: String {
        let suffix = option.sidetext.isEmpty ? "" : " \(option.sidetext)"
        switch revertTarget.source {
        case .threeMF: return "From file: \(revertTarget.value)\(suffix)"
        case .systemDefault: return "Default: \(revertTarget.value)\(suffix)"
        }
    }

    // MARK: - Validation

    private var isValid: Bool { validatedValue() != nil }

    private func validatedValue() -> String? {
        switch option.type {
        case .bool:
            return (draft == "1" || draft == "0") ? draft : nil
        case .int, .ints:
            guard let i = Int(draft.trimmingCharacters(in: .whitespaces)) else {
                validationError = "Enter a whole number."
                return nil
            }
            if let lo = option.min, Double(i) < lo {
                validationError = "Must be ≥ \(Int(lo))\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
                return nil
            }
            if let hi = option.max, Double(i) > hi {
                validationError = "Must be ≤ \(Int(hi))\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
                return nil
            }
            validationError = nil
            return String(i)
        case .float, .floats:
            guard let d = Double(draft.replacingOccurrences(of: ",", with: ".")) else {
                validationError = "Enter a decimal number."
                return nil
            }
            if let lo = option.min, d < lo { validationError = "Must be ≥ \(lo)"; return nil }
            if let hi = option.max, d > hi { validationError = "Must be ≤ \(hi)"; return nil }
            validationError = nil
            return draft
        case .percent, .percents:
            let stripped = draft.replacingOccurrences(of: "%", with: "")
            guard !stripped.isEmpty, Double(stripped) != nil else {
                validationError = "Enter a percent value."
                return nil
            }
            validationError = nil
            return draft.hasSuffix("%") ? draft : "\(stripped)%"
        case .floatOrPercent, .floatsOrPercents:
            let stripped = draft.replacingOccurrences(of: "%", with: "")
            guard !stripped.isEmpty, Double(stripped) != nil else {
                validationError = "Enter a number."
                return nil
            }
            validationError = nil
            return draft
        case .string, .strings:
            validationError = nil
            return draft
        case .enum:
            guard option.enumValues?.contains(draft) == true else {
                validationError = "Select a value."
                return nil
            }
            validationError = nil
            return draft
        case .point, .points, .point3, .bools, .none:
            return nil
        }
    }
}
