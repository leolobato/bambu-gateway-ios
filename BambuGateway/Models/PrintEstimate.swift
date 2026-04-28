import Foundation

struct PrintEstimate: Codable, Equatable {
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

extension PrintEstimate {
    /// Decode a `PrintEstimate` from a base64-encoded JSON HTTP header value.
    /// Returns `nil` if the header is missing, not valid base64, or doesn't decode as a `PrintEstimate`.
    static func decodeFromHeader(_ value: String?) -> PrintEstimate? {
        guard let value, !value.isEmpty else { return nil }
        guard let data = Data(base64Encoded: value) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(PrintEstimate.self, from: data)
    }
}
