import Foundation
import OpenWeightsCore

private final class ScriptStopSignal: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    var value: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}
private actor ControllerScriptRunner: ScriptRunner {
    private(set) var calls: [(String, String)] = []
    private var held = false
    private nonisolated let signal = ScriptStopSignal()
    func hold() { held = true }
    func releaseHold() { held = false }
    nonisolated func cancel() { signal.stop() }
    func run(source: String, inputsJSON: String) async throws -> ScriptResult {
        calls.append((source, inputsJSON))
        if held {
            while !signal.value { try await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        return ScriptResult(output: "31", failed: false)
    }
}

private actor ScriptWatchSearchTransport: SearchHTTPTransport {
    private(set) var requests = 0
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        requests += 1
        return WebHTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data())
    }
}
extension ControllerChecks {
    @MainActor static func scriptChecks(_ passed: inout [String]) async throws {
        let automaticRunner = ControllerScriptRunner()
        let automatic = try Fixture(scriptRunner: automaticRunner, mode: .script, write: false); defer { automatic.cleanup() }
        try require(automatic.chat.scriptsAvailable && !automatic.chat.scriptEnabled, "Scripts did not start off.")
        automatic.chat.scriptEnabled = true
        try require(automatic.defaults.bool(forKey: "tools.scripts.enabled"), "Script preference was not persisted.")
        try await automatic.loadAndSend(); try await wait("Automatic script did not finish") { !automatic.chat.busy }
        let inlineCalls = await automaticRunner.calls
        let inline = automatic.chat.current!.messages.first { $0.toolName == "run_script" }
        try require(inlineCalls.count == 1 && inline?.status == .complete && inline?.toolUntrustedText == true && inline?.toolPrivateDataRead == false && automatic.runtime.captures.first!.tools.contains("run_script"), "Inline script routing or provenance failed.")
        let search = AgentToolCall(id: "search", name: "web_search", argumentsJSON: "{\"query\":\"Cedar\"}")
        let inlineApproval = await automatic.web.requiresApproval(search, mode: .auto)
        try require(!inlineApproval, "Arithmetic without file reads incorrectly marked private file data.")
        passed.append("script-default-off-persisted-toggle-auto-routing-and-inline-provenance")

        let askRunner = ControllerScriptRunner()
        let approved = try Fixture(scriptRunner: askRunner, mode: .script, write: false); defer { approved.cleanup() }
        approved.chat.scriptEnabled = true; approved.files.mode = .ask
        try await approved.loadAndSend(); try await wait("Script approval absent") { approved.chat.pendingToolApproval != nil }
        let beforeApproval = await askRunner.calls
        try require(beforeApproval.isEmpty && approved.chat.pendingToolApproval!.displayedCall.name == "run_script", "The script ran before exact Ask approval.")
        approved.chat.answerToolApproval(approved: true)
        try await wait("Approved script did not finish") { !approved.chat.busy }
        let afterApproval = await askRunner.calls
        try require(afterApproval.count == 1 && approved.chat.current!.messages.contains { $0.toolName == "run_script" && $0.content == "31" && $0.status == .complete }, "Exact approved script did not execute.")
        passed.append("script-exact-ask-approval-precedes-execution-and-result-checkpoint")

        let declineRunner = ControllerScriptRunner()
        let decline = try Fixture(scriptRunner: declineRunner, mode: .script, write: false); defer { decline.cleanup() }
        decline.chat.scriptEnabled = true; decline.files.mode = .ask
        try await decline.loadAndSend(); try await wait("Decline approval absent") { decline.chat.pendingToolApproval != nil }
        decline.chat.answerToolApproval(approved: false)
        try await wait("Declined script did not settle") { !decline.chat.busy }
        let declinedCalls = await declineRunner.calls
        try require(declinedCalls.isEmpty && decline.chat.current!.messages.contains { $0.toolName == "run_script" && $0.status == .failed }, "Declined script reached the runner.")
        passed.append("declined-script-never-reaches-the-runner")

        for state in ["off", "plan", "unavailable"] {
            let runner = ControllerScriptRunner(), fixture = try Fixture(scriptRunner: state == "unavailable" ? nil : runner, mode: .script, write: false)
            defer { fixture.cleanup() }
            fixture.chat.scriptEnabled = state != "off"; fixture.files.mode = state == "plan" ? .plan : .auto
            try await fixture.loadAndSend(); try await wait("Blocked script did not finish") { !fixture.chat.busy }
            let calls = await runner.calls
            try require(calls.isEmpty && !fixture.runtime.captures.first!.tools.contains("run_script"), "Disabled/Plan/unavailable script was offered or executed.")
        }
        passed.append("script-disabled-plan-and-unavailable-paths-do-not-offer-or-run")

        let fileRunner = ControllerScriptRunner()
        let privateData = try Fixture(scriptRunner: fileRunner, mode: .script, write: false); defer { privateData.cleanup() }
        try await privateData.prepareFiles(); privateData.files.enabled = []
        try Data("{\"total\":30}".utf8).write(to: privateData.sharedFolder.appendingPathComponent("sales.json"))
        privateData.runtime.setScriptArguments("{\"source\":\"inputs['sales.json']\"}"); privateData.chat.scriptEnabled = true
        try await privateData.loadAndSend(); try await wait("File script did not finish") { !privateData.chat.busy }
        let fileCalls = await fileRunner.calls
        try require(fileCalls.count == 1 && fileCalls[0].1.contains("total") && privateData.chat.current!.messages.contains { $0.toolName == "run_script" && $0.toolPrivateDataRead == true }, "Script file bytes or private provenance were lost.")
        let fileApproval = await privateData.web.requiresApproval(search, mode: .auto)
        try require(fileApproval, "Private script inputs failed to guard network queries.")
        let reopened = try ConversationStore(file: privateData.conversationFile)
        let durable = try await reopened.conversation(privateData.chat.current!.id)
        try require(durable.messages.contains { $0.toolName == "run_script" && $0.toolPrivateDataRead == true }, "Private provenance did not reopen.")
        privateData.chat.scriptEnabled = false
        privateData.chat.draft = "Continue"; await privateData.chat.send()
        try await wait("Private replay did not finish") { !privateData.chat.busy }
        let continuedApproval = await privateData.web.requiresApproval(search, mode: .auto)
        try require(continuedApproval, "The next turn dropped durable private-script provenance.")
        passed.append("script-private-file-inputs-persist-reopen-and-guard-network-egress-across-turns")

        let heldRunner = ControllerScriptRunner(), stopped = try Fixture(scriptRunner: heldRunner, mode: .script, write: false); defer { stopped.cleanup() }
        stopped.chat.scriptEnabled = true; await heldRunner.hold()
        try await stopped.loadAndSend()
        for _ in 0..<200 {
            if !(await heldRunner.calls).isEmpty { break }; try await Task.sleep(nanoseconds: 5_000_000)
        }
        try require(!(await heldRunner.calls).isEmpty, "Held script did not start.")
        stopped.chat.cancel(); try await wait("Stop did not release the script turn") { !stopped.chat.busy }
        try require(stopped.chat.error == nil && stopped.chat.pendingToolApproval == nil, "Script Stop left an error or approval behind.")
        await heldRunner.releaseHold(); stopped.chat.draft = "Recover"; await stopped.chat.send()
        try await wait("Script Stop recovery did not finish") { !stopped.chat.busy }
        try require(stopped.chat.error == nil && stopped.chat.current?.messages.last?.content == "31", "The next script turn did not recover.")
        passed.append("chat-stop-reaches-active-script-runner-and-next-turn-recovers")
        try await scriptWatchChecks(&passed)
    }
    @MainActor static func scriptWatchChecks(_ passed: inout [String]) async throws {
        let runner = ControllerScriptRunner(), fixture = try Fixture(scriptRunner: runner, mode: .script, write: false); defer { fixture.cleanup() }
        fixture.chat.scriptEnabled = true
        try await fixture.prepareFiles(mode: .ask); fixture.files.enabled = []
        try Data("{\"total\":30}".utf8).write(to: fixture.sharedFolder.appendingPathComponent("sales.json"))
        fixture.runtime.setScriptArguments("{\"source\":\"inputs['sales.json']\"}")
        await fixture.chat.load(fixture.chat.downloads.models[0])
        let initial = fixture.chat.current
        let watch = ScheduledWatch(task: "Calculate a private file total", everyMinutes: 1, at: Date())
        let finding = await fixture.chat.checkWatch(watch, background: true)
        let calls = await runner.calls
        try require(finding.outcome == .checked && finding.summary == "31" && calls.count == 1 && calls[0].1.contains("total") && fixture.chat.current == initial && fixture.chat.pendingToolApproval == nil && !fixture.chat.busy && fixture.chat.checkingWatchID == nil && fixture.chat.contextUsed == 0, "Watch did not execute an enabled script in Auto without changing chat.")
        let search = AgentToolCall(id: "search", name: "web_search", argumentsJSON: "{\"query\":\"Cedar\"}")
        let privateGuard = await fixture.web.requiresApproval(search, mode: .auto)
        try require(privateGuard, "Private watch script inputs failed to mark the web guard.")
        passed.append("watch-script-uses-auto-with-captured-private-inputs-no-chat-approval-and-isolated-context")

        let transport = ScriptWatchSearchTransport(), privateRunner = ControllerScriptRunner()
        let privateSearch = try Fixture(scriptRunner: privateRunner, mode: .scriptThenSearch, write: false, searchTransport: transport); defer { privateSearch.cleanup() }
        try await privateSearch.prepareFiles(); privateSearch.files.enabled = []
        try Data("{\"total\":30}".utf8).write(to: privateSearch.sharedFolder.appendingPathComponent("sales.json"))
        privateSearch.runtime.setScriptArguments("{\"source\":\"inputs['sales.json']\"}")
        privateSearch.chat.scriptEnabled = true; privateSearch.web.searchEnabled = true
        await privateSearch.chat.load(privateSearch.chat.downloads.models[0])
        _ = await privateSearch.chat.checkWatch(watch, background: true)
        let requests = await transport.requests
        let refusal = privateSearch.runtime.captures.last!.messages.first { $0["role"] == "tool" && $0["tool_name"] == "web_search" }
        try require(requests == 0 && refusal?["content"]?.contains("Approve this exact search") == true && privateSearch.chat.pendingToolApproval == nil, "Private script-derived unattended search escaped its egress approval guard.")
        passed.append("watch-private-script-result-refuses-unapproved-web-query-before-transport")

        for state in ["off", "unavailable", "no-tools"] {
            let blockedRunner = ControllerScriptRunner()
            let blocked = try Fixture(scriptRunner: state == "unavailable" ? nil : blockedRunner, mode: .script, supportsTools: state != "no-tools", write: false); defer { blocked.cleanup() }
            blocked.chat.scriptEnabled = state != "off"
            await blocked.chat.load(blocked.chat.downloads.models[0])
            _ = await blocked.chat.checkWatch(watch, background: true)
            let attempted = await blockedRunner.calls
            try require(attempted.isEmpty && blocked.runtime.captures.allSatisfy { !$0.tools.contains("run_script") }, "An off/unavailable/unsupported watch executed or offered a script.")
        }
        passed.append("watch-script-off-unavailable-and-unsupported-model-guards")

        let revokedRunner = ControllerScriptRunner(), revoked = try Fixture(scriptRunner: revokedRunner, mode: .script, write: false); defer { revoked.cleanup() }
        try await revoked.prepareFiles(); revoked.files.enabled = []; revoked.chat.scriptEnabled = true
        revoked.runtime.setScriptArguments("{\"source\":\"1\",\"files\":[\"user.txt\"]}")
        await revoked.chat.load(revoked.chat.downloads.models[0])
        let gate = PreparationGate(); revoked.runtime.streamGate = gate
        let checking = Task { await revoked.chat.checkWatch(watch, background: true) }
        try await waitForGate(gate); await revoked.files.revoke(); revoked.runtime.streamGate = nil; await gate.release()
        _ = await checking.value
        let revokedCalls = await revokedRunner.calls
        try require(revokedCalls.isEmpty && revoked.runtime.captures.last!.messages.contains { $0["tool_name"] == "run_script" && $0["content"]?.contains("No folder has been shared") == true }, "A watch script used a folder grant revoked after model generation began.")
        passed.append("watch-script-refuses-inputs-after-captured-folder-grant-is-revoked")

        let heldRunner = ControllerScriptRunner(), clock = FixtureWatchClock()
        let held = try Fixture(scriptRunner: heldRunner, mode: .script, write: false, clock: { clock.now }); defer { held.cleanup() }
        held.chat.scriptEnabled = true; await heldRunner.hold(); await held.chat.load(held.chat.downloads.models[0])
        _ = await held.watches.create(task: "Calculate a result", everyMinutes: 1)
        let id = await held.watches.store.list()[0].id; clock.now = clock.now.addingTimeInterval(61)
        let active = Task { await held.watches.runBackground(UUID()) }
        for _ in 0..<200 { if !(await heldRunner.calls).isEmpty { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await heldRunner.calls; try require(started.count == 1, "Watch script did not start.")
        await held.watches.pause(id); _ = await active.value
        let paused = await held.watches.store.watch(id)!
        try require(paused.state == .paused && paused.runs == 0 && paused.lastSummary == nil && paused.claim == nil && !held.chat.busy && held.chat.checkingWatchID == nil, "Pause allowed a cancelled watch script to consume a run or record a stale finding.")
        await heldRunner.releaseHold(); held.chat.draft = "Recover"; await held.chat.send(); try await wait("Chat after watch Stop did not recover") { !held.chat.busy }
        try require(held.chat.error == nil && held.chat.current?.messages.last?.content == "31", "Chat did not recover after a paused script watch.")
        passed.append("watch-pause-cancels-active-script-rejects-late-finding-and-chat-recovers")
    }

}
