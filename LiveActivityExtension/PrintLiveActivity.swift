import ActivityKit
import SwiftUI
import WidgetKit

struct PrintLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            lockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    thumbnail(data: context.attributes.thumbnailData, size: 36)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.printerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.progress)
                        Text(statusLine(context: context))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(for: context.state.state))
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: iconName(for: context.state.state))
            }
        }
    }

    private func lockScreenView(context: ActivityViewContext<PrintActivityAttributes>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(data: context.attributes.thumbnailData, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(context.attributes.printerName)
                        .font(.headline)
                    Spacer()
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.headline.monospacedDigit())
                }
                if !context.attributes.fileName.isEmpty {
                    Text(context.attributes.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressView(value: context.state.progress)
                    .tint(.white)
                Text(statusLine(context: context))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(data: Data?, size: CGFloat) -> some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.1))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "printer.fill").foregroundStyle(.white.opacity(0.6)))
        }
    }

    private func statusLine(context: ActivityViewContext<PrintActivityAttributes>) -> String {
        let state = context.state
        if let stage = state.stageName, !stage.isEmpty, state.state == .preparing {
            return stage
        }
        switch state.state {
        case .paused: return "Paused"
        case .offline: return "Printer offline"
        case .error: return "Error"
        case .finished: return "Complete"
        case .cancelled: return "Cancelled"
        default:
            var parts: [String] = []
            if state.totalLayers > 0 {
                parts.append("Layer \(state.currentLayer)/\(state.totalLayers)")
            }
            if state.remainingMinutes > 0 {
                parts.append("\(state.remainingMinutes) min left")
            }
            return parts.joined(separator: " · ")
        }
    }

    private func iconName(for state: PrinterStateBadge) -> String {
        switch state {
        case .printing, .preparing: return "printer.fill"
        case .paused: return "pause.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        case .idle: return "printer"
        }
    }
}
