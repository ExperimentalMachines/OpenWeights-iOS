import Foundation
import Combine
import OpenWeightsCore

@MainActor final class DiscoveryController: ObservableObject {
    @Published private(set) var query = HubQuery()
    @Published private(set) var models: [HubModel] = []
    @Published private(set) var busy = false
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var unavailableRuntimes: [HubRuntime] = []
    @Published private(set) var unavailableRepositories: [String] = []
    @Published private(set) var hasMore = false
    private let client: HubDiscoveryClient
    private var cursors: [HubCursor] = []
    private var seenCursors: Set<String> = []
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    init(client: HubDiscoveryClient = HubDiscoveryClient(transport: HubAPITransport())) { self.client = client }
    func search(_ query: HubQuery) {
        operation?.cancel()
        generation = UUID(); self.query = query
        models = []; cursors = []; seenCursors = []; hasMore = false
        unavailableRuntimes = []; unavailableRepositories = []; error = nil; busy = true; loadingMore = false
        fetch(append: false)
    }
    func loadMore() {
        guard !busy, !loadingMore, hasMore else { return }
        loadingMore = true; error = nil
        fetch(append: true)
    }
    func retry() { if !models.isEmpty, hasMore { loadMore() } else { search(query) } }
    func cancel() {
        operation?.cancel(); operation = nil; generation = UUID(); busy = false; loadingMore = false
    }
    private func fetch(append: Bool) {
        let token = generation, query = query, paging = append ? cursors : nil
        operation = Task { [weak self, client] in
            do {
                let page = try await query.shortlistOnly ? client.shortlist(query) : client.search(query, cursors: paging)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.models = HubDiscoveryClient.merged((append ? self.models : []) + page.models)
                self.cursors = page.cursors.filter { self.seenCursors.insert($0.runtime.rawValue + "|" + $0.value).inserted }
                self.hasMore = !self.cursors.isEmpty
                self.unavailableRuntimes = page.unavailableRuntimes
                self.unavailableRepositories = page.unavailableRepositories
                self.busy = false; self.loadingMore = false; self.operation = nil
            } catch {
                guard let self, self.generation == token else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
                self.busy = false; self.loadingMore = false; self.operation = nil
            }
        }
    }
}
