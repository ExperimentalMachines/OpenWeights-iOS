import XCTest
import OpenWeightsCore
@testable import OpenWeights

@MainActor extension ProductTests {
    func testNativeIsolatedScriptProcessRoundTripAndRecovery() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated helper API requires iOS 26.") }
        let runner = IsolatedScriptRunner()
        var processIDs: [Int32] = []; var reached: [String] = []; var completed = false
        defer {
            let observation: [String: Any] = ["purpose": "native-isolated-script-process", "completed": completed,
                "hostPID": getpid(), "lastStage": runner.lastStage, "lastReply": runner.lastReplyDescription ?? "none", "bundleIdentifier": Bundle.main.bundleIdentifier ?? "missing", "helperPIDs": processIDs, "actionsReached": reached,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Launch/PID, language, cancellation and recovery checks. No production chat registration, crash injection, OS sandbox denied-access probes, external file provider or older-iOS behavior."]]
            if let data = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let first = try await runner.run(source: "await Promise.resolve({value:31,city:'Osaka'})", inputsJSON: "{}")
        XCTAssertFalse(first.failed); XCTAssertEqual(first.output, "{\"value\":31,\"city\":\"Osaka\"}")
        let firstPID = try XCTUnwrap(runner.lastProcessID); XCTAssertNotEqual(firstPID, getpid())
        guard !first.failed, first.output == "{\"value\":31,\"city\":\"Osaka\"}", firstPID != getpid() else { return }
        processIDs.append(firstPID); reached.append("isolated-helper-async-object-round-trip")
        let poison = try await runner.run(source: "globalThis.poison=23;23", inputsJSON: "{}")
        XCTAssertEqual(poison.output, "23")
        let fresh = try await runner.run(source: "typeof poison", inputsJSON: "{}")
        XCTAssertEqual(fresh.output, "\"undefined\""); reached.append("fresh-runtime-across-helper-requests")
        let begin = ProcessInfo.processInfo.systemUptime
        let pending = Task { try await runner.run(source: "while(true){}", inputsJSON: "{}") }
        try await Task.sleep(nanoseconds: 100_000_000); runner.cancel()
        do { _ = try await pending.value; XCTFail("A cancelled script returned success."); return }
        catch is CancellationError { reached.append("responsive-cancelled-request") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 1.5)
        let recovered = try await runner.run(source: "inputs.city + ':' + (2+3)", inputsJSON: "{\"city\":\"Osaka\"}")
        XCTAssertFalse(recovered.failed); XCTAssertEqual(recovered.output, "\"Osaka:5\"")
        processIDs.append(try XCTUnwrap(runner.lastProcessID)); reached.append("fresh-request-after-cancellation")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"total\":30}".utf8).write(to: root.appendingPathComponent("sales.json"))
        try Data("const fs=require('fs'); return JSON.parse(await fs.promises.readFile('sales.json')).total+1".utf8).write(to: root.appendingPathComponent("program.js"))
        let tool = ScriptTools(runner: runner), workspace = try Workspace(root: root)
        let call = AgentToolCall(id: UUID().uuidString, name: "run_script", argumentsJSON: "{\"path\":\"program.js\"}")
        let result = await tool.execute(call, enabled: true, mode: .ask, workspace: workspace, approval: ApprovedToolCall(displayedCall: call))
        XCTAssertFalse(result.rejected); XCTAssertEqual(result.text, "31"); XCTAssertTrue(result.untrustedText)
        guard !result.rejected, result.text == "31" else { return }
        reached.append("approved-saved-script-and-json-inputs-over-xpc")
        completed = reached.count == 5
    }
}
