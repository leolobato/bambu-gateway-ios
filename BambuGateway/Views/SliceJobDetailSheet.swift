import SwiftUI

struct SliceJobDetailSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let jobId: String
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    private var job: SliceJob? {
        viewModel.sliceJobs.first(where: { $0.jobId == jobId })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let job {
                    content(for: job)
                } else {
                    missingJob
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Job present

    @ViewBuilder
    private func content(for job: SliceJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero(for: job)
                titleBlock(for: job)
                metadataBlock(for: job)
                if let estimate = job.estimate {
                    PrintEstimationCard(estimate: estimate)
                }
                actions(for: job)
            }
            .padding(16)
        }
        .alert("Delete this slice job?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteSliceJob(jobId: job.jobId)
                    dismiss()
                }
            }
        } message: {
            Text("\(job.filename) and its sliced 3MF will be permanently removed. This can't be undone.")
        }
    }

    @ViewBuilder
    private func hero(for job: SliceJob) -> some View {
        if job.hasThumbnail, let url = viewModel.sliceJobThumbnailURL(for: job.jobId) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                default:
                    heroPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(Color(uiColor: .systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            heroPlaceholder
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .background(Color(uiColor: .systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var heroPlaceholder: some View {
        Image(systemName: "doc.fill")
            .font(.system(size: 48))
            .foregroundStyle(.tertiary)
    }

    private func titleBlock(for job: SliceJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.filename)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(2)
                .truncationMode(.middle)

            let style = SliceJobBadgeStyle.style(for: job.displayStatus)
            Text(SliceJobBadgeStyle.label(for: job))
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(style.background)
                .foregroundStyle(style.foreground)
                .clipShape(Capsule())
                .strikethrough(job.displayStatus == .cancelled)
        }
    }

    private func metadataBlock(for job: SliceJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let printerLabel: String = {
                if let id = job.printerId, !id.isEmpty {
                    return id
                }
                return "—"
            }()
            Label(printerLabel, systemImage: "printer.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(SliceJobRelativeTime.format(job.createdAt),
                  systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if job.displayStatus.isInFlight,
               let phase = job.phase, !phase.isEmpty {
                Label(phase, systemImage: "scissors")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let error = job.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.red)
            }
        }
    }

    @ViewBuilder
    private func actions(for job: SliceJob) -> some View {
        let mutationInFlight = viewModel.sliceJobMutationsInFlight.contains(job.jobId)
        let canPrint = job.displayStatus == .ready && (job.outputSize ?? 0) > 0
        let canCancel = !job.isTerminal

        VStack(spacing: 8) {
            if canPrint {
                Button {
                    Task { await viewModel.printSliceJob(jobId: job.jobId) }
                } label: {
                    actionLabel(title: "Print",
                                systemImage: "printer.fill",
                                inFlight: mutationInFlight,
                                tintOnLight: true)
                }
                .disabled(mutationInFlight || viewModel.selectedPrinterId.isEmpty)
                .background(Color.accentBlue.opacity(viewModel.selectedPrinterId.isEmpty ? 0.4 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if canCancel {
                Button {
                    Task { await viewModel.cancelSliceJob(jobId: job.jobId) }
                } label: {
                    actionLabel(title: "Cancel slice",
                                systemImage: "xmark",
                                inFlight: mutationInFlight)
                }
                .disabled(mutationInFlight)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                showDeleteConfirm = true
            } label: {
                actionLabel(title: "Delete",
                            systemImage: "trash",
                            inFlight: false)
            }
            .disabled(mutationInFlight)
            .background(Color.red.opacity(0.15))
            .foregroundStyle(Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func actionLabel(title: String,
                             systemImage: String,
                             inFlight: Bool,
                             tintOnLight: Bool = false) -> some View {
        HStack(spacing: 8) {
            if inFlight {
                ProgressView().tint(tintOnLight ? .white : Color.accentBlue)
            } else {
                Image(systemName: systemImage)
            }
            Text(title).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: - Job missing

    private var missingJob: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("This slice job is no longer available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
