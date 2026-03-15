import Foundation

struct PerPrinterSelection: Codable {
    var machineProfileId: String
    var processProfileId: String
    var plateType: String
    var trayProfileBySlot: [Int: String]
    var filamentTrayByIndex: [Int: Int]

    enum CodingKeys: String, CodingKey {
        case machineProfileId
        case processProfileId
        case plateType
        case trayProfileBySlot
        case filamentTrayByIndex
    }

    init(
        machineProfileId: String,
        processProfileId: String,
        plateType: String,
        trayProfileBySlot: [Int: String],
        filamentTrayByIndex: [Int: Int]
    ) {
        self.machineProfileId = machineProfileId
        self.processProfileId = processProfileId
        self.plateType = plateType
        self.trayProfileBySlot = trayProfileBySlot
        self.filamentTrayByIndex = filamentTrayByIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineProfileId = try container.decodeIfPresent(String.self, forKey: .machineProfileId) ?? ""
        processProfileId = try container.decodeIfPresent(String.self, forKey: .processProfileId) ?? ""
        plateType = try container.decodeIfPresent(String.self, forKey: .plateType) ?? ""
        trayProfileBySlot = try container.decodeIfPresent([Int: String].self, forKey: .trayProfileBySlot) ?? [:]
        filamentTrayByIndex = try container.decodeIfPresent([Int: Int].self, forKey: .filamentTrayByIndex) ?? [:]
    }

    static let empty = PerPrinterSelection(
        machineProfileId: "",
        processProfileId: "",
        plateType: "",
        trayProfileBySlot: [:],
        filamentTrayByIndex: [:]
    )
}

struct PersistedSettings: Codable {
    var gatewayBaseURL: String
    var selectedPrinterId: String
    var perPrinter: [String: PerPrinterSelection]

    static let `default` = PersistedSettings(
        gatewayBaseURL: "",
        selectedPrinterId: "",
        perPrinter: [:]
    )
}

final class AppSettingsStore {
    private let defaults: UserDefaults
    private let key = "bambu_gateway_ios.settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedSettings {
        guard let data = defaults.data(forKey: key) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(PersistedSettings.self, from: data)
        } catch {
            return .default
        }
    }

    func save(_ settings: PersistedSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: key)
        } catch {
            defaults.removeObject(forKey: key)
        }
    }
}
