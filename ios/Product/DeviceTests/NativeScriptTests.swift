import XCTest
import OpenWeightsCore
@testable import OpenWeights

// Test-only in-process bridge. Production tool registration requires an isolated runner.
private final class NativeScriptFixture: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var active: OWScriptSession?
    private var stopped = false
    func cancel() { lock.withLock { stopped = true; active?.cancel() } }
    func run(source: String, inputsJSON: String) async throws -> ScriptResult {
        let session = OWScriptSession()
        lock.withLock { active = session; if stopped { session.cancel() } }
        defer { lock.withLock { active = nil } }
        return try await withTaskCancellationHandler(operation: {
            let value = await Task.detached {
                let value = session.runSource(source, inputsJSON: inputsJSON)
                return ScriptResult(output: value["output"] as? String ?? "Missing output", failed: value["failed"] as? Bool ?? true)
            }.value
            try Task.checkCancellation(); return value
        }, onCancel: { session.cancel() })
    }
}

@MainActor extension ProductTests {
    func testNativeScriptInterpreterLimitsAndCancellation() async throws {
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        var passed: [String] = []; var completed = false
        defer {
            let value: [String: Any] = ["purpose": "native-quickjs-interpreter-controls", "completed": completed,
                "passedChecks": passed, "quickjsRevision": "954dc53628e36891f93c359aa60895c2ae3dac6b",
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limits": ["memoryBytes": 33554432, "stackBytes": 524288, "workerStackBytes": 2097152, "millis": 2000, "outputBytes": 2000],
                "limitations": ["Test-only interpreter in the XCTest host process. No verified separate-process sandbox, production tool registration, model-generated scripts, native touch or background execution."]]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let cases = [
            ("2 + 3", "5", "arithmetic"),
            ("return {city:'Osaka', total:7}", "{\"city\":\"Osaka\",\"total\":7}", "return-object"),
            ("await Promise.resolve(11)", "11", "await"),
            ("const n = await Promise.resolve(13); return n * 2", "26", "await-return"),
            ("(async function(){return {value:19, city:'Osaka'}})()", "{\"value\":19,\"city\":\"Osaka\"}", "promise-object-value-key"),
            ("const n = await Promise.resolve(19); return {value:n, city:'Osaka'}", "{\"value\":19,\"city\":\"Osaka\"}", "async-wrapper-object-value-key"),
            ("console.log('Cedar'); 17", "Cedar\n17", "console-result"),
            ("globalThis.poison = 23; 23", "23", "first-world"),
            ("typeof poison", "\"undefined\"", "fresh-world"),
            ("[typeof fetch, typeof process, typeof std, typeof os, typeof Worker, typeof require]", "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]", "host-globals-absent")
        ]
        for (source, expected, name) in cases {
            let result = try await NativeScriptFixture().run(source: source, inputsJSON: "{}")
            XCTAssertFalse(result.failed, name + ": " + result.output); XCTAssertEqual(result.output, expected, name)
            guard !result.failed, result.output == expected else { return }; passed.append(name)
        }
        for source in ["while(true) {}", "function f(){return f()} f()", "let a=[]; while(true) a.push('x'.repeat(1000000))", "await new Promise(()=>{})", "Promise.resolve().then(function f(){Promise.resolve().then(f)}); await new Promise(()=>{})"] {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await NativeScriptFixture().run(source: source, inputsJSON: "{}")
            XCTAssertTrue(result.failed); XCTAssertFalse(result.output.isEmpty)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 10)
            guard result.failed else { return }; passed.append("resource-refusal-\(passed.count)")
        }
        let capped = try await NativeScriptFixture().run(source: "console.log('😀'.repeat(10000)); '漢'.repeat(10000)", inputsJSON: "{}")
        XCTAssertFalse(capped.failed); XCTAssertLessThanOrEqual(capped.output.utf8.count, 2000)
        XCTAssertTrue(capped.output.contains("truncated")); XCTAssertFalse(capped.output.contains("�")); passed.append("unicode-aggregate-output-cap")
        let runtimeError = try await NativeScriptFixture().run(source: "console.log('once'); JSON.parse('bad')", inputsJSON: "{}")
        XCTAssertTrue(runtimeError.failed); XCTAssertTrue(runtimeError.output.contains("SyntaxError")); XCTAssertFalse(runtimeError.output.contains("once")); passed.append("runtime-error-no-replay")
        let fixture = NativeScriptFixture()
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task { try await fixture.run(source: "while(true){}", inputsJSON: "{}") }
        try await Task.sleep(nanoseconds: 50_000_000); fixture.cancel()
        let cancelled = try await task.value
        XCTAssertTrue(cancelled.failed); XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        passed.append("responsive-main-actor-cancellation")
        completed = passed.count == 18
        XCTAssertTrue(completed)
    }
    func testNativeScriptFileAdapterAndRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"total\":30,\"quoted\":\"'); throw new Error('injected') //\"}".utf8).write(to: root.appendingPathComponent("sales.json"))
        try Data("```js\nconst fs = require('node:fs'); const p = require('path'); const text = await fs.promises.readFile(p.join('sales.json')); return JSON.parse(text).total + 1;\n```".utf8).write(to: root.appendingPathComponent("program.js"))
        let workspace = try Workspace(root: root), tools = ScriptTools(runner: NativeScriptFixture())
        func call(_ args: [String: Any]) throws -> AgentToolCall {
            AgentToolCall(id: UUID().uuidString, name: "run_script", argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
        }
        let saved = try call(["path": "program.js"])
        let refused = await tools.execute(saved, enabled: true, mode: .ask, workspace: workspace)
        XCTAssertTrue(refused.rejected)
        let accepted = await tools.execute(saved, enabled: true, mode: .ask, workspace: workspace, approval: ApprovedToolCall(displayedCall: saved))
        XCTAssertFalse(accepted.rejected); XCTAssertEqual(accepted.text, "31"); XCTAssertTrue(accepted.untrustedText)
        let missing = await tools.execute(try call(["source": "const fs=require('fs'); [fs.existsSync('missing.json'), fs.existsSync('sales.json')]", "files": ["missing.json", "sales.json"]]), enabled: true, mode: .auto, workspace: workspace)
        XCTAssertFalse(missing.rejected); XCTAssertEqual(missing.text, "[false,true]")
        try Data("require('fs').writeFileSync('sales.json', 'changed')".utf8).write(to: root.appendingPathComponent("program.js"))
        let write = await tools.execute(saved, enabled: true, mode: .auto, workspace: workspace)
        XCTAssertTrue(write.rejected); XCTAssertTrue(write.text.contains("write_file and replace"))
        let unchanged = try String(contentsOf: root.appendingPathComponent("sales.json"), encoding: .utf8)
        XCTAssertTrue(unchanged.contains("\"total\":30"))
        let attachment = XCTAttachment(string: "Saved/fenced script, fs/path/await, exact approval, JSON injection treated as data, missing file absent, direct file write refused and saved-program repair route passed. Test-only in-process interpreter. Isolation and production chat integration pending.")
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
