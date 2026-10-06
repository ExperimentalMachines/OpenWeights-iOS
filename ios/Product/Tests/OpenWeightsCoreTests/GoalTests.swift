import Foundation
import XCTest
@testable import OpenWeightsCore

final class GoalTests: XCTestCase {
    func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("goal.json")
    }
    let plan = TaskPlan(steps: [TaskStep(text: "Find"), TaskStep(text: "Read")])
    func testProgressBudgetAndTerminalStateCannotBeReplayed() async throws {
        let store = try GoalStore(file: file())
        let first = try await store.start(task: "Find the report", conversationID: UUID())
        let id = try XCTUnwrap(first.goal?.id)
        _ = try await store.planned(plan, expectedID: id)
        var last = first
        for _ in 0..<WorkGoal.maximumSteps { last = try await store.advanced(plan, expectedID: id) }
        XCTAssertEqual(last.goal?.state, .halted)
        XCTAssertEqual(last.goal?.stepsTaken, 12)
        do { _ = try await store.advanced(plan, expectedID: id); XCTFail("Budget was bypassed") } catch {}
        do { _ = try await store.resume(plan: plan, expectedID: id); XCTFail("Spent goal resumed") } catch {}
        let next = try await store.start(task: "New bounded task", conversationID: UUID())
        let nextID = try XCTUnwrap(next.goal?.id)
        do { _ = try await store.stop(expectedID: id); XCTFail("Stale ID stopped a new goal") } catch {}
        _ = try await store.planned(plan, expectedID: nextID)
        let done = try await store.advanced(plan.ticked(0).ticked(1), expectedID: nextID)
        XCTAssertEqual(done.goal?.state, .done)
        let retained = try await store.halt("Old lifecycle event", expectedID: nextID)
        XCTAssertEqual(retained.goal?.state, .done)
    }
    func testInterruptedGoalKeepsPlanAndSteeringWithoutAutomaticResume() async throws {
        let location = try file()
        let store = try GoalStore(file: location)
        let first = try await store.start(task: "Task", conversationID: UUID())
        let id = try XCTUnwrap(first.goal?.id)
        _ = try await store.planned(plan, expectedID: id)
        _ = try await store.steer("Use September", expectedID: id)
        let reopened = try GoalStore(file: location)
        let paused = await reopened.snapshot()
        XCTAssertEqual(paused.goal?.state, .halted)
        XCTAssertEqual(paused.goal?.plan, plan)
        XCTAssertEqual(paused.goal?.steering, ["Use September"])
        XCTAssertTrue(paused.goal!.note!.contains("Review"))
        let resumed = try await reopened.resume(plan: plan, expectedID: id)
        XCTAssertEqual(resumed.goal?.state, .working)
        let cleared = try await reopened.stop(expectedID: id)
        XCTAssertEqual(cleared.goal?.state, .stopped)
    }
    func testSteeringIsBoundedAtomicAndConsumedOnce() async throws {
        let store = try GoalStore(file: file())
        let first = try await store.start(task: "Task", conversationID: UUID())
        let id = try XCTUnwrap(first.goal?.id)
        for i in 0..<25 { _ = try await store.steer("\(i) " + String(repeating: "👩🏽‍💻", count: 100), expectedID: id) }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.goal?.steering.count, 16)
        XCTAssertTrue(snapshot.goal!.steering.allSatisfy { $0.utf16.count <= 500 })
        let (empty, messages) = try await store.takeSteering(expectedID: id)
        XCTAssertEqual(messages.count, 16)
        XCTAssertTrue(empty.goal!.steering.isEmpty)
        _ = try await store.steer("Arrived at boundary", expectedID: id)
        let (_, fresh) = try await store.takeSteering(expectedID: id)
        XCTAssertEqual(fresh, ["Arrived at boundary"])
    }
    func testFailedWriteRetainsPriorGoalAndCorruptionIsPreserved() async throws {
        let location = try file()
        let store = try GoalStore(file: location)
        let before = try await store.start(task: "Task", conversationID: UUID())
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        do { _ = try await store.steer("Must not appear", expectedID: before.goal!.id); XCTFail("Expected a failed write") } catch {}
        let retained = await store.snapshot(); XCTAssertEqual(retained, before)
        try FileManager.default.removeItem(at: location)
        let data = Data("corrupt snapshot".utf8); try data.write(to: location)
        XCTAssertThrowsError(try GoalStore(file: location))
        XCTAssertEqual(try Data(contentsOf: location), data)
    }
    func testHostVerdictRejectsWrongAdvanceAndFailedToolsWithoutDoubleTick() {
        var advance = StoredMessage(role: .tool, content: "Finished")
        advance.toolName = "advance"
        XCTAssertNil(WorkGoal.stepRefusal(before: plan, after: plan.ticked(0), tools: [advance]))
        XCTAssertNotNil(WorkGoal.stepRefusal(before: plan, after: plan.ticked(1), tools: [advance]))
        XCTAssertNotNil(WorkGoal.stepRefusal(before: plan, after: plan.ticked(0).ticked(1), tools: [advance]))
        XCTAssertNotNil(WorkGoal.stepRefusal(before: plan, after: plan, tools: [advance]))
        var failed = StoredMessage(role: .tool, content: "Declined", status: .failed); failed.toolName = "write_file"
        XCTAssertNotNil(WorkGoal.stepRefusal(before: plan, after: plan, tools: [failed]))
        XCTAssertNil(WorkGoal.stepRefusal(before: plan, after: plan, tools: []))
        XCTAssertTrue(WorkGoal.shouldRetry(failures: 1, tools: [failed]))
        XCTAssertFalse(WorkGoal.shouldRetry(failures: 2, tools: [failed]))
        advance.toolResultCheckpointFailed = true
        XCTAssertNotNil(WorkGoal.stepRefusal(before: plan, after: plan.ticked(0), tools: [advance]))
        XCTAssertFalse(WorkGoal.shouldRetry(failures: 1, tools: [advance]))
    }
}
