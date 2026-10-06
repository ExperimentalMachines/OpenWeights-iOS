import Foundation
import XCTest
@testable import OpenWeightsCore

final class ConversationContextTests: XCTestCase {
    private let model = LocalModel(name: "Test", backend: .llamaCPU, entryFile: "test.gguf", files: [])
    private func conversation() -> Conversation {
        Conversation(title: "Test", messages: [StoredMessage(role: .user, content: "Porto"),
            StoredMessage(role: .assistant, content: "Saved"), StoredMessage(role: .user, content: "Osaka"),
            StoredMessage(role: .assistant, content: "Corrected"), StoredMessage(role: .user, content: "Continue")])
    }
    func testWholeTurnBoundaryPreservesAssistantCallsAndAllResults() throws {
        var chat = conversation()
        let call = AgentToolCall(id: "call", name: "read_file", argumentsJSON: "{}")
        var assistant = StoredMessage(role: .assistant, content: "")
        assistant.toolCalls = [call]; assistant.promptContent = "<tool_call>read_file</tool_call>"
        var tool = StoredMessage(role: .tool, content: "Evidence")
        tool.toolCallID = "call"; tool.toolName = "read_file"
        chat.messages.insert(contentsOf: [assistant, tool], at: 3)
        XCTAssertEqual(ConversationContext.foldBoundary(chat, contextTokens: 2048), 6)
        XCTAssertEqual(ConversationContext.foldBoundary(chat, contextTokens: 4096), 2)
        chat.fold = ConversationFold(summary: "The location is now Osaka.", through: 2, in: chat, model: model)
        let retained = ConversationContext.prompt(chat, system: "Stable head")
        XCTAssertEqual(retained.first?["content"], "Stable head")
        XCTAssertEqual(retained.first(where: { $0["role"] == "tool" })?["tool_call_id"], "call")
        XCTAssertTrue(retained.contains { $0["content"] == assistant.promptContent })
    }
    func testEditInvalidatesSummaryButMetricsAndBranchIDsDoNot() {
        var chat = conversation()
        chat.fold = ConversationFold(summary: "Porto", through: 2, in: chat, model: model)
        chat.messages[0].tokensPerSecond = 42
        XCTAssertNotNil(ConversationContext.validFold(chat))
        var branch = chat
        branch.messages[0] = StoredMessage(role: .user, content: "Porto")
        XCTAssertNotNil(ConversationContext.validFold(branch))
        branch.messages[0].content = "Kyoto"
        XCTAssertNil(ConversationContext.validFold(branch))
        XCTAssertFalse(ConversationContext.prompt(branch, system: "Stable").contains { $0["content"]?.contains("Earlier conversation summary") == true })
        chat.messages = Array(chat.messages.prefix(1))
        XCTAssertNil(ConversationContext.validFold(chat))
    }
    func testMaskOnlyOlderCompletedReadObservationsAndKeepTaintAndOutcome() {
        var chat = conversation()
        var read = StoredMessage(role: .tool, content: String(repeating: "Evidence ", count: 100))
        read.toolName = "read_file"; read.toolCallID = "read"; read.toolUntrustedText = true
        var write = read; write.toolName = "write_file"; write.toolCallID = "write"
        var uncertain = read; uncertain.toolCallID = "uncertain"; uncertain.toolResultCheckpointFailed = true
        chat.messages.insert(contentsOf: [read, write, uncertain], at: 1)
        chat.observationMask = ConversationMask(through: 5, in: chat)
        let prompt = ConversationContext.prompt(chat, system: "Stable")
        XCTAssertTrue(prompt.first(where: { $0["tool_call_id"] == "read" })?["content"]?.contains("omitted") == true)
        XCTAssertEqual(prompt.first(where: { $0["tool_call_id"] == "write" })?["content"], write.content)
        XCTAssertEqual(prompt.first(where: { $0["tool_call_id"] == "uncertain" })?["content"], uncertain.content)
        XCTAssertTrue(chat.messages[1].toolUntrustedText == true)
        XCTAssertEqual(chat.messages[1].content, read.content)
    }
    func testUncertainEffectsRemainExplicitAfterSummary() {
        var chat = conversation()
        var tool = StoredMessage(role: .tool, content: "The approved change may already have completed.", status: .cancelled)
        tool.toolName = "write_file"; tool.toolResultCheckpointFailed = true
        chat.messages.insert(tool, at: 1)
        chat.fold = ConversationFold(summary: "Porto", through: 3, in: chat, model: model)
        let prompt = ConversationContext.prompt(chat, system: "Stable")
        XCTAssertTrue(prompt[1]["content"]?.contains(tool.content) == true)
        XCTAssertTrue(prompt[1]["content"]?.contains("Inspect actual results") == true)
    }
    func testContextPolicyReservesOutputAndClampsTrigger() {
        XCTAssertTrue(ConversationContext.shouldFold(tokens: 1200, context: 2048, output: 900, foldableSavings: 0))
        XCTAssertFalse(ConversationContext.shouldFold(tokens: 1200, context: 2048, output: 512, foldableSavings: 0))
        XCTAssertTrue(ConversationContext.shouldFold(tokens: 4200, context: 16000, output: 512, foldableSavings: 3000))
        XCTAssertFalse(ConversationContext.shouldFold(tokens: 4200, context: 16000, output: 512, foldableSavings: 2900))
        XCTAssertTrue(ConversationContext.shouldFold(tokens: 220, context: 2048, output: 512, foldableSavings: 0, trigger: -1))
    }
    func testFoldReopensAndOnlyMatchingBranchRetainsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conversations.json")
        let store = try ConversationStore(file: file)
        var chat = try await store.create(title: "Test")
        chat.messages = conversation().messages
        chat.fold = ConversationFold(summary: "Porto was corrected to Osaka.", through: 4, in: chat, model: model)
        try await store.save(chat)
        let reopened = try ConversationStore(file: file)
        let saved = try await reopened.conversation(chat.id)
        XCTAssertEqual(saved.messages, chat.messages)
        XCTAssertEqual(saved.fold, chat.fold)
        let earlier = try await reopened.branch(chat.id, through: chat.messages[1].id)
        XCTAssertNil(earlier.fold)
        let matching = try await reopened.branch(chat.id, through: chat.messages[3].id)
        XCTAssertEqual(matching.fold, chat.fold)
        XCTAssertNotEqual(matching.messages[0].id, chat.messages[0].id)
    }
    func testInFlightAndUnansweredToolRoundsCannotBeFolded() {
        var chat = conversation()
        chat.messages[3].toolCalls = [AgentToolCall(id: "call", name: "read_file", argumentsJSON: "{}")]
        XCTAssertNil(ConversationContext.foldBoundary(chat, contextTokens: 2048))
        chat.messages[3].toolCalls = nil; chat.messages[1].status = .streaming
        XCTAssertNil(ConversationContext.foldBoundary(chat, contextTokens: 2048))
    }
    func testPlanRepairRetainsTheOriginalUserTurn() {
        var chat = conversation()
        chat.messages.append(StoredMessage(role: .assistant, content: "A prose answer"))
        var repair = StoredMessage(role: .user, content: "Make a numbered plan")
        repair.continuesPreviousTurn = true
        chat.messages.append(repair)
        XCTAssertEqual(ConversationContext.foldBoundary(chat, contextTokens: 2048), 4)
        XCTAssertEqual(ConversationContext.foldBoundary(chat, contextTokens: 4096), 2)
    }
}
