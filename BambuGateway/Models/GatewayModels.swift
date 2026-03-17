import Foundation

struct HealthResponse: Decodable {
    let status: String
}

struct PrinterListResponse: Decodable {
    let printers: [PrinterStatus]
}

enum SpeedLevel: Int, CaseIterable, Identifiable {
    case silent = 1
    case standard = 2
    case sport = 3
    case ludicrous = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .silent: return "Silent"
        case .standard: return "Standard"
        case .sport: return "Sport"
        case .ludicrous: return "Ludicrous"
        }
    }
}

struct PrinterStatus: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let machineModel: String
    let online: Bool
    let state: String
    let speedLevel: Int
    let temperatures: TemperatureInfo
    let job: PrintJob?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        machineModel = try c.decodeIfPresent(String.self, forKey: .machineModel) ?? ""
        online = try c.decode(Bool.self, forKey: .online)
        state = try c.decode(String.self, forKey: .state)
        speedLevel = try c.decodeIfPresent(Int.self, forKey: .speedLevel) ?? 2
        temperatures = try c.decode(TemperatureInfo.self, forKey: .temperatures)
        job = try c.decodeIfPresent(PrintJob.self, forKey: .job)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, machineModel, online, state, speedLevel, temperatures, job
    }
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

struct AMSUnit: Decodable, Identifiable, Hashable {
    var id: Int
    let humidity: Int
    let temperature: Double
    let trayCount: Int
    let amsType: String?

    /// False only when the type is confirmed to be AMS Lite, which has no humidity sensor.
    var hasHumiditySensor: Bool { amsType != "lite" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        humidity = try c.decodeIfPresent(Int.self, forKey: .humidity) ?? -1
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        trayCount = try c.decodeIfPresent(Int.self, forKey: .trayCount) ?? 0
        amsType = try c.decodeIfPresent(String.self, forKey: .amsType)
    }

    private enum CodingKeys: String, CodingKey {
        case id, humidity, temperature, trayCount, amsType
    }
}

struct AMSResponse: Decodable {
    let printerId: String
    let trays: [AMSTray]
    let units: [AMSUnit]
    let vtTray: AMSTray?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        printerId = try container.decode(String.self, forKey: .printerId)
        trays = try container.decode([AMSTray].self, forKey: .trays)
        units = try container.decodeIfPresent([AMSUnit].self, forKey: .units) ?? []
        vtTray = try container.decodeIfPresent(AMSTray.self, forKey: .vtTray)
    }

    private enum CodingKeys: String, CodingKey {
        case printerId, trays, units, vtTray
    }
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
    let remain: Int
    let matchedFilament: SlicerProfile?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slot = try container.decode(Int.self, forKey: .slot)
        amsId = try container.decode(Int.self, forKey: .amsId)
        trayId = try container.decode(Int.self, forKey: .trayId)
        trayType = try container.decodeIfPresent(String.self, forKey: .trayType) ?? ""
        trayColor = try container.decodeIfPresent(String.self, forKey: .trayColor) ?? ""
        traySubBrands = try container.decodeIfPresent(String.self, forKey: .traySubBrands) ?? ""
        filamentId = try container.decodeIfPresent(String.self, forKey: .filamentId) ?? ""
        remain = try container.decodeIfPresent(Int.self, forKey: .remain) ?? -1
        matchedFilament = try container.decodeIfPresent(SlicerProfile.self, forKey: .matchedFilament)
    }

    private enum CodingKeys: String, CodingKey {
        case slot, amsId, trayId, trayType, trayColor, traySubBrands, filamentId, remain, matchedFilament
    }
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
    let uploadId: String?
}

struct UploadProgressResponse: Decodable {
    let uploadId: String
    let status: String
    let progress: Double
    let bytesSent: Int
    let totalBytes: Int
    let error: String?
}

struct CommandResponse: Decodable {
    let printerId: String
    let command: String
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
