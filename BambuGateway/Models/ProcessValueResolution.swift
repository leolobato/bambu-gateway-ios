import Foundation

enum ProcessValueSource: Equatable {
    case threeMF
    case systemDefault
}

struct ProcessRevertTarget: Equatable {
    let value: String
    let source: ProcessValueSource
}

/// Effective value rendered in both Modified card and All view.
/// Resolution order: user override > 3MF customization > resolved profile baseline > catalogue default.
func resolveProcessValue(
    key: String,
    option: ProcessOption?,
    modifications: ProcessModifications?,
    baseline: [String: String],
    overrides: [String: String]
) -> String {
    if let user = overrides[key] { return user }
    if let mod = modifications?.values[key] { return mod }
    if let base = baseline[key] { return base }
    return option?.default ?? ""
}

/// The value Revert should restore, plus a hint at where it came from
/// (used by the editor footer to label "From file" vs "Default").
func revertTargetForProcessValue(
    key: String,
    option: ProcessOption?,
    modifications: ProcessModifications?,
    baseline: [String: String]
) -> ProcessRevertTarget {
    if let mod = modifications?.values[key] {
        return ProcessRevertTarget(value: mod, source: .threeMF)
    }
    if let base = baseline[key] {
        return ProcessRevertTarget(value: base, source: .systemDefault)
    }
    return ProcessRevertTarget(value: option?.default ?? "", source: .systemDefault)
}
