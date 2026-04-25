import Foundation

struct PrintEstimate: Decodable, Equatable {
    let totalFilamentMillimeters: Double?
    let totalFilamentGrams: Double?
    let modelFilamentMillimeters: Double?
    let modelFilamentGrams: Double?
    let prepareSeconds: Int?
    let modelPrintSeconds: Int?
    let totalSeconds: Int?

    var isEmpty: Bool {
        totalFilamentMillimeters == nil
            && totalFilamentGrams == nil
            && modelFilamentMillimeters == nil
            && modelFilamentGrams == nil
            && prepareSeconds == nil
            && modelPrintSeconds == nil
            && totalSeconds == nil
    }
}
