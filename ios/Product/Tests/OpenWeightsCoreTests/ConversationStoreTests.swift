import Foundation
import XCTest
@testable import OpenWeightsCore

final class ConversationStoreTests: XCTestCase {
    func testUnfinishedToolCheckpointReopensWithExplicitUncertainty() async throws {
        let file = try location()
        let store = try ConversationStore(file: file)
        var conversation = try await store.create(title: "Interrupted tool")
        var tool = StoredMessage(role: .tool, content: "Applying approved change", status: .streaming)
        tool.toolName = "save_memory"; tool.toolCallID = "pending-call"
        conversation.messages = [tool]
        try await store.save(conversation)
        let reopened = try ConversationStore(file: file)
        let uncertain = try await reopened.conversation(conversation.id)
        XCTAssertEqual(uncertain.messages[0].status, .cancelled)
        XCTAssertEqual(uncertain.messages[0].toolCallID, "pending-call")
        XCTAssertTrue(uncertain.messages[0].content.contains("may already have completed"))
        XCTAssertTrue(uncertain.messages[0].content.contains("Inspect saved facts"))
        tool.toolName = "read_memory"
        conversation.messages = [tool]
        try await store.save(conversation)
        let readReopen = try ConversationStore(file: file)
        let read = try await readReopen.conversation(conversation.id)
        XCTAssertTrue(read.messages[0].content.contains("fresh read"))
        XCTAssertFalse(read.messages[0].content.contains("change may"))
    }
    func testToolWireHistorySurvivesReopenBranchAndOlderMessageShape() async throws {
        let file = try location()
        let store = try ConversationStore(file: file)
        var conversation = try await store.create(title: "Memory")
        let call = AgentToolCall(id: "call-1", name: "read_memory", argumentsJSON: "{}")
        var assistant = StoredMessage(role: .assistant, content: "")
        assistant.promptContent = "<tool_call>\n{\"name\":\"read_memory\",\"arguments\":{}}\n</tool_call>"
        assistant.toolCalls = [call]
        var result = StoredMessage(role: .tool, content: "Prefers tea")
        result.toolCallID = call.id; result.toolName = call.name
        result.toolUntrustedText = true
        conversation.messages = [StoredMessage(role: .user, content: "What do I prefer?"), assistant, result]
        try await store.save(conversation)
        let reopened = try ConversationStore(file: file)
        let saved = try await reopened.conversation(conversation.id)
        XCTAssertEqual(saved.messages[1].promptContent, assistant.promptContent)
        XCTAssertEqual(saved.messages[1].toolCalls, [call])
        XCTAssertEqual(saved.messages[2].toolCallID, call.id)
        XCTAssertEqual(saved.messages[2].toolUntrustedText, true)
        let branch = try await reopened.branch(conversation.id, through: result.id)
        XCTAssertNotEqual(branch.messages[2].id, result.id)
        XCTAssertEqual(branch.messages[1].promptContent, assistant.promptContent)
        XCTAssertEqual(branch.messages[2].toolCallID, call.id)
        XCTAssertEqual(branch.messages[2].toolUntrustedText, true)
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var conversations = try XCTUnwrap(snapshot["conversations"] as? [[String: Any]])
        for c in conversations.indices {
            var messages = try XCTUnwrap(conversations[c]["messages"] as? [[String: Any]])
            for m in messages.indices { for key in ["promptContent", "toolCalls", "toolCallID", "toolName", "toolResultCheckpointFailed", "toolUntrustedText"] { messages[m].removeValue(forKey: key) } }
            conversations[c]["messages"] = messages
        }
        snapshot["conversations"] = conversations
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        let legacy = try ConversationStore(file: file)
        let old = try await legacy.conversation(conversation.id)
        XCTAssertNil(old.messages[1].promptContent)
        XCTAssertNil(old.messages[1].toolCalls)
        XCTAssertNil(old.messages[2].toolUntrustedText)
        XCTAssertEqual(old.messages[2].content, "Prefers tea")
    }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("conversations.json")
    }

    func testReopenKeepsPartialTextAndMarksInterruptedStream() async throws {
        let file = try location()
        let store = try ConversationStore(file: file)
        var chat = try await store.create(title: "Workshop")
        chat.messages = [StoredMessage(role: .user, content: "Where?"), StoredMessage(role: .assistant, content: "Osa", status: .streaming)]
        try await store.save(chat)
        let reopened = try ConversationStore(file: file)
        let saved = try await reopened.conversation(chat.id)
        XCTAssertEqual(saved.messages[1].content, "Osa")
        XCTAssertEqual(saved.messages[1].status, .cancelled)
    }

    func testBranchDoesNotMutateOriginalAndAssignsNewMessageIDs() async throws {
        let store = try ConversationStore(file: location())
        var chat = try await store.create(title: "Original")
        chat.messages = [StoredMessage(role: .user, content: "Cedar"), StoredMessage(role: .assistant, content: "Saved"), StoredMessage(role: .user, content: "Osaka")]
        try await store.save(chat)
        let branch = try await store.branch(chat.id, through: chat.messages[1].id)
        XCTAssertEqual(branch.messages.map(\.content), ["Cedar", "Saved"])
        XCTAssertNotEqual(branch.messages[0].id, chat.messages[0].id)
        let original = try await store.conversation(chat.id)
        XCTAssertEqual(original.messages.count, 3)
    }

    func testArchiveAndPinSurviveReopenAndDeleteIsDurable() async throws {
        let file = try location()
        let store = try ConversationStore(file: file)
        var chat = try await store.create(title: "One")
        chat.title = "Renamed"; chat.pinned = true; chat.archived = true
        try await store.save(chat)
        let reopened = try ConversationStore(file: file)
        let active = await reopened.list()
        let archived = await reopened.list(archived: true)
        XCTAssertTrue(active.isEmpty)
        XCTAssertEqual(archived.first?.title, "Renamed")
        XCTAssertEqual(archived.first?.pinned, true)
        try await reopened.delete(chat.id)
        let afterDelete = try ConversationStore(file: file)
        let remaining = await afterDelete.list(archived: true)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMetadataEditsPreserveLatestTranscriptAndActivityAcrossReopen() async throws {
        let file = try location(), store = try ConversationStore(file: file)
        let stale = try await store.create(title: "Original", modelID: UUID())
        var latest = stale
        var message = StoredMessage(role: .assistant, content: "Newer reply")
        message.promptContent = "Serialized newer reply"
        message.toolCalls = [AgentToolCall(id: "latest-call", name: "read_memory", argumentsJSON: "{}")]
        latest.messages = [StoredMessage(role: .user, content: "Newer question"), message]
        try await store.save(latest)
        let durable = try await store.conversation(stale.id)
        let renamed = try await store.updateMetadata(stale.id, edit: .title("  Cedar\n project  "))
        XCTAssertEqual(renamed.title, "Cedar project")
        XCTAssertEqual(renamed.messages, durable.messages)
        XCTAssertEqual(renamed.modelID, durable.modelID)
        XCTAssertEqual(renamed.updatedAt, durable.updatedAt)
        try await store.updateMetadata(stale.id, edit: .pinned(true))
        try await store.updateMetadata(stale.id, edit: .archived(true))
        let reopened = try ConversationStore(file: file)
        let archived = try await reopened.conversation(stale.id)
        XCTAssertTrue(archived.archived); XCTAssertTrue(archived.pinned)
        XCTAssertEqual(archived.messages, durable.messages)
        XCTAssertEqual(archived.updatedAt, durable.updatedAt)
        let restored = try await reopened.updateMetadata(stale.id, edit: .archived(false))
        XCTAssertFalse(restored.archived); XCTAssertTrue(restored.pinned)
        XCTAssertEqual(restored.messages, durable.messages)
    }

    func testMetadataRefusesBlankMissingAndFailedWritesWithoutChangingState() async throws {
        let file = try location(), store = try ConversationStore(file: file)
        let chat = try await store.create(title: "Keep")
        let bytes = try Data(contentsOf: file)
        do { try await store.updateMetadata(chat.id, edit: .title(" \n\t ")); XCTFail("Blank rename accepted") }
        catch StoreError.invalidTitle {} catch { XCTFail("Unexpected error: \(error)") }
        do { try await store.updateMetadata(UUID(), edit: .pinned(true)); XCTFail("Missing conversation accepted") }
        catch StoreError.missingConversation {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await store.updateMetadata(chat.id, edit: .archived(true)); XCTFail("Failed write accepted") } catch {}
        let retained = try await store.conversation(chat.id)
        XCTAssertEqual(retained, chat)
    }

    func testMetadataTitleCollapsesWhitespaceAndBoundsLongNames() async throws {
        let store = try ConversationStore(file: location())
        let chat = try await store.create(title: "Keep")
        let renamed = try await store.updateMetadata(chat.id, edit: .title(String(repeating: "Cedar ", count: 20)))
        XCTAssertEqual(renamed.title, String(repeating: "Cedar ", count: 9) + "Cedar…")
        let unbroken = try await store.updateMetadata(chat.id, edit: .title(String(repeating: "x", count: 100)))
        XCTAssertEqual(unbroken.title, String(repeating: "x", count: 60) + "…")
    }

    func testCorruptionIsReportedWithoutOverwritingEvidence() throws {
        let file = try location()
        let bytes = Data("corrupt".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try ConversationStore(file: file))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testFailedWriteDoesNotAdvanceInMemoryState() async throws {
        let file = try location()
        let store = try ConversationStore(file: file)
        let chat = try await store.create(title: "Keep")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var edit = chat; edit.title = "Must not persist"
        do { try await store.save(edit); XCTFail("Expected filesystem failure") } catch {}
        let retained = try await store.conversation(chat.id)
        XCTAssertEqual(retained.title, "Keep")
    }
}
