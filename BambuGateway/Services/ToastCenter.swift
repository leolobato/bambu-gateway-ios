#if os(iOS)
import Foundation

struct ToastMessage: Identifiable, Equatable {
    let id: UUID
    let title: String
    let body: String
}

@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var current: ToastMessage?

    private var dismissTask: Task<Void, Never>?
    private let visibleDuration: Duration

    init(visibleDuration: Duration = .seconds(4)) {
        self.visibleDuration = visibleDuration
    }

    func show(title: String, body: String) {
        guard !(title.isEmpty && body.isEmpty) else { return }
        dismissTask?.cancel()
        current = ToastMessage(id: UUID(), title: title, body: body)
        dismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.visibleDuration)
            if !Task.isCancelled {
                self.current = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}
#endif
