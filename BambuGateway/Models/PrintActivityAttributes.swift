import Foundation
#if os(iOS)
import ActivityKit
#endif

enum PrinterStateBadge: String, Codable, Hashable {
    case idle
    case preparing
    case printing
    case paused
    case finished
    case cancelled
    case error
    case offline
}

#if os(iOS)
struct PrintActivityAttributes: ActivityAttributes {
    // Static, set once at Activity creation
    let printerId: String
    let printerName: String
    let fileName: String
    let thumbnailData: Data?
    /// True when the user has more than one printer configured. The Live
    /// Activity surfaces the printer name in the status line only when this
    /// is set, since with a single printer the name is just noise.
    let showPrinterName: Bool

    init(
        printerId: String,
        printerName: String,
        fileName: String,
        thumbnailData: Data?,
        showPrinterName: Bool = false
    ) {
        self.printerId = printerId
        self.printerName = printerName
        self.fileName = fileName
        self.thumbnailData = thumbnailData
        self.showPrinterName = showPrinterName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printerId = try c.decode(String.self, forKey: .printerId)
        printerName = try c.decode(String.self, forKey: .printerName)
        fileName = try c.decode(String.self, forKey: .fileName)
        thumbnailData = try c.decodeIfPresent(Data.self, forKey: .thumbnailData)
        showPrinterName = try c.decodeIfPresent(Bool.self, forKey: .showPrinterName) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case printerId, printerName, fileName, thumbnailData, showPrinterName
    }

    struct ContentState: Codable, Hashable {
        var state: PrinterStateBadge
        var stageName: String?
        var progress: Double          // 0.0-1.0
        var remainingMinutes: Int
        var currentLayer: Int
        var totalLayers: Int
        var updatedAt: Date
    }
}
#endif
