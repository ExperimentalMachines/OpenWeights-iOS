import Foundation
import XCTest
@testable import OpenWeightsCore

final class PlanningTests: XCTestCase {
    func call(_ name: String, _ args: String) -> AgentToolCall {
        AgentToolCall(id: "fixture", name: name, argumentsJSON: args)
    }
    func call(_ args: String) -> AgentToolCall { call("ask_user", args) }
    func testListParserIgnoresProseBoundsStepsAndPreservesCharacters() throws {
        XCTAssertNil(TaskPlan.read("Just explain it.\n1. One step"))
        let plan = try XCTUnwrap(TaskPlan.read("Intro\nStep 1: **Find** the file\n2) `Read` it\n- Write summary\n* Review\n• Finish\n6. Ignore"))
        XCTAssertEqual(plan.steps.map(\.text), ["Find the file", "Read it", "Write summary", "Review", "Finish"])
        let unicode = try XCTUnwrap(TaskPlan.read("1. " + String(repeating: "👩🏽‍💻", count: 20) + "\n2. " + String(repeating: "é", count: 80)))
        XCTAssertTrue(unicode.steps.allSatisfy { $0.text.utf16.count <= 60 })
        XCTAssertEqual(unicode.steps[0].text, String(repeating: "👩🏽‍💻", count: 8))
    }
    func testAdvanceAvailabilityWholeNumberAliasesAndBounds() throws {
        let plan = TaskPlan(steps: [TaskStep(text: "First"), TaskStep(text: "Second")])
        XCTAssertEqual(PlanningToolDefinitions.enabled(plan: nil, mode: .auto).count, 0)
        XCTAssertEqual(PlanningToolDefinitions.enabled(plan: plan, mode: .plan).map(\.name), ["advance", "ask_user"])
        XCTAssertEqual(try PlanningToolDefinitions.step(call("advance", "{\"number\":\" 2 \"}")), 2)
        XCTAssertEqual(try PlanningToolDefinitions.step(call("advance", "{\"index\":-1}")), -1)
        for args in ["{\"step\":true}", "{\"step\":1.5}", "{\"step\":1e100}", "[]", "{}"] {
            XCTAssertThrowsError(try PlanningToolDefinitions.step(call("advance", args)))
        }
        XCTAssertEqual(plan.ticked(Int.min), plan)
        let finished = plan.ticked(0).ticked(1)
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(PlanningToolDefinitions.enabled(plan: finished, mode: .auto).count, 0)
        XCTAssertTrue(plan.statusBlock.contains("1. [ ] First"))
        XCTAssertFalse(finished.statusBlock.contains("Do the next"))
    }
    func testQuestionAliasesOptionBoundAndStrictBoolean() throws {
        let question = try UserQuestion.read(call("{\"prompt\":\" Pick a city \",\"options\":[\" A \",\"\",\"B\",\"C\",\"D\",\"E\"],\"multi\":\"TRUE\"}"))
        XCTAssertEqual(question.text, "Pick a city")
        XCTAssertEqual(question.options, ["A", "B", "C", "D"])
        XCTAssertTrue(question.multiple)
        XCTAssertFalse(try UserQuestion.read(call("{\"text\":\"Pick\",\"multiple\":1}")).multiple)
        XCTAssertThrowsError(try UserQuestion.read(call("{\"question\":\"  \"}")))
        XCTAssertThrowsError(try UserQuestion.read(call("[]")))
    }
    func testPlanAndQuestionReopenBranchAndLegacyShape() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.json")
        let store = try ConversationStore(file: file)
        var value = try await store.create(title: "Plan")
        let first = TaskPlan(steps: [TaskStep(text: "Find"), TaskStep(text: "Read")])
        var proposed = StoredMessage(role: .assistant, content: "1. Find\n2. Read")
        proposed.planAfterMessage = first
        var advanced = StoredMessage(role: .tool, content: "Finished")
        advanced.planAfterMessage = first.ticked(0)
        value.messages = [proposed, advanced]; value.plan = first.ticked(0).ticked(1)
        try await store.save(value)
        let earlier = try await store.branch(value.id, through: proposed.id)
        let latest = try await store.branch(value.id, through: advanced.id)
        XCTAssertEqual(earlier.plan, first)
        XCTAssertEqual(latest.plan, value.plan)
        var pending = StoredMessage(role: .tool, content: "Waiting", status: .streaming)
        pending.toolName = "ask_user"; pending.userQuestion = UserQuestion(text: "Where?", options: ["Osaka"])
        value.messages.append(pending); try await store.save(value)
        let reopened = try ConversationStore(file: file)
        let saved = try await reopened.conversation(value.id)
        XCTAssertEqual(saved.plan, value.plan)
        XCTAssertEqual(saved.messages.last?.userQuestion, pending.userQuestion)
        XCTAssertEqual(saved.messages.last?.status, .cancelled)
        XCTAssertTrue(saved.messages.last!.content.contains("Answer or skip"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "plan")
        var messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        for index in messages.indices { messages[index].removeValue(forKey: "userQuestion"); messages[index].removeValue(forKey: "planAfterMessage") }
        object["messages"] = messages
        let old = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.plan); XCTAssertNil(old.messages.last?.userQuestion)
    }
}
