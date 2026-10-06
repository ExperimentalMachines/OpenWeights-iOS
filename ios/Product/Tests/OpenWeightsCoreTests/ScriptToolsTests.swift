import XCTest
@testable import OpenWeightsCore

private actor RecordingScriptRunner: ScriptRunner {
    private(set) var calls: [(String, String)] = []
    var failed = false
    func run(source: String, inputsJSON: String) async throws -> ScriptResult {
        calls.append((source, inputsJSON)); return ScriptResult(output: failed ? "TypeError: bad data" : "31", failed: failed)
    }
    nonisolated func cancel() {}
    func fail() { failed = true }
}
final class ScriptToolsTests: XCTestCase {
    private func call(_ args: [String: Any]) throws -> AgentToolCall {
        AgentToolCall(id: UUID().uuidString, name: "run_script", argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
    }
    private func folder() throws -> (URL, Workspace) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try Workspace(root: root))
    }
    func testFencesTypographyAndRootPathRecognition() {
        XCTAssertEqual(ScriptToolDefinition.program("  ```javascript\nreturn “Osaka”;\n```\nDone"), "return \"Osaka\";")
        XCTAssertEqual(ScriptToolDefinition.program("const x = `a`; x"), "const x = `a`; x")
        XCTAssertEqual(ScriptToolDefinition.mentionedPaths("read('sales.csv'); read('data/report.json'); 'https://a/b.csv'; 'sales.csv'"), ["sales.csv", "data/report.json"])
    }
    func testExactAskApprovalIsConsumedAndDisabledPlanNeverRun() async throws {
        let runner = RecordingScriptRunner()
        let tested = ScriptTools(runner: runner), request = try call(["source": "30+1"])
        let ticket = ApprovedToolCall(displayedCall: request)
        let refused = await tested.execute(request, enabled: true, mode: .ask)
        XCTAssertTrue(refused.rejected)
        let wrong = await tested.execute(request, enabled: true, mode: .ask, approval: ApprovedToolCall(displayedCall: try call(["source": "9"])))
        XCTAssertTrue(wrong.rejected)
        let approved = await tested.execute(request, enabled: true, mode: .ask, approval: ticket)
        XCTAssertFalse(approved.rejected); XCTAssertTrue(approved.untrustedText)
        let reused = await tested.execute(request, enabled: true, mode: .ask, approval: ticket)
        let plan = await tested.execute(request, enabled: true, mode: .plan)
        let off = await tested.execute(request, enabled: false, mode: .auto)
        XCTAssertTrue(reused.rejected && plan.rejected && off.rejected)
        let calls = await runner.calls; XCTAssertEqual(calls.count, 1)
    }
    func testInputBoundAndMissingFilesAreJSONDataNotSource() async throws {
        let (root, workspace) = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let data = String(repeating: "😀", count: 12000) + "throw new Error('injected')"
        try Data(data.utf8).write(to: root.appendingPathComponent("sales.csv"))
        let runner = RecordingScriptRunner()
        let tested = ScriptTools(runner: runner)
        let request = try call(["source": "inputs['sales.csv'].length", "files": ["sales.csv", "missing.json"]])
        let result = await tested.execute(request, enabled: true, mode: .auto, workspace: workspace)
        XCTAssertFalse(result.rejected); XCTAssertTrue(result.untrustedText)
        let calls = await runner.calls; let first = try XCTUnwrap(calls.first)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.1.utf8)) as? [String: String])
        XCTAssertEqual(input["sales.csv"]?.utf16.count, 20 * 1024); XCTAssertNil(input["missing.json"])
        XCTAssertFalse(first.0.contains("injected")); XCTAssertTrue(first.0.hasPrefix(ScriptToolDefinition.nodeShim))
    }
    func testSavedProgramAndErrorRepairRoute() async throws {
        let (root, workspace) = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("```js\nreturn 31\n```".utf8).write(to: root.appendingPathComponent("program.js"))
        let runner = RecordingScriptRunner()
        let tool = ScriptTools(runner: runner)
        let request = try call(["path": "program.js"])
        let good = await tool.execute(request, enabled: true, mode: .auto, workspace: workspace)
        XCTAssertEqual(good.text, "31")
        await runner.fail()
        let bad = await tool.execute(request, enabled: true, mode: .auto, workspace: workspace)
        XCTAssertTrue(bad.rejected && bad.untrustedText); XCTAssertTrue(bad.text.contains("write_file and replace"))
        let calls = await runner.calls; XCTAssertTrue(calls[0].0.hasSuffix("return 31"))
    }
    func testTraversalSymlinkAndRevokedGrantNeverReachRunner() async throws {
        let (root, workspace) = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path, withDestinationPath: "/etc/hosts")
        let runner = RecordingScriptRunner()
        let tool = ScriptTools(runner: runner)
        for path in ["../secret.txt", "/etc/hosts", "link.txt"] {
            let result = await tool.execute(try call(["source": "1", "files": [path]]), enabled: true, mode: .auto, workspace: workspace)
            XCTAssertTrue(result.rejected)
        }
        await workspace.revoke()
        let revoked = await tool.execute(try call(["source": "1", "files": ["sales.csv"]]), enabled: true, mode: .auto, workspace: workspace)
        XCTAssertTrue(revoked.rejected)
        let calls = await runner.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testOversizedSavedOrInlineSourceAndUnsharedFileNeverRun() async throws {
        let (root, workspace) = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let large = String(repeating: " ", count: 16 * 1024) + "return 31"
        try Data(large.utf8).write(to: root.appendingPathComponent("large.js"))
        let runner = RecordingScriptRunner()
        let tested = ScriptTools(runner: runner)
        let inline = await tested.execute(try call(["source": String(repeating: "x", count: 16385)]), enabled: true, mode: .auto)
        let saved = await tested.execute(try call(["path": "large.js"]), enabled: true, mode: .auto, workspace: workspace)
        let noFolder = await tested.execute(try call(["source": "inputs['a.csv']"]), enabled: true, mode: .auto)
        XCTAssertTrue(inline.rejected && saved.rejected && noFolder.rejected)
        let calls = await runner.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testPrivateInputsAreTrackedThroughSuccessFailureAndApprovalRefusal() async throws {
        let (root, workspace) = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"total\":30}".utf8).write(to: root.appendingPathComponent("sales.json"))
        try Data("return 31".utf8).write(to: root.appendingPathComponent("program.js"))
        let runner = RecordingScriptRunner(), tool = ScriptTools(runner: RecordingScriptRunner())
        let arithmetic = await tool.execute(try call(["source": "30+1"]), enabled: true, mode: .auto)
        XCTAssertFalse(arithmetic.privateDataRead)
        let missing = await tool.execute(try call(["source": "1", "files": ["missing.json"]]), enabled: true, mode: .auto, workspace: workspace)
        XCTAssertFalse(missing.privateDataRead)
        let actual = ScriptTools(runner: runner)
        let input = await actual.execute(try call(["source": "inputs['sales.json']"]), enabled: true, mode: .auto, workspace: workspace)
        XCTAssertTrue(input.privateDataRead)
        let program = try call(["path": "program.js"])
        let refused = await actual.execute(program, enabled: true, mode: .ask, workspace: workspace)
        XCTAssertTrue(refused.rejected); XCTAssertFalse(refused.privateDataRead)
        let saved = await actual.execute(program, enabled: true, mode: .auto, workspace: workspace)
        XCTAssertTrue(saved.privateDataRead)
        await runner.fail()
        let failed = await actual.execute(try call(["source": "1", "files": ["sales.json"]]), enabled: true, mode: .auto, workspace: workspace)
        XCTAssertTrue(failed.rejected); XCTAssertTrue(failed.privateDataRead)
    }
    func testScriptPrivateProvenancePersistsAndParticipatesInFoldIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("chat.json"), store = try ConversationStore(file: root.appendingPathComponent("chat.json"))
        var value = try await store.create(title: "Script privacy")
        var tool = StoredMessage(role: .tool, content: "31")
        tool.toolName = "run_script"; tool.toolUntrustedText = true; tool.toolPrivateDataRead = true
        value.messages.append(tool); try await store.save(value)
        let reopened = try ConversationStore(file: url); let saved = try await reopened.conversation(value.id)
        XCTAssertEqual(saved.messages.first?.toolPrivateDataRead, true)
        let before = ConversationContext.fingerprint(saved.messages[...])
        var changed = saved.messages; changed[0].toolPrivateDataRead = false
        XCTAssertNotEqual(before, ConversationContext.fingerprint(changed[...]))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tool)) as? [String: Any])
        legacy.removeValue(forKey: "toolPrivateDataRead")
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.toolPrivateDataRead); XCTAssertEqual(decoded.toolName, "run_script")
    }

}
