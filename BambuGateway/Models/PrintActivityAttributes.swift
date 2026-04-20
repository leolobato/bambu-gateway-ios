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
