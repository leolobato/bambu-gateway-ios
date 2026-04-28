import SwiftUI

struct SliceJobsSection: View {
    @ObservedObject var viewModel: AppViewModel
    /// Set by tapping a row; `PrintTab` observes this to present the detail sheet.
    @Binding var selectedJobId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            VStack(spacing: 0) {
                if viewModel.sliceJobs.isEmpty {
                    if viewModel.isLoadingSliceJobs {
                        loadingRow
                    } else {
                        emptyRow
                    }
                } else {
                    ForEach(Array(viewModel.sliceJobs.enumerated()), id: \.element.id) { index, job in
                        if index > 0 {
                            Divider().padding(.leading, 14)
                        }
                        SliceJobRow(viewModel: viewModel, job: job) {
                            selectedJobId = job.jobId
                        }
                    }
                }
            }
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .task {
            await viewModel.runSliceJobsPolling()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Slice jobs")
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            clearFailedButton
            clearCompletedButton
        }
        .padding(.top, 4)
    }

    private var failedCount: Int {
        viewModel.sliceJobs.filter { $0.status == "failed" }.count
    }

    private var terminalCount: Int {
        viewModel.sliceJobs.filter { $0.isTerminal }.count
    }

    private var clearFailedButton: some View {
        Button {
            Task { await viewModel.clearSliceJobs(failedOnly: true) }
        } label: {
            HStack(spacing: 4) {
                if viewModel.clearFailedInFlight {
                    ProgressView().controlSize(.mini)
                }
                Text(failedCount > 0 ? "Clear failed (\(failedCount))" : "Clear failed")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(failedCount > 0 ? Color.red : Color.secondary)
        .disabled(failedCount == 0 || viewModel.clearFailedInFlight)
    }

    private var clearCompletedButton: some View {
        Button {
            Task { await viewModel.clearSliceJobs(failedOnly: false) }
        } label: {
            HStack(spacing: 4) {
                if viewModel.clearCompletedInFlight {
                    ProgressView().controlSize(.mini)
                }
                Text(terminalCount > 0 ? "Clear completed (\(terminalCount))" : "Clear completed")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(terminalCount > 0 ? Color.accentBlue : Color.secondary)
        .disabled(terminalCount == 0 || viewModel.clearCompletedInFlight)
    }

    // MARK: - Empty / loading rows

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Loading slice jobs…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var emptyRow: some View {
        HStack {
            Text("No slice jobs yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

// MARK: - Row

private struct SliceJobRow: View {
    @ObservedObject var viewModel: AppViewModel
    let job: SliceJob
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail
                    title
                    Spacer(minLength: 8)
                    statusPill
                }
                if job.displayStatus.isInFlight {
                    ProgressView(value: progressValue, total: 100)
                        .tint(Color.accentBlue)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var progressValue: Double {
        Double(max(0, min(100, job.progress)))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if job.hasThumbnail, let url = viewModel.sliceJobThumbnailURL(for: job.jobId) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                default:
                    thumbnailPlaceholder
                }
            }
            .frame(width: 56, height: 56)
            .background(Color(uiColor: .systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            thumbnailPlaceholder
                .frame(width: 56, height: 56)
                .background(Color(uiColor: .systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var thumbnailPlaceholder: some View {
        Image(systemName: "doc.fill")
            .font(.system(size: 20))
            .foregroundStyle(.tertiary)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(job.filename)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(metadataLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let error = job.error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            }
        }
    }

    private var metadataLine: String {
        let printer: String
        if let id = job.printerId, !id.isEmpty {
            printer = id
        } else {
            printer = "—"
        }
        let when = SliceJobRelativeTime.format(job.createdAt)
        return "\(printer) · \(when)"
    }

    private var statusPill: some View {
        let style = SliceJobBadgeStyle.style(for: job.displayStatus)
        let label = SliceJobBadgeStyle.label(for: job)
        return Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.background)
            .foregroundStyle(style.foreground)
            .clipShape(Capsule())
            .strikethrough(job.displayStatus == .cancelled)
    }
}

// MARK: - Helpers

enum SliceJobRelativeTime {
    static func format(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}

enum SliceJobBadgeStyle {
    struct Style {
        let background: Color
        let foreground: Color
    }

    static func style(for status: SliceJobDisplayStatus) -> Style {
        switch status {
        case .queued:
            return Style(background: Color.secondary.opacity(0.18), foreground: .secondary)
        case .slicing, .uploading:
            return Style(background: Color.accentBlue.opacity(0.18), foreground: .accentBlue)
        case .ready:
            return Style(background: Color.green.opacity(0.18), foreground: .green)
        case .failed:
            return Style(background: Color.red.opacity(0.18), foreground: .red)
        case .cancelled:
            return Style(background: Color.secondary.opacity(0.18), foreground: .secondary)
        }
    }

    static func label(for job: SliceJob) -> String {
        switch job.displayStatus {
        case .queued: return "Queued"
        case .slicing: return "Slicing \(job.progress)%"
        case .uploading: return "Uploading \(job.progress)%"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}
