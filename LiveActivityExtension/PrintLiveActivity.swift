#if os(iOS)
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
                    thumbnail(data: context.attributes.thumbnailData, size: 56)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.title2.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(jobTitle(context: context))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.progress)
                        Text(statusLine(context: context))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            } compactLeading: {
                compactImage(
                    state: context.state.state,
                    thumbnailData: context.attributes.thumbnailData
                )
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .monospacedDigit()
            } minimal: {
                compactImage(
                    state: context.state.state,
                    thumbnailData: context.attributes.thumbnailData
                )
            }
        }
    }

    private func lockScreenView(context: ActivityViewContext<PrintActivityAttributes>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnail(data: context.attributes.thumbnailData, size: 84)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(jobTitle(context: context))
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.headline.monospacedDigit())
                }
                ProgressView(value: context.state.progress)
                    .tint(.white)
                Text(statusLine(context: context))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    private func jobTitle(context: ActivityViewContext<PrintActivityAttributes>) -> String {
        let name = context.attributes.fileName
        guard !name.isEmpty else { return context.attributes.printerName }
        let trimmed = (name as NSString).deletingPathExtension
        return trimmed.isEmpty ? name : trimmed
    }

    @ViewBuilder
    private func thumbnail(data: Data?, size: CGFloat) -> some View {
        let radius = max(8, size * 0.14)
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.white.opacity(0.1))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "cube.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white.opacity(0.6))
                )
        }
    }

    private func statusLine(context: ActivityViewContext<PrintActivityAttributes>) -> String {
        let state = context.state
        let core: String
        switch state.state {
        case .paused: core = "Paused"
        case .offline: core = "Printer offline"
        case .error: core = "Error"
        case .finished: core = "Complete"
        case .cancelled: core = "Cancelled"
        default:
            if let stage = state.stageName, !stage.isEmpty {
                if state.remainingMinutes > 0 {
                    core = "\(stage) · \(formattedRemaining(state.remainingMinutes)) left"
                } else {
                    core = stage
                }
            } else if state.remainingMinutes > 0 {
                core = "\(formattedRemaining(state.remainingMinutes)) left"
            } else {
                core = ""
            }
        }

        if context.attributes.showPrinterName {
            let name = context.attributes.printerName
            if !name.isEmpty {
                return core.isEmpty ? name : "\(name) · \(core)"
            }
        }
        return core
    }

    private func formattedRemaining(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return String(format: "%d:%02d", h, m)
    }

    @ViewBuilder
    private func compactImage(state: PrinterStateBadge, thumbnailData: Data?) -> some View {
        if let data = thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            Image(systemName: iconName(for: state))
        }
    }

    private func iconName(for state: PrinterStateBadge) -> String {
        switch state {
        case .printing, .preparing: return "cube.fill"
        case .paused: return "pause.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        case .idle: return "cube"
        }
    }
}
#endif
