import Foundation

public struct StoredMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public enum Status: String, Codable, Sendable { case streaming, complete, cancelled, failed }
    public let id: UUID
    public var role: Role
    public var content: String
    public var status: Status
    public var createdAt: Date
    public var firstTextMilliseconds: Double?
    public var tokensPerSecond: Double?
    public var promptContent: String?
    public var toolCalls: [AgentToolCall]?
    public var toolCallID: String?
    public var toolName: String?
    public var toolResultCheckpointFailed: Bool?
    public var toolUntrustedText: Bool?
    public var toolPrivateDataRead: Bool?
    public var searchEvidence: WebSearchEvidence?
    public var fetchEvidence: WebFetchEvidence?
    public var researchStep: ResearchStepScope?
    public var mediaEvidence: MediaSearchEvidence?
    public var userQuestion: UserQuestion?
    public var planAfterMessage: TaskPlan?
    public var continuesPreviousTurn: Bool?
    public var attachments: [ChatAttachment]?
    public var attachedDocument: AttachmentDocumentInfo?

    public init(id: UUID = UUID(), role: Role, content: String, status: Status = .complete, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.status = status
        self.createdAt = createdAt
    }
}

public struct Conversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var modelID: UUID?
    public var messages: [StoredMessage]
    public var pinned: Bool
    public var archived: Bool
    public var updatedAt: Date
    public var plan: TaskPlan?
    public var goalPlanReviewID: UUID?
    public var fold: ConversationFold?
    public var observationMask: ConversationMask?

    public init(id: UUID = UUID(), title: String, modelID: UUID? = nil, messages: [StoredMessage] = []) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.messages = messages
        self.pinned = false
        self.archived = false
        self.updatedAt = Date()
    }
}

public enum StoreError: LocalizedError {
    case unsupportedVersion(Int)
    case missingConversation
    case missingMessage
    case invalidBranchPoint
    case invalidTitle
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported conversation store version: \(version)"
        case .missingConversation: return "The conversation no longer exists."
        case .missingMessage: return "The message no longer exists."
        case .invalidBranchPoint: return "Choose a completed message to branch from."
        case .invalidTitle: return "Enter a conversation name."
        }
    }
}

public enum ConversationMetadataEdit: Sendable {
    case title(String)
    case pinned(Bool)
    case archived(Bool)
}

public actor ConversationStore {
    private struct Snapshot: Codable { var version = 1; var conversations: [Conversation] }
    private let file: URL
    private var conversations: [Conversation]

    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else { throw StoreError.unsupportedVersion(snapshot.version) }
            // A process can die between stream checkpoints. Keep the text and expose interruption.
            self.conversations = snapshot.conversations.map { original in
                var conversation = original
                for index in conversation.messages.indices where conversation.messages[index].status == .streaming {
                    conversation.messages[index].status = .cancelled
                    if conversation.messages[index].role == .tool {
                        switch conversation.messages[index].toolName {
                        case "ask_user":
                            conversation.messages[index].content = "This question was interrupted when the app stopped. Answer or skip it to continue. No action will be replayed automatically."
                        case "read_memory", "read_file", "find_files":
                            conversation.messages[index].content = "This tool result was not recorded before the app stopped. Request a fresh read if needed."
                        case "save_memory", "update_memory", "forget_memory":
                            conversation.messages[index].content = "This tool result was not recorded before the app stopped. Its change may already have completed. Inspect saved facts before requesting it again."
                        default:
                            conversation.messages[index].content = "This tool result was not recorded before the app stopped. Its change may already have completed. Inspect the actual result before requesting it again."
                        }
                    }
                }
                return conversation
            }
        } else {
            self.conversations = []
        }
    }

    public func list(archived: Bool = false) -> [Conversation] {
        conversations.filter { $0.archived == archived }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func all() -> [Conversation] { conversations }

    public func conversation(_ id: UUID) throws -> Conversation {
        guard let value = conversations.first(where: { $0.id == id }) else { throw StoreError.missingConversation }
        return value
    }

    @discardableResult public func create(title: String, modelID: UUID? = nil) throws -> Conversation {
        let value = Conversation(title: title, modelID: modelID)
        var next = conversations
        next.append(value)
        try commit(next)
        return value
    }

    public func save(_ conversation: Conversation) throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { throw StoreError.missingConversation }
        var next = conversations
        var updated = conversation
        ConversationContext.discardInvalidContext(&updated)
        updated.updatedAt = Date()
        next[index] = updated
        try commit(next)
    }

    @discardableResult public func updateMetadata(_ id: UUID, edit: ConversationMetadataEdit) throws -> Conversation {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { throw StoreError.missingConversation }
        var next = conversations
        switch edit {
        case .title(let raw):
            let title = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !title.isEmpty else { throw StoreError.invalidTitle }
            if title.count <= 60 { next[index].title = title }
            else {
                let prefix = String(title.prefix(60))
                next[index].title = (prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix) + "…"
            }
        case .pinned(let pinned): next[index].pinned = pinned
        case .archived(let archived): next[index].archived = archived
        }
        // Filing changes must preserve the latest transcript and its activity date.
        try commit(next)
        return next[index]
    }

    public func delete(_ id: UUID) throws {
        guard conversations.contains(where: { $0.id == id }) else { throw StoreError.missingConversation }
        try commit(conversations.filter { $0.id != id })
    }

    @discardableResult public func branch(_ id: UUID, through messageID: UUID) throws -> Conversation {
        let original = try conversation(id)
        guard let index = original.messages.firstIndex(where: { $0.id == messageID }) else { throw StoreError.missingMessage }
        guard original.messages[index].status == .complete else { throw StoreError.invalidBranchPoint }
        var branch = Conversation(title: original.title + " (branch)", modelID: original.modelID)
        branch.messages = Array(original.messages.prefix(index + 1)).map {
            var copy = StoredMessage(role: $0.role, content: $0.content, status: $0.status, createdAt: $0.createdAt)
            copy.firstTextMilliseconds = $0.firstTextMilliseconds
            copy.tokensPerSecond = $0.tokensPerSecond
            copy.promptContent = $0.promptContent
            copy.toolCalls = $0.toolCalls
            copy.toolCallID = $0.toolCallID
            copy.toolName = $0.toolName
            copy.toolResultCheckpointFailed = $0.toolResultCheckpointFailed
            copy.toolUntrustedText = $0.toolUntrustedText
            copy.userQuestion = $0.userQuestion
            copy.planAfterMessage = $0.planAfterMessage
            copy.continuesPreviousTurn = $0.continuesPreviousTurn
            copy.attachments = $0.attachments
            copy.attachedDocument = $0.attachedDocument
            return copy
        }
        branch.plan = index == original.messages.count - 1 ? original.plan : branch.messages.compactMap(\.planAfterMessage).last
        branch.fold = original.fold; branch.observationMask = original.observationMask
        ConversationContext.discardInvalidContext(&branch)
        var next = conversations
        next.append(branch)
        try commit(next)
        return branch
    }

    private func commit(_ next: [Conversation]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(conversations: next))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        // Do not expose an in-memory success if the durable write failed.
        conversations = next
    }
}
