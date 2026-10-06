import Foundation
import XCTest
@testable import OpenWeightsCore

final class WatchTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_964_800)
    func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("watches.json")
    }
    func testConcurrentStartsCannotExceedFourAndInputsAreChecked() async throws {
        let store = try WatchStore(file: file(), at: now)
        let count = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<10 { group.addTask { (try? await store.start(task: "Check \(index)", everyMinutes: 1, at: self.now)) != nil } }
            var success = 0
            for await started in group { if started { success += 1 } }
            return success
        }
        XCTAssertEqual(count, 4)
        let saved = await store.list(); XCTAssertEqual(saved.count, 4)
        _ = try await store.pause(saved[0].id)
        _ = try await store.start(task: "Daily check", everyMinutes: 1440, at: now)
        do { _ = try await store.resume(saved[0].id, at: now); XCTFail("Resuming exceeded active limit") } catch {}
        do { _ = try await store.start(task: " ", everyMinutes: 5, at: now); XCTFail("Blank task accepted") } catch {}
        do { _ = try await store.start(task: "Invalid", everyMinutes: 0, at: now); XCTFail("Invalid interval accepted") } catch {}
    }
    func testOneDueClaimAndOneRecordAcrossOverlappingSchedulers() async throws {
        let store = try WatchStore(file: file(), at: now)
        let watch = try await store.start(task: "Check a fact", everyMinutes: 1, at: now)
        let early = try await store.begin(watch.id, at: now.addingTimeInterval(59)); XCTAssertNil(early)
        let first = try await store.begin(watch.id, at: now.addingTimeInterval(60))
        let ticket = try XCTUnwrap(first)
        let overlap = try await store.begin(watch.id, at: now.addingTimeInterval(61)); XCTAssertNil(overlap)
        let due = await store.due(at: now.addingTimeInterval(100)); XCTAssertTrue(due.isEmpty)
        let recorded = try await store.record(ticket, outcome: .checked, summary: "A fact", at: now.addingTimeInterval(80), changed: true)
        XCTAssertEqual(recorded?.runs, 1); XCTAssertEqual(recorded?.lastRunAt, ticket.claim.startedAt)
        XCTAssertEqual(recorded?.nextDueAt, now.addingTimeInterval(140))
        let duplicate = try await store.record(ticket, outcome: .failed, summary: "Late error", at: now.addingTimeInterval(81))
        XCTAssertNil(duplicate)
        let final = await store.watch(watch.id); XCTAssertEqual(final?.history.count, 1); XCTAssertEqual(final?.lastSummary, "A fact")
    }
    func testLateResultsCannotUndoPauseEditStopOrRemoval() async throws {
        let store = try WatchStore(file: file(), at: now)
        for action in ["pause", "edit", "stop", "forget"] {
            let watch = try await store.start(task: "Old task", everyMinutes: 1, at: now)
            let claimed = try await store.begin(watch.id, at: now.addingTimeInterval(60)); let ticket = try XCTUnwrap(claimed)
            switch action {
            case "pause": _ = try await store.pause(watch.id)
            case "edit": _ = try await store.edit(watch.id, task: "New task", everyMinutes: 7, at: now.addingTimeInterval(61))
            case "stop": _ = try await store.stop(watch.id)
            default: try await store.forget(watch.id)
            }
            let late = try await store.record(ticket, outcome: .checked, summary: "Obsolete answer", at: now.addingTimeInterval(70), changed: true)
            XCTAssertNil(late)
            let final = await store.watch(watch.id)
            XCTAssertNil(final?.resultNotice); XCTAssertNil(final?.lastSummary)
            if action == "edit" { XCTAssertEqual(final?.task, "New task"); XCTAssertEqual(final?.nextDueAt, now.addingTimeInterval(481)) }
            if final != nil { try await store.forget(watch.id) }
        }
    }
    func testSkippedChecksKeepLastFindingAndFailureCountButMoveDeadline() async throws {
        let store = try WatchStore(file: file(), at: now)
        let watch = try await store.start(task: "Check", everyMinutes: 1, at: now)
        func run(_ seconds: TimeInterval, _ outcome: WatchRun.Outcome, _ text: String) async throws -> ScheduledWatch {
            let claimed = try await store.begin(watch.id, at: now.addingTimeInterval(seconds)); let ticket = try XCTUnwrap(claimed)
            let result = try await store.record(ticket, outcome: outcome, summary: text, at: now.addingTimeInterval(seconds + 5))
            return try XCTUnwrap(result)
        }
        _ = try await run(60, .checked, "Known finding")
        let failed = try await run(125, .failed, "Could not check")
        let skipped = try await run(190, .skipped, "Busy")
        XCTAssertEqual(skipped.runs, 2); XCTAssertEqual(skipped.consecutiveFailures, 1)
        XCTAssertEqual(skipped.lastRunAt, failed.lastRunAt); XCTAssertEqual(skipped.lastSummary, failed.lastSummary)
        XCTAssertEqual(skipped.nextDueAt, now.addingTimeInterval(255)); XCTAssertEqual(skipped.history.last?.outcome, .skipped)
        let recovered = try await run(255, .checked, "Recovered")
        XCTAssertEqual(recovered.consecutiveFailures, 0); XCTAssertEqual(recovered.runs, 3)
    }
    func testThreeFailuresEndWithoutSkippedChecksSpendingTheBudget() async throws {
        let store = try WatchStore(file: file(), at: now)
        let watch = try await store.start(task: "Check", everyMinutes: 1, at: now)
        var final = watch
        for outcome in [WatchRun.Outcome.failed, .skipped, .failed, .skipped, .failed] {
            let claimed = try await store.begin(watch.id, at: final.nextDueAt); let ticket = try XCTUnwrap(claimed)
            let result = try await store.record(ticket, outcome: outcome, summary: "Reason", at: final.nextDueAt)
            final = try XCTUnwrap(result)
        }
        XCTAssertEqual(final.state, .failed); XCTAssertEqual(final.runs, 3); XCTAssertEqual(final.consecutiveFailures, 3)
        XCTAssertEqual(final.endNotice?.kind, .ended)
        let ended = try await store.begin(watch.id, at: final.nextDueAt); XCTAssertNil(ended)
        do { _ = try await store.resume(watch.id, at: final.nextDueAt); XCTFail("Failed watch resumed") } catch {}
    }
    func testRunBudgetAndHistoryAreBoundedWithValidUnicode() async throws {
        let store = try WatchStore(file: file(), at: now)
        var watch = try await store.start(task: "Check", everyMinutes: 1, at: now)
        for _ in 0..<60 {
            let claimed = try await store.begin(watch.id, at: watch.nextDueAt); let ticket = try XCTUnwrap(claimed)
            let result = try await store.record(ticket, outcome: .checked, summary: String(repeating: "👩🏽‍💻", count: 100), at: watch.nextDueAt, changed: true)
            watch = try XCTUnwrap(result)
        }
        XCTAssertEqual(watch.state, .expired); XCTAssertEqual(watch.runs, 60); XCTAssertEqual(watch.history.count, 20)
        XCTAssertTrue(watch.history.allSatisfy { $0.summary.utf16.count <= 400 && !$0.summary.contains("�") })
        XCTAssertNotNil(watch.resultNotice); XCTAssertNotNil(watch.endNotice)
        do { _ = try await store.edit(watch.id, task: "Reset budget", everyMinutes: 1, at: watch.nextDueAt); XCTFail("Budget reset through edit") } catch {}
    }
    func testDailyCadenceGetsTwoChecksBeforeTheIndependentLifetimeLimit() async throws {
        let location = try file(); let store = try WatchStore(file: location, at: now)
        var watch = try await store.start(task: "Daily", everyMinutes: 1440, at: now)
        for _ in 0..<2 {
            let claimed = try await store.begin(watch.id, at: watch.nextDueAt); let ticket = try XCTUnwrap(claimed)
            let result = try await store.record(ticket, outcome: .checked, summary: "Daily finding", at: watch.nextDueAt)
            watch = try XCTUnwrap(result)
        }
        XCTAssertEqual(watch.runs, 2); XCTAssertEqual(watch.state, .active)
        let reopened = try WatchStore(file: location, at: now.addingTimeInterval(ScheduledWatch.lifetime))
        let expired = await reopened.watch(watch.id); XCTAssertEqual(expired?.state, .expired); XCTAssertEqual(expired?.runs, 2)
        let sweep = try await reopened.expire(at: watch.expiresAt); XCTAssertTrue(sweep.isEmpty)
        do { _ = try await reopened.resume(watch.id, at: watch.expiresAt); XCTFail("Expired watch revived") } catch {}
    }
    func testReopenRecoversAnInterruptedClaimOnceAndCatchUpHasNoBacklog() async throws {
        let location = try file(); let store = try WatchStore(file: location, at: now)
        let watch = try await store.start(task: "Check", everyMinutes: 1, at: now)
        let claimed = try await store.begin(watch.id, at: now.addingTimeInterval(60)); XCTAssertNotNil(claimed)
        let reopened = try WatchStore(file: location, at: now.addingTimeInterval(300))
        let restored = await reopened.watch(watch.id)
        XCTAssertNil(restored?.claim); XCTAssertEqual(restored?.runs, 0); XCTAssertEqual(restored?.consecutiveFailures, 0)
        XCTAssertEqual(restored?.history.count, 1); XCTAssertEqual(restored?.history.last?.outcome, .skipped)
        let again = try WatchStore(file: location, at: now.addingTimeInterval(301))
        let repeated = await again.watch(watch.id); XCTAssertEqual(repeated, restored)
        let due = await again.due(at: now.addingTimeInterval(3600)); XCTAssertEqual(due.count, 1)
        let catchUp = try await again.begin(watch.id, at: now.addingTimeInterval(3600)); let ticket = try XCTUnwrap(catchUp)
        _ = try await again.record(ticket, outcome: .checked, summary: "Current answer", at: now.addingTimeInterval(3610))
        let extra = await again.due(at: now.addingTimeInterval(3610)); XCTAssertTrue(extra.isEmpty)
    }
    func testNoticeAcknowledgementCannotRemoveANewerResultAndSurvivesRestart() async throws {
        let location = try file(); let store = try WatchStore(file: location, at: now)
        var watch = try await store.start(task: "Check", everyMinutes: 1, at: now)
        var notices: [WatchNotice] = []
        for summary in ["First finding", "New finding"] {
            let claimed = try await store.begin(watch.id, at: watch.nextDueAt); let ticket = try XCTUnwrap(claimed)
            let result = try await store.record(ticket, outcome: .checked, summary: summary, at: watch.nextDueAt, changed: true)
            watch = try XCTUnwrap(result); notices.append(try XCTUnwrap(watch.resultNotice))
        }
        try await store.acknowledgeNotice(watchID: watch.id, noticeID: notices[0].id)
        let reopened = try WatchStore(file: location, at: watch.nextDueAt)
        let retained = await reopened.watch(watch.id); XCTAssertEqual(retained?.resultNotice, notices[1])
        try await reopened.acknowledgeNotice(watchID: watch.id, noticeID: notices[1].id)
        let settled = await reopened.watch(watch.id); XCTAssertNil(settled?.resultNotice)
    }
    func testPauseResumeAndIntervalEditKeepPriorChecksAndOriginalExpiry() async throws {
        let store = try WatchStore(file: file(), at: now)
        let watch = try await store.start(task: "Same task", everyMinutes: 1, at: now)
        let claimed = try await store.begin(watch.id, at: watch.nextDueAt); let ticket = try XCTUnwrap(claimed)
        _ = try await store.record(ticket, outcome: .checked, summary: "Saved finding", at: watch.nextDueAt, changed: true)
        let paused = try await store.pause(watch.id)
        let due = await store.due(at: now.addingTimeInterval(300)); XCTAssertTrue(due.isEmpty)
        let edited = try await store.edit(watch.id, task: "Same task", everyMinutes: 10, at: now.addingTimeInterval(300))
        XCTAssertEqual(edited.state, .paused); XCTAssertEqual(edited.lastSummary, "Saved finding")
        XCTAssertEqual(edited.resultNotice, paused.resultNotice); XCTAssertEqual(edited.runs, 1)
        let resumed = try await store.resume(watch.id, at: now.addingTimeInterval(400))
        XCTAssertEqual(resumed.nextDueAt, now.addingTimeInterval(1000)); XCTAssertEqual(resumed.expiresAt, watch.expiresAt)
        XCTAssertEqual(resumed.lastSummary, "Saved finding"); XCTAssertEqual(resumed.runs, 1)
        let stopped = try await store.stop(watch.id)
        let expired = try await store.expire(at: watch.expiresAt); XCTAssertTrue(expired.isEmpty)
        let retained = await store.watch(watch.id); XCTAssertEqual(retained, stopped)
        let lapsed = try await store.start(task: "Paused but time-bounded", everyMinutes: 1, at: now)
        _ = try await store.pause(lapsed.id)
        do { _ = try await store.resume(lapsed.id, at: lapsed.expiresAt); XCTFail("A lapsed pause resumed") } catch {}
        let ended = await store.watch(lapsed.id); XCTAssertEqual(ended?.state, .expired); XCTAssertNotNil(ended?.endNotice)
    }
    func testVerdictUsesASeparateFinalLineAndDoesNotInventSilence() {
        XCTAssertEqual(WatchVerdict.read("Price is 12.\n**UNCHANGED**", previous: "Price is 12."), .init(summary: "Price is 12.", changed: false))
        XCTAssertTrue(WatchVerdict.read("Price is 12.\nUNCHANGED", previous: nil).changed)
        XCTAssertFalse(WatchVerdict.read("Same", previous: "Same").changed)
        XCTAssertTrue(WatchVerdict.read("New", previous: "Old").changed)
        XCTAssertEqual(WatchVerdict.read("The price has not CHANGED.", previous: "Different").summary, "The price has not CHANGED.")
        XCTAssertEqual(WatchVerdict.read("CHANGED", previous: "Old").summary, "Nothing new.")
        XCTAssertEqual(WatchVerdict.read("UNCHANGED.", previous: "Price is 12."), .init(summary: "Price is 12.", changed: false))
    }
    func testWatchToolAlwaysNeedsExactSingleUseApprovalAndHonorsSwitchAndPlan() async throws {
        let store = try WatchStore(file: file(), at: now); let tools = WatchTools(store: store)
        let call = AgentToolCall(id: "w", name: "watch", argumentsJSON: "{\"task\":\"Check the report\",\"every_minutes\":5}")
        for mode in [AgentMode.auto, .ask, .yolo] {
            let refused = await tools.execute(call, enabled: true, mode: mode, at: now); XCTAssertTrue(refused.rejected)
        }
        let approval = ApprovedToolCall(displayedCall: call)
        let disabled = await tools.execute(call, enabled: false, mode: .auto, approval: approval, at: now); XCTAssertTrue(disabled.rejected)
        let plan = await tools.execute(call, enabled: true, mode: .plan, approval: approval, at: now); XCTAssertTrue(plan.rejected)
        let modified = AgentToolCall(id: "w", name: "watch", argumentsJSON: "{\"task\":\"Different report\",\"every_minutes\":5}")
        let mismatch = await tools.execute(modified, enabled: true, mode: .auto, approval: approval, at: now); XCTAssertTrue(mismatch.rejected)
        let started = await tools.execute(call, enabled: true, mode: .yolo, approval: approval, at: now)
        XCTAssertFalse(started.rejected); XCTAssertTrue(started.text.contains("iOS grants time"))
        let replay = await tools.execute(call, enabled: true, mode: .auto, approval: approval, at: now); XCTAssertTrue(replay.rejected)
        for interval in ["true", "1.5", "0", "1441"] {
            let invalid = AgentToolCall(id: UUID().uuidString, name: "watch", argumentsJSON: "{\"task\":\"Check\",\"every_minutes\":\(interval)}")
            let result = await tools.execute(invalid, enabled: true, mode: .auto, approval: ApprovedToolCall(displayedCall: invalid), at: now)
            XCTAssertTrue(result.rejected)
        }
        let saved = await store.list(); XCTAssertEqual(saved.count, 1)
    }
    func testFailedWritesAndCorruptOrFutureSnapshotsPreserveEvidence() async throws {
        let location = try file(); let store = try WatchStore(file: location, at: now)
        let watch = try await store.start(task: "Check", everyMinutes: 1, at: now)
        let before = await store.list()
        let original = try Data(contentsOf: location)
        try FileManager.default.removeItem(at: location); try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        do { _ = try await store.pause(watch.id); XCTFail("Expected failed checkpoint") } catch {}
        let after = await store.list(); XCTAssertEqual(after, before)
        try FileManager.default.removeItem(at: location)
        for text in ["not JSON", "{\"version\":2,\"watches\":[]}"] {
            let data = Data(text.utf8); try data.write(to: location)
            XCTAssertThrowsError(try WatchStore(file: location, at: now)); XCTAssertEqual(try Data(contentsOf: location), data)
        }
        var invalid = try XCTUnwrap(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        var watches = try XCTUnwrap(invalid["watches"] as? [[String: Any]])
        watches[0]["runs"] = 60; invalid["watches"] = watches
        let data = try JSONSerialization.data(withJSONObject: invalid)
        try data.write(to: location)
        XCTAssertThrowsError(try WatchStore(file: location, at: now)); XCTAssertEqual(try Data(contentsOf: location), data)
    }
}
