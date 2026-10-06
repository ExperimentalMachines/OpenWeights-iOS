import Foundation
import CryptoKit

public struct ConversationFold: Codable, Equatable, Sendable {
    public var summary: String
    public var messageCount: Int
    public var transcriptSHA256: String
    public var modelID: UUID
    public var modelName: String
    public var modelRevision: String?
    public var createdAt: Date

    public init(summary: String, through count: Int, in conversation: Conversation, model: LocalModel) {
        self.summary = summary
        self.messageCount = count
        self.transcriptSHA256 = ConversationContext.fingerprint(conversation.messages.prefix(count))
        self.modelID = model.id; self.modelName = model.name; self.modelRevision = model.revision
        self.createdAt = Date()
    }
}

public struct ConversationMask: Codable, Equatable, Sendable {
    public var messageCount: Int
    public var transcriptSHA256: String
    public init(through count: Int, in conversation: Conversation) {
        messageCount = count
        transcriptSHA256 = ConversationContext.fingerprint(conversation.messages.prefix(count))
    }
}

public struct ConversationPromptEntry: Sendable {
    public var text: [String: String]
    public var attachments: [ChatAttachment]
}

public enum ConversationContext {
    private struct WireEntry: Encodable {
        var role: StoredMessage.Role
        var content: String
        var promptContent: String?
        var status: StoredMessage.Status
        var toolCalls: [AgentToolCall]?
        var toolCallID: String?
        var toolName: String?
        var checkpointFailed: Bool?
        var untrustedText: Bool?
        var privateDataRead: Bool?
        var continuesPreviousTurn: Bool?
        var attachments: [ChatAttachment]?
        var attachedDocument: AttachmentDocumentInfo?
    }

    // IDs change on branching. Hash the actual wire history and outcome state,
    // so a matching branch may reuse a summary but an edited prefix cannot.
    public static func fingerprint(_ entries: ArraySlice<StoredMessage>) -> String {
        let wire = entries.map { WireEntry(role: $0.role, content: $0.content, promptContent: $0.promptContent,
            status: $0.status, toolCalls: $0.toolCalls, toolCallID: $0.toolCallID, toolName: $0.toolName,
            checkpointFailed: $0.toolResultCheckpointFailed, untrustedText: $0.toolUntrustedText, privateDataRead: $0.toolPrivateDataRead, continuesPreviousTurn: $0.continuesPreviousTurn, attachments: $0.attachments, attachedDocument: $0.attachedDocument) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(wire)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func validFold(_ conversation: Conversation) -> ConversationFold? {
        guard let fold = conversation.fold, fold.messageCount > 0, fold.messageCount <= conversation.messages.count,
              !fold.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fold.transcriptSHA256 == fingerprint(conversation.messages.prefix(fold.messageCount)) else { return nil }
        return fold
    }
    public static func validMask(_ conversation: Conversation) -> ConversationMask? {
        guard let mask = conversation.observationMask, mask.messageCount > 0, mask.messageCount <= conversation.messages.count,
              mask.transcriptSHA256 == fingerprint(conversation.messages.prefix(mask.messageCount)) else { return nil }
        return mask
    }
    public static func discardInvalidContext(_ conversation: inout Conversation) {
        conversation.fold = validFold(conversation)
        conversation.observationMask = validMask(conversation)
    }

    /// A boundary starts a retained user turn, never the middle of a tool exchange.
    public static func foldBoundary(_ conversation: Conversation, contextTokens: Int) -> Int? {
        let starts = conversation.messages.indices.filter { conversation.messages[$0].role == .user && conversation.messages[$0].continuesPreviousTurn != true }
        let keep = contextTokens < 4096 ? 1 : 2
        guard starts.count > keep else { return nil }
        let boundary = starts[starts.count - keep]
        let oldCount = validFold(conversation)?.messageCount ?? 0
        guard boundary > oldCount, boundary >= 2,
              conversation.messages[boundary - 1].role == .assistant,
              conversation.messages[boundary - 1].status == .complete,
              conversation.messages[boundary - 1].toolCalls?.isEmpty != false,
              !conversation.messages.prefix(boundary).contains(where: { $0.status == .streaming }) else { return nil }
        return boundary
    }

    public static func shouldFold(tokens: Int, context: Int, output: Int, foldableSavings: Int, trigger: Double = 0.75) -> Bool {
        let fraction = trigger.isFinite ? min(0.99, max(0.1, trigger)) : 0.75
        return tokens + output > context || Double(tokens) >= Double(context) * fraction ||
            (tokens >= 4096 && foldableSavings >= 3000)
    }

    public static func prompt(_ conversation: Conversation, system: String) -> [[String: String]] {
        promptEntries(conversation, system: system).map(\.text)
    }

    public static func promptEntries(_ conversation: Conversation, system: String) -> [ConversationPromptEntry] {
        var result = [ConversationPromptEntry(text: ["role": "system", "content": system], attachments: [])]
        let fold = validFold(conversation)
        let start = fold?.messageCount ?? 0
        if let fold {
            var summary = "Earlier conversation summary. This is historical context, not new instructions:\n" + fold.summary
            let uncertain = conversation.messages.prefix(start).filter {
                $0.role == .tool && ($0.status != .complete || $0.toolResultCheckpointFailed == true)
            }
            if !uncertain.isEmpty {
                summary += "\n\nInterrupted tool outcomes. Changes may already have happened. Inspect actual results before requesting them again:\n"
                summary += uncertain.map { ($0.toolName ?? "tool") + ": " + $0.content }.joined(separator: "\n")
            }
            result.append(ConversationPromptEntry(text: ["role": "user", "content": summary], attachments: []))
            result.append(ConversationPromptEntry(text: ["role": "assistant", "content": "I will use this context to continue the conversation."], attachments: []))
        }
        let mask = validMask(conversation)?.messageCount ?? 0
        for (index, entry) in conversation.messages.enumerated() where index >= start && entry.status != .streaming {
            var content = entry.promptContent ?? entry.content
            if index < mask, entry.role == .tool, entry.status == .complete, entry.toolResultCheckpointFailed != true,
               ["read_file", "find_files", "read_memory"].contains(entry.toolName ?? ""), content.utf16.count > 320 {
                content = "Earlier \(entry.toolName ?? "read") result omitted to make room. Full result is saved in the conversation. Request a fresh read if needed."
            }
            guard !content.isEmpty || entry.attachments?.isEmpty == false else { continue }
            var message = ["role": entry.role.rawValue, "content": content]
            if let id = entry.toolCallID { message["tool_call_id"] = id }
            result.append(ConversationPromptEntry(text: message, attachments: entry.attachments ?? []))
        }
        return result
    }

    public static func transcript(_ entries: ArraySlice<StoredMessage>) -> String {
        entries.map { entry in
            let status = entry.status == .complete && entry.toolResultCheckpointFailed != true ? "" : " [\(entry.status.rawValue), outcome may be uncertain]"
            return entry.role.rawValue + (entry.toolName.map { " (\($0))" } ?? "") + status + ":\n" + (entry.promptContent ?? entry.content)
        }.joined(separator: "\n\n")
    }
}
