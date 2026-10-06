import Foundation

public struct AgentToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public struct ApprovedToolCall: Sendable {
    public let ticketID: UUID
    public let displayedCall: AgentToolCall
    public init(displayedCall: AgentToolCall) { self.ticketID = UUID(); self.displayedCall = displayedCall }
}

public struct MemoryToolSettings: Codable, Equatable, Sendable {
    public var readEnabled = false
    public var writeEnabled = false
    public init() {}
}

public struct ToolResult: Equatable, Sendable {
    public let text: String
    public let rejected: Bool
    public let untrustedText: Bool
    public let privateDataRead: Bool
    public let searchEvidence: WebSearchEvidence?
    public let fetchEvidence: WebFetchEvidence?
    public let mediaEvidence: MediaSearchEvidence?
    public init(text: String, rejected: Bool = false, untrustedText: Bool = false, searchEvidence: WebSearchEvidence? = nil, fetchEvidence: WebFetchEvidence? = nil, mediaEvidence: MediaSearchEvidence? = nil, privateDataRead: Bool = false) {
        self.privateDataRead = privateDataRead
        self.text = text; self.rejected = rejected; self.untrustedText = untrustedText; self.searchEvidence = searchEvidence; self.fetchEvidence = fetchEvidence; self.mediaEvidence = mediaEvidence
    }
}

public actor MemoryTools {
    private let store: MemoryStore
    private var consumedApprovals: Set<UUID> = []
    public init(store: MemoryStore) { self.store = store }
    public func execute(_ call: AgentToolCall, settings: MemoryToolSettings, approval: ApprovedToolCall? = nil) async -> ToolResult {
        do {
            guard ["read_memory", "save_memory", "update_memory", "forget_memory"].contains(call.name) else {
                return ToolResult(text: "Unknown memory tool.", rejected: true)
            }
            let writes = call.name != "read_memory"
            guard writes ? settings.writeEnabled : settings.readEnabled else {
                return ToolResult(text: "This memory tool is switched off.", rejected: true)
            }
            guard let arguments = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any] else {
                return ToolResult(text: "Tool arguments must be a JSON object.", rejected: true)
            }
            guard call.name != "read_memory" || arguments.isEmpty else {
                return ToolResult(text: "read_memory requires an empty arguments object. No saved facts were read.", rejected: true)
            }
            if writes {
                guard let approval, approval.displayedCall == call, !consumedApprovals.contains(approval.ticketID) else {
                    return ToolResult(text: "Approve this exact memory tool call before it changes saved facts.", rejected: true)
                }
                consumedApprovals.insert(approval.ticketID)
            }
            func string(_ names: String...) throws -> String {
                for name in names { if let value = arguments[name] as? String { return value } }
                throw MemoryToolArgumentError.missing(names[0])
            }
            let result: String
            switch call.name {
            case "read_memory": result = await store.toolRead()
            case "save_memory": result = try await store.remember(string("fact", "text", "note"))
            case "update_memory": result = try await store.replace(old: string("old", "fact"), new: string("new", "replacement"))
            default: result = try await store.forget(string("fact", "text", "memory"))
            }
            return ToolResult(text: result)
        } catch { return ToolResult(text: error.localizedDescription, rejected: true) }
    }
}

private enum MemoryToolArgumentError: LocalizedError {
    case missing(String)
    var errorDescription: String? {
        switch self { case .missing(let name): return "A string argument named \(name) is required." }
    }
}
