import Foundation
import XCTest
@testable import OpenWeightsCore

final class ResearchTests: XCTestCase {
    func messages() -> [StoredMessage] {
        var search = StoredMessage(role: .tool, content: "Untrusted snippets")
        search.toolName = "web_search"
        search.searchEvidence = WebSearchEvidence(query: "status", engine: .brave, hits: [WebSearchHit(title: "Status", snippet: "Status", url: "https://example.com/status")])
        var fetch = StoredMessage(role: .tool, content: "Page")
        fetch.toolName = "fetch_url"; fetch.fetchEvidence = WebFetchEvidence(requestedURL: "https://example.com/status", finalURL: "https://example.com/current")
        return [search, fetch]
    }
    func testOnlySuccessfulTypedCorrelatedToolsCount() {
        let valid = messages()
        XCTAssertEqual(ResearchBrief.correlatedSources(valid), ["https://example.com/current"])
        XCTAssertNotNil(ResearchBrief.refusal([valid[0]]))
        XCTAssertNotNil(ResearchBrief.refusal([valid[1]]))
        var unrelated = valid; unrelated[1].fetchEvidence = WebFetchEvidence(requestedURL: "https://example.com/other", finalURL: "https://example.com/current")
        XCTAssertNotNil(ResearchBrief.refusal(unrelated))
        var failed = valid; failed[1].status = .failed
        XCTAssertNotNil(ResearchBrief.refusal(failed))
        var checkpoint = valid; checkpoint[1].toolResultCheckpointFailed = true
        XCTAssertNotNil(ResearchBrief.refusal(checkpoint))
        var prose = valid; prose[0].searchEvidence = nil; prose[0].content = "Search found https://example.com/status"
        XCTAssertNotNil(ResearchBrief.refusal(prose))
    }
    func testRetryEvidenceCannotCrossGoalQuestionOrIndex() {
        let scope = ResearchStepScope(goalID: UUID(), index: 0, question: "Identifier?")
        var valid = messages(); for index in valid.indices { valid[index].researchStep = scope }
        XCTAssertEqual(ResearchBrief.correlatedSources(ResearchBrief.scopedTools(valid, scope: scope)), ["https://example.com/current"])
        for other in [ResearchStepScope(goalID: UUID(), index: 0, question: scope.question), ResearchStepScope(goalID: scope.goalID, index: 1, question: scope.question), ResearchStepScope(goalID: scope.goalID, index: 0, question: "Other?")] {
            XCTAssertTrue(ResearchBrief.scopedTools(valid, scope: other).isEmpty)
        }
        valid[0].researchStep = nil
        XCTAssertTrue(ResearchBrief.correlatedSources(ResearchBrief.scopedTools(valid, scope: scope)).isEmpty)
    }
    func testFallbackIsOneBoundedQuestionAndManualTicksNeedEvidence() {
        let plan = ResearchBrief.fallback("What is the current status of this specific project and what changed recently?")
        XCTAssertEqual(plan.steps.count, 1); XCTAssertLessThanOrEqual(plan.steps[0].text.utf16.count, 60)
        XCTAssertFalse(ResearchProgress().reviewed(plan.ticked(0)).steps[0].done)
        XCTAssertFalse(ResearchProgress().verifies(plan.ticked(0)))
    }
    func testResearchRequiresEvidenceThenSeparateReportCompletionAndReopen() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try GoalStore(file: file)
        let started = try await store.start(task: "Status?", conversationID: UUID(), research: true)
        let id = try XCTUnwrap(started.goal?.id), plan = ResearchBrief.fallback("Status?")
        _ = try await store.planned(plan, expectedID: id)
        do { _ = try await store.advanced(plan.ticked(0), expectedID: id); XCTFail("No sources counted") } catch {}
        let writing = try await store.advanced(plan.ticked(0), expectedID: id, sources: ["https://example.com/status"])
        XCTAssertEqual(writing.goal?.state, .writing); XCTAssertTrue(writing.goal!.isRunning)
        let reopened = try GoalStore(file: file), interrupted = await reopened.snapshot()
        XCTAssertEqual(interrupted.goal?.state, .halted)
        XCTAssertEqual(interrupted.goal?.research, writing.goal?.research)
        let resumed = try await reopened.resume(plan: writing.goal?.plan, expectedID: id)
        XCTAssertEqual(resumed.goal?.state, .writing)
        let done = try await reopened.finishResearch(expectedID: id)
        XCTAssertEqual(done.goal?.state, .done)
    }
    func testReviewChangedQuestionCannotReuseOldEvidence() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try GoalStore(file: file), plan = ResearchBrief.fallback("Status?")
        let id = try await store.start(task: "Status?", conversationID: UUID(), research: true).goal!.id
        _ = try await store.planned(plan, expectedID: id)
        _ = try await store.advanced(plan.ticked(0), expectedID: id, sources: ["https://example.com/status"])
        _ = try await store.stop(expectedID: id)
        let different = TaskPlan(steps: [TaskStep(text: "Other question?", done: true)])
        let resumed = try await store.resume(plan: different, expectedID: id)
        XCTAssertEqual(resumed.goal?.state, .working); XCTAssertFalse(resumed.goal!.plan!.steps[0].done)
        XCTAssertFalse(resumed.goal!.research!.verifies(different))
    }
    func testCompletedReviewInvalidatesRecheckedEvidenceAndRetainsBudgetIdentity() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try GoalStore(file: file), plan = ResearchBrief.fallback("Status?")
        let started = try await store.start(task: "Status?", conversationID: UUID(), research: true), id = started.goal!.id
        _ = try await store.planned(plan, expectedID: id)
        _ = try await store.advanced(plan.ticked(0), expectedID: id, sources: ["https://example.com/status"])
        let done = try await store.finishResearch(expectedID: id)
        let reviewed = try await store.reviewPlan(plan, expectedID: id)
        XCTAssertEqual(reviewed.goal?.state, .halted); XCTAssertEqual(reviewed.goal?.id, id)
        XCTAssertEqual(reviewed.goal?.stepsTaken, 1); XCTAssertNotNil(reviewed.goal?.planReviewID)
        XCTAssertNotEqual(reviewed.goal?.research?.cycleID, done.goal?.research?.cycleID)
        XCTAssertTrue(reviewed.goal!.research!.evidence.isEmpty)
        let reopened = await (try GoalStore(file: file)).snapshot()
        XCTAssertEqual(reopened, reviewed)
        let old = ResearchStepScope(goalID: id, index: 0, question: "Status?", cycleID: done.goal?.research?.cycleID)
        let fresh = ResearchStepScope(goalID: id, index: 0, question: "Status?", cycleID: reviewed.goal?.research?.cycleID)
        var tools = messages(); for i in tools.indices { tools[i].researchStep = old }
        XCTAssertTrue(ResearchBrief.scopedTools(tools, scope: fresh).isEmpty)
    }
    func testClearResearchPlanClearsEvidenceAndManualTicksCannotProveNewQuestions() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try GoalStore(file: file), plan = ResearchBrief.fallback("Status?")
        let id = try await store.start(task: "Status?", conversationID: UUID(), research: true).goal!.id
        _ = try await store.planned(plan, expectedID: id)
        _ = try await store.advanced(plan.ticked(0), expectedID: id, sources: ["https://example.com/status"])
        _ = try await store.finishResearch(expectedID: id)
        let cleared = try await store.reviewPlan(nil, expectedID: id)
        XCTAssertNil(cleared.goal?.plan); XCTAssertEqual(cleared.goal?.state, .halted)
        XCTAssertTrue(cleared.goal!.research!.evidence.isEmpty)
        let checked = TaskPlan(steps: [TaskStep(text: "New question?", done: true)])
        let reviewed = try await store.reviewPlan(checked, expectedID: id)
        XCTAssertFalse(reviewed.goal!.plan!.steps[0].done)
        XCTAssertEqual(reviewed.goal?.stepsTaken, 1)
    }
    func testLegacyResearchScopesAndProgressDecodeWithoutCycleAndReviewTokens() throws {
        let progress = try JSONDecoder().decode(ResearchProgress.self, from: Data("{\"evidence\":[]}".utf8))
        XCTAssertNil(progress.cycleID)
        let scope = ResearchStepScope(goalID: UUID(), index: 0, question: "Status?")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as? [String: Any]); object.removeValue(forKey: "cycleID")
        XCTAssertNil(try JSONDecoder().decode(ResearchStepScope.self, from: JSONSerialization.data(withJSONObject: object)).cycleID)
    }
    func testOldGoalSnapshotAndOldMessagesDecodeWithoutResearchMetadata() throws {
        let original = WorkGoal(task: "Original", conversationID: UUID())
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); object.removeValue(forKey: "research")
        let decoded = try decoder.decode(WorkGoal.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.research); XCTAssertEqual(decoded, original)
        let message = StoredMessage(role: .tool, content: "Historical page")
        XCTAssertNil(try decoder.decode(StoredMessage.self, from: encoder.encode(message)).fetchEvidence)
    }
}
