import Foundation
import Combine

@MainActor
final class ProcessOptionsStore: ObservableObject {
    @Published private(set) var catalogue: ProcessOptionsCatalogue?
    @Published private(set) var layout: ProcessLayout?
    @Published private(set) var allowlistedKeys: Set<String> = []
    @Published private(set) var loadError: Error?
    @Published private(set) var isLoading: Bool = false

    private let client: GatewayClient
    private var catalogueTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?

    init(client: GatewayClient) {
        self.client = client
    }

    func loadCatalogueIfNeeded() async {
        if catalogue != nil { return }
        if let task = catalogueTask {
            await task.value
            return
        }
        let task = Task { [client] in
            isLoading = true
            defer { isLoading = false }
            do {
                let cat = try await client.fetchProcessOptions()
                self.catalogue = cat
                self.loadError = nil
            } catch {
                self.loadError = error
            }
        }
        catalogueTask = task
        await task.value
        catalogueTask = nil
    }

    func loadLayoutIfNeeded() async {
        if layout != nil { return }
        await refreshLayout()
    }

    func refreshLayout() async {
        if let task = layoutTask {
            await task.value
            return
        }
        let task = Task { [client] in
            isLoading = true
            defer { isLoading = false }
            do {
                let next = try await client.fetchProcessLayout()
                self.layout = next
                self.allowlistedKeys = Set(next.pages.flatMap { $0.optgroups.flatMap(\.options) })
                self.loadError = nil
            } catch {
                self.loadError = error
            }
        }
        layoutTask = task
        await task.value
        layoutTask = nil
    }
}
