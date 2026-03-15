import Foundation

struct HealthResponse: Decodable {
    let status: String
}

struct PrinterListResponse: Decodable {
    let printers: [PrinterStatus]
}

struct PrinterStatus: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let machineModel: String
    let online: Bool
    let state: String
    let temperatures: TemperatureInfo
    let job: PrintJob?
}

struct TemperatureInfo: Decodable, Hashable {
    let nozzleTemp: Double
    let nozzleTarget: Double
    let bedTemp: Double
    let bedTarget: Double
}

struct PrintJob: Decodable, Hashable {
    let fileName: String
    let progress: Int
    let remainingMinutes: Int
    let currentLayer: Int
    let totalLayers: Int
}

struct AMSResponse: Decodable {
    let printerId: String
    let trays: [AMSTray]
}

struct AMSTray: Decodable, Identifiable, Hashable {
    var id: Int { slot }

    let slot: Int
    let amsId: Int
    let trayId: Int
    let trayType: String
    let trayColor: String
    let traySubBrands: String
    let filamentId: String
    let matchedFilament: SlicerProfile?
}

struct SlicerProfile: Decodable, Identifiable, Hashable {
    var id: String { settingId }

    let name: String
    let settingId: String
    let filamentId: String?
    let amsAssignable: Bool?
    let printerModel: String?
    let compatiblePrinters: [String]?
}

struct PlateTypeOption: Decodable, Identifiable, Hashable {
    var id: String { value }

    let value: String
    let label: String
}

struct ThreeMFInfo: Decodable {
    let plates: [PlateInfo]
    let filaments: [ProjectFilament]
    let printProfile: PrintProfileInfo
    let printer: PrinterInfo
    let hasGcode: Bool
}

struct PlateInfo: Decodable, Identifiable {
    let id: Int
    let name: String
    let thumbnail: String
}

struct ProjectFilament: Codable, Identifiable, Hashable {
    var id: Int { index }

    let index: Int
    let type: String
    let color: String
    let settingId: String
}

enum FilamentMatchReason: String, Decodable, Hashable {
    case exactFilamentId = "exact_filament_id"
    case typeFallback = "type_fallback"
    case none = "none"
}

struct ProjectFilamentMatch: Decodable, Hashable {
    let index: Int
    let settingId: String
    let type: String
    let color: String
    let resolvedProfile: SlicerProfile?
    let preferredTraySlot: Int?
    let matchReason: FilamentMatchReason
}

struct FilamentMatchRequest: Encodable {
    let printerId: String
    let filaments: [ProjectFilament]
}

struct FilamentMatchResponse: Decodable {
    let printerId: String
    let matches: [ProjectFilamentMatch]
}

struct PrintProfileInfo: Decodable {
    let printSettingsId: String
    let layerHeight: String
}

struct PrinterInfo: Decodable {
    let printerSettingsId: String
    let printerModel: String
    let nozzleDiameter: String
}

struct PrintResponse: Decodable {
    let status: String
    let fileName: String
    let printerId: String
    let wasSliced: Bool
    let settingsTransfer: SettingsTransferInfo?
}

struct SettingsTransferInfo: Decodable {
    let status: String
    let transferred: [TransferredSetting]
}

struct TransferredSetting: Decodable, Hashable {
    let key: String
    let value: String
    let original: String?
}

struct ErrorDetailResponse: Decodable {
    let detail: String
}

struct Imported3MFFile: Equatable {
    let fileName: String
    let data: Data
}

struct FilamentOverrideSelection: Codable, Equatable {
    let profileSettingId: String
    let traySlot: Int?

    enum CodingKeys: String, CodingKey {
        case profileSettingId = "profile_setting_id"
        case traySlot = "tray_slot"
    }
}

struct ProfileOption: Identifiable, Hashable {
    let id: String
    let label: String
}

struct PreviewResult {
    let threeMFData: Data
    let previewId: String
    let fileName: String
}
