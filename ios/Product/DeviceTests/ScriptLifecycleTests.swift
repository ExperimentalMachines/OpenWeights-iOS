import XCTest
import OpenWeightsCore
@testable import OpenWeights

@MainActor private final class SuspendedScriptDiscovery {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { self.continuation = continuation }
        }
    }
    func release() { released = true; let value = continuation; continuation = nil; value?.resume() }
}

@MainActor extension ProductTests {
    func testNativeScriptDeadlineReturnsBeforeNonCooperativeDiscoveryAndCleansLateLaunch() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated helper requires iOS 26.") }
        let gate = SuspendedScriptDiscovery(); var entries = 0
        let runner = IsolatedScriptRunner(deadlineNanoseconds: 200_000_000, beforeDiscovery: {
            entries += 1; if entries == 1 { await gate.wait() }
        })
        defer { gate.release(); runner.cancel() }
        let begin = ProcessInfo.processInfo.systemUptime
        let pending = Task { try await runner.run(source: "while(true){}", inputsJSON: "{}") }
        var elapsed = 0.0
        do { _ = try await pending.value; XCTFail("The held discovery did not time out."); return }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut); elapsed = ProcessInfo.processInfo.systemUptime - begin }
        XCTAssertTrue(gate.entered); XCTAssertLessThan(elapsed, 1)
        XCTAssertTrue(runner.hasPendingRequest)
        do { _ = try await runner.run(source: "1", inputsJSON: "{}"); XCTFail("A second launch was admitted while cleanup was held."); return }
        catch ScriptProcessError.busy {}
        XCTAssertEqual(entries, 1); XCTAssertNil(runner.lastProcessID)
        gate.release()
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 1
        while runner.hasPendingRequest {
            guard ProcessInfo.processInfo.systemUptime < cleanupDeadline else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(runner.lastStage, "discovering-extension"); XCTAssertNil(runner.lastProcessID)
        let recovered = try await runner.run(source: "6*7", inputsJSON: "{}")
        XCTAssertEqual(recovered.output, "42"); XCTAssertFalse(recovered.failed)
        XCTAssertNotEqual(runner.lastProcessID, getpid())
        let data = try JSONSerialization.data(withJSONObject: ["purpose": "native-script-whole-call-deadline", "completed": recovered.output == "42",
            "heldPhase": "non-cooperative-before-discovery", "deadlineSeconds": 0.2, "callerReturnedSeconds": elapsed,
            "heldLaunchRefusedOverlap": entries == 2, "lateDiscoveryStoppedBeforeProcessLaunch": true,
            "hostPID": getpid(), "recoveryHelperPID": runner.lastProcessID ?? -1,
            "limitations": ["A controlled non-cooperative discovery gate plus real extension recovery. Not an actual hung OS service or a real-time scheduling guarantee."]], options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNativeScriptStopReturnsBeforeNonCooperativeDiscoveryAndRecovers() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated helper requires iOS 26.") }
        let gate = SuspendedScriptDiscovery(); var entries = 0
        let runner = IsolatedScriptRunner(beforeDiscovery: { entries += 1; if entries == 1 { await gate.wait() } })
        defer { gate.release(); runner.cancel() }
        let pending = Task { try await runner.run(source: "while(true){}", inputsJSON: "{}") }
        let entryDeadline = ProcessInfo.processInfo.systemUptime + 1
        while !gate.entered { guard ProcessInfo.processInfo.systemUptime < entryDeadline else { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 5_000_000) }
        let begin = ProcessInfo.processInfo.systemUptime
        runner.cancel(); pending.cancel()
        do { _ = try await pending.value; XCTFail("The held discovery ignored cancellation."); return }
        catch is CancellationError {}
        let elapsed = ProcessInfo.processInfo.systemUptime - begin; XCTAssertLessThan(elapsed, 0.5)
        XCTAssertTrue(runner.hasPendingRequest)
        do { _ = try await runner.run(source: "1", inputsJSON: "{}"); XCTFail("A stopped launch admitted overlap before cleanup."); return }
        catch ScriptProcessError.busy {}
        gate.release()
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 1
        while runner.hasPendingRequest { guard ProcessInfo.processInfo.systemUptime < cleanupDeadline else { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(runner.lastProcessID); XCTAssertEqual(runner.lastStage, "discovering-extension")
        let recovered = try await runner.run(source: "7*8", inputsJSON: "{}")
        XCTAssertEqual(recovered.output, "56"); XCTAssertFalse(recovered.failed)
        let data = try JSONSerialization.data(withJSONObject: ["purpose": "native-script-whole-call-cancel", "completed": recovered.output == "56",
            "heldPhase": "non-cooperative-before-discovery", "cancelReturnedSeconds": elapsed, "overlapRefusedBeforeCleanup": entries == 2,
            "hostPID": getpid(), "recoveryHelperPID": runner.lastProcessID ?? -1,
            "limitations": ["Controlled non-cooperative phase with duplicate Stop/task cancellation and real helper recovery. No production chat integration or actual hung OS service."]], options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; add(attachment)
    }
}
