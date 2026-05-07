import Foundation
import Combine

@MainActor
final class ProcessOptionsStore: ObservableObject {
    @Published private(set) var catalogue: ProcessOptionsCatalogue?
    @Published private(set) var layout: ProcessLayout?
    @Published private(set) var allowlistedKeys: Set<String> = []
    @Published private(set) var loadError: Error?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var profileBaselines: [String: [String: String]] = [:]

    private let client: GatewayClient
    private var catalogueTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var profileTasks: [String: Task<[String: String]?, Never>] = [:]

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

    /// Returns the resolved values for a process profile, fetching once and
    /// caching by setting id. Returns nil on failure (caller may retry later).
    func profileValues(for settingId: String) async -> [String: String]? {
        if settingId.isEmpty { return nil }
        if let cached = profileBaselines[settingId] { return cached }
        if let task = profileTasks[settingId] {
            return await task.value
        }
        let task = Task { [client] () -> [String: String]? in
            do {
                let profile = try await client.fetchProcessProfile(settingId: settingId)
                self.profileBaselines[settingId] = profile.values
                return profile.values
            } catch {
                self.loadError = error
                return nil
            }
        }
        profileTasks[settingId] = task
        let result = await task.value
        profileTasks[settingId] = nil
        return result
    }
}
