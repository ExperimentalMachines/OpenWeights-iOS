import Foundation
import Combine
import OpenWeightsCore

@MainActor final class MemoryController: ObservableObject {
    @Published private(set) var facts: [RememberedFact] = []
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var readEnabled: Bool { didSet { defaults.set(readEnabled, forKey: "memory.readEnabled") } }
    @Published var writeEnabled: Bool { didSet { defaults.set(writeEnabled, forKey: "memory.writeEnabled") } }
    let store: MemoryStore
    let tools: MemoryTools
    private let defaults: UserDefaults

    init(store: MemoryStore, defaults: UserDefaults = .standard) {
        self.store = store; self.tools = MemoryTools(store: store); self.defaults = defaults
        readEnabled = defaults.bool(forKey: "memory.readEnabled")
        writeEnabled = defaults.bool(forKey: "memory.writeEnabled")
    }
    var toolSettings: MemoryToolSettings {
        var settings = MemoryToolSettings(); settings.readEnabled = readEnabled; settings.writeEnabled = writeEnabled
        return settings
    }
    var definitions: [AgentToolDefinition] { MemoryToolDefinitions.enabled(toolSettings) }
    func execute(_ call: AgentToolCall, approval: ApprovedToolCall? = nil) async -> ToolResult {
        let result = await tools.execute(call, settings: toolSettings, approval: approval)
        facts = await store.list()
        return result
    }

    func restore() async { facts = await store.list() }

    @discardableResult func save(_ text: String, replacing fact: RememberedFact? = nil) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            if let fact { _ = try await store.replace(id: fact.id, expectedText: fact.text, new: text) }
            else { _ = try await store.remember(text) }
            facts = await store.list()
            return true
        } catch { facts = await store.list(); self.error = error.localizedDescription; return false }
    }

    func delete(_ fact: RememberedFact) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { _ = try await store.forget(id: fact.id); facts = await store.list() }
        catch { facts = await store.list(); self.error = error.localizedDescription }
    }

    func deleteAll() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await store.forgetAll(); facts = await store.list() }
        catch { facts = await store.list(); self.error = error.localizedDescription }
    }
}
